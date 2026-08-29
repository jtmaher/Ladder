import AVFoundation
import CoreAudio
import Synchronization

struct EngineStats {
    var sampleRate: Double = 0
    var bufferFrames: UInt32 = 0
    var deviceLatencyFrames: UInt32 = 0
    var safetyOffsetFrames: UInt32 = 0

    var totalOutputLatencyMS: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(bufferFrames + deviceLatencyFrames + safetyOffsetFrames) / sampleRate * 1000.0
    }
}

/// Owns the AVAudioEngine and the render callback.
///
/// Threading contract: the UI writes parameters through the atomics below and
/// never touches render state; the MIDI thread talks to the audio thread only
/// through `midiFIFO`. `phase`, `smoothedGain`, `synth`, and `pitchBend` belong
/// to the audio thread alone. Nothing in the render closure allocates or locks.
final class AudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    /// MIDI thread -> audio thread.
    let midiFIFO = MidiEventFIFO()

    /// UI -> audio thread, snapshotted once per buffer.
    let params = ParamStore()

    /// Audio thread -> UI: output samples for the waterfall display.
    let visFIFO = SampleFIFO()

    // UI -> audio thread. Floats travel as bit patterns so we only need Atomic<UInt32>.
    let toneOn = Atomic<Bool>(false)
    let targetGain = Atomic<UInt32>(Float(0.2).bitPattern)
    let frequency = Atomic<UInt32>(Float(220).bitPattern)
    let masterGain = Atomic<UInt32>(Float(0.35).bitPattern)

    // Audio thread -> UI, polled by a timer for display only.
    let uiActiveVoices = Atomic<UInt32>(0)
    let uiLastNote = Atomic<UInt32>(0)
    let uiLastVelocity = Atomic<UInt32>(0)

    // Audio-thread-only state.
    private var phase = 0.0
    private var smoothedGain: Float = 0
    private var synth = PolySynth(sampleRate: 48_000)
    private var fx = FXChain(sampleRate: 48_000)
    private var pitchBend: Float = 0  // -1...1, scaled to ±2 semitones
    private var modWheel: Float = 0   // CC1, 0...1

    private(set) var stats = EngineStats()

    func start(preferredBufferFrames: UInt32 = 128) throws {
        let output = engine.outputNode
        let sampleRate = output.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw NSError(domain: "Ladder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create stereo format at \(sampleRate) Hz"])
        }
        synth = PolySynth(sampleRate: sampleRate)
        fx = FXChain(sampleRate: Float(sampleRate))

        let node = AVAudioSourceNode(format: format) { [self] _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let frames = Int(frameCount)

            // Drain pending MIDI events (applied at buffer start; 128 frames of
            // jitter at most, refined to sample-accurate later if audible).
            while let event = midiFIFO.pop() {
                switch event.kind {
                case .noteOn:
                    synth.noteOn(note: event.note, velocity: event.value)
                    uiLastNote.store(UInt32(event.note), ordering: .relaxed)
                    uiLastVelocity.store(event.value.bitPattern, ordering: .relaxed)
                case .noteOff:
                    synth.noteOff(note: event.note)
                case .controlChange:
                    switch event.note {
                    case 64: synth.setSustain(event.value >= 0.5)
                    case 1: modWheel = event.value
                    default: break
                    }
                case .pitchBend:
                    pitchBend = event.value
                }
            }

            // Test tone fills the buffer, synth mixes on top.
            let gainTarget: Float = toneOn.load(ordering: .relaxed)
                ? Float(bitPattern: targetGain.load(ordering: .relaxed)) : 0
            let freq = Double(Float(bitPattern: frequency.load(ordering: .relaxed)))
            let phaseIncrement = 2.0 * .pi * freq / sampleRate
            for frame in 0..<frames {
                smoothedGain += 0.002 * (gainTarget - smoothedGain)
                let sample = Float(sin(phase)) * smoothedGain
                phase += phaseIncrement
                if phase > 2.0 * .pi { phase -= 2.0 * .pi }
                left[frame] = sample
                right[frame] = sample
            }

            let patch = params.snapshot()
            synth.render(left: left, right: right, frameCount: frames,
                         patch: patch,
                         pitchBendSemitones: pitchBend * 2.0,
                         modWheel: modWheel,
                         masterGain: Float(bitPattern: masterGain.load(ordering: .relaxed)))
            uiActiveVoices.store(UInt32(synth.activeVoiceCount), ordering: .relaxed)

            fx.process(left: left, right: right, frameCount: frames, patch: patch)

            // Soft clip so a fistful of loud voices saturates instead of wrapping.
            for frame in 0..<frames {
                left[frame] = tanhf(left[frame])
                right[frame] = tanhf(right[frame])
            }

            visFIFO.push(left: left, right: right, count: frames)
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: output, format: format)
        sourceNode = node

        engine.prepare()
        configureDeviceAndReadStats(preferredBufferFrames: preferredBufferFrames, sampleRate: sampleRate)
        try engine.start()
    }

    /// Requests a small hardware buffer on the output device, then reads back
    /// what the device actually granted plus its intrinsic latencies.
    private func configureDeviceAndReadStats(preferredBufferFrames: UInt32, sampleRate: Double) {
        guard let au = engine.outputNode.audioUnit else { return }

        var deviceID = AudioDeviceID(0)
        var idSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &deviceID, &idSize) == noErr,
              deviceID != kAudioObjectUnknown else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var requested = preferredBufferFrames
        AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &requested)

        var granted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &granted)

        var deviceLatency: UInt32 = 0
        address.mSelector = kAudioDevicePropertyLatency
        address.mScope = kAudioObjectPropertyScopeOutput
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &deviceLatency)

        var safetyOffset: UInt32 = 0
        address.mSelector = kAudioDevicePropertySafetyOffset
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &safetyOffset)

        stats = EngineStats(sampleRate: sampleRate,
                            bufferFrames: granted,
                            deviceLatencyFrames: deviceLatency,
                            safetyOffsetFrames: safetyOffset)
    }
}
