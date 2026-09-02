import Foundation

// MARK: - Envelope

struct ADSR {
    enum Stage { case idle, attack, decay, sustain, release }
    private(set) var stage: Stage = .idle
    private(set) var level: Float = 0

    mutating func gateOn() { stage = .attack }
    mutating func gateOff() { if stage != .idle { stage = .release } }

    /// Exponential segments; attack overshoots toward 1.3 for a punchy knee.
    mutating func next(attack: Float, decay: Float, sustain: Float, release: Float) -> Float {
        switch stage {
        case .idle:
            level = 0
        case .attack:
            level += (1.3 - level) * attack
            if level >= 1.0 { level = 1.0; stage = .decay }
        case .decay:
            level += (sustain - level) * decay
            if abs(level - sustain) < 0.001 { stage = .sustain }
        case .sustain:
            level += (sustain - level) * decay   // tracks the knob smoothly
        case .release:
            level -= level * release
            if level < 1e-4 { level = 0; stage = .idle }
        }
        return level
    }
}

// MARK: - Oscillator

@inline(__always)
private func polyBLEP(_ t: Double, _ dt: Double) -> Double {
    if t < dt {
        let x = t / dt
        return x + x - x * x - 1
    } else if t > 1 - dt {
        let x = (t - 1) / dt
        return x * x + x + x + 1
    }
    return 0
}

/// wave: 0 = triangle, 1 = saw, 2 = square, 3 = 25% pulse
@inline(__always)
private func oscSample(wave: Int, t: Double, dt: Double) -> Float {
    switch wave {
    case 0:
        // Naive triangle; its harmonics fall off at 1/n^2 so aliasing is mild.
        return Float(t < 0.5 ? 4 * t - 1 : 3 - 4 * t)
    case 2:
        var v: Double = t < 0.5 ? 1 : -1
        v += polyBLEP(t, dt)
        v -= polyBLEP((t + 0.5).truncatingRemainder(dividingBy: 1), dt)
        return Float(v)
    case 3:
        var v: Double = t < 0.25 ? 1 : -1
        v += polyBLEP(t, dt)
        v -= polyBLEP((t + 0.75).truncatingRemainder(dividingBy: 1), dt)
        return Float(v)
    default:
        return Float(2 * t - 1 - polyBLEP(t, dt))
    }
}

// MARK: - Moog ladder filter (Huovilainen model, 2x oversampled)

struct LadderFilter {
    private var d0: Float = 0, d1: Float = 0, d2: Float = 0, d3: Float = 0
    private var d4: Float = 0, d5: Float = 0
    private var t0: Float = 0, t1: Float = 0, t2: Float = 0

    private static let thermal: Float = 0.000025

    mutating func process(_ input: Float, cutoff: Float, resonance: Float, sampleRate: Float) -> Float {
        let fc = min(max(cutoff, 20), sampleRate * 0.45) / sampleRate
        let f = fc * 0.5  // oversampled rate
        let fc2 = fc * fc
        let fcr = 1.8730 * fc2 * fc + 0.4955 * fc2 - 0.6490 * fc + 0.9988
        let acr = -3.9364 * fc2 + 1.8409 * fc + 0.9968
        let tune = (1.0 - expf(-2.0 * .pi * f * fcr)) / Self.thermal
        let resQuad = 4.0 * resonance * acr

        for _ in 0..<2 {
            let inp = input - resQuad * d5
            let stage0 = d0 + tune * (tanhf(inp * Self.thermal) - t0)
            d0 = stage0
            t0 = tanhf(stage0 * Self.thermal)
            let stage1 = d1 + tune * (t0 - t1)
            d1 = stage1
            t1 = tanhf(stage1 * Self.thermal)
            let stage2 = d2 + tune * (t1 - t2)
            d2 = stage2
            t2 = tanhf(stage2 * Self.thermal)
            let stage3 = d3 + tune * (t2 - tanhf(d3 * Self.thermal))
            d3 = stage3
            d5 = (stage3 + d4) * 0.5
            d4 = stage3
        }
        return d5
    }
}

// MARK: - Polyphonic synth

/// 16-voice Minimoog-style engine: 3 oscillators + noise -> ladder filter ->
/// amp, with independent filter and amp ADSRs, velocity to loudness and
/// brightness, key tracking, and sustain pedal.
/// Lives entirely on the audio thread; all state is preallocated.
struct PolySynth {
    struct Voice {
        var note: UInt8 = 0
        var velocity: Float = 0     // raw 0...1 from MIDI
        var isActive = false
        var isHeld = false
        var sustained = false

        var baseFreq: Double = 0
        var t1 = 0.0, t2 = 0.0, t3 = 0.0    // osc phases, 0...1
        var noiseState: UInt32 = 0x12345678

        // Analog drift: each osc slowly wanders toward a random pitch target.
        var drift1: Float = 0, drift2: Float = 0, drift3: Float = 0
        var driftT1: Float = 0, driftT2: Float = 0, driftT3: Float = 0
        var driftCountdown = 0
        var filter = LadderFilter()
        var ampEnv = ADSR()
        var filterEnv = ADSR()
        var smoothCutoff: Float = -1        // smoothed normalized cutoff; -1 = snap on first use
    }

    static let voiceCount = 16

    private var voices: [Voice]
    private var sustainDown = false
    private let sampleRate: Float
    private let cutoffSmooth: Float   // ~5 ms one-pole on the cutoff knob

    // Global LFOs, rendered per-sample into preallocated buffers each render call.
    private let lfoBuf1: UnsafeMutablePointer<Float>
    private let lfoBuf2: UnsafeMutablePointer<Float>
    private var lfoPhase1 = 0.0
    private var lfoPhase2 = 0.0
    private var lfoSH1: Float = 0
    private var lfoSH2: Float = 0
    private var lfoRng: UInt32 = 0xBEE55EED

    private(set) var activeVoiceCount = 0

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        cutoffSmooth = 1 - expf(Float(-1.0 / (0.005 * sampleRate)))
        voices = [Voice](repeating: Voice(), count: Self.voiceCount)
        for i in 0..<Self.voiceCount { voices[i].noiseState = UInt32(0x9E3779B9) &* UInt32(i + 1) }
        lfoBuf1 = .allocate(capacity: 8192)
        lfoBuf2 = .allocate(capacity: 8192)
        lfoBuf1.initialize(repeating: 0, count: 8192)
        lfoBuf2.initialize(repeating: 0, count: 8192)
    }

    mutating func noteOn(note: UInt8, velocity: Float) {
        let index = voiceIndexFor(note: note)
        voices[index].note = note
        voices[index].velocity = velocity
        voices[index].isHeld = true
        voices[index].sustained = false
        voices[index].baseFreq = 440.0 * pow(2.0, (Double(note) - 69.0) / 12.0)
        voices[index].ampEnv.gateOn()
        voices[index].filterEnv.gateOn()
        voices[index].isActive = true
    }

    mutating func noteOff(note: UInt8) {
        for i in 0..<Self.voiceCount where voices[i].isHeld && voices[i].note == note {
            voices[i].isHeld = false
            if sustainDown {
                voices[i].sustained = true
            } else {
                voices[i].ampEnv.gateOff()
                voices[i].filterEnv.gateOff()
            }
        }
    }

    mutating func allNotesOff() {
        for i in 0..<Self.voiceCount where voices[i].isHeld || voices[i].sustained {
            voices[i].isHeld = false
            voices[i].sustained = false
            voices[i].ampEnv.gateOff()
            voices[i].filterEnv.gateOff()
        }
    }

    mutating func setSustain(_ down: Bool) {
        sustainDown = down
        if !down {
            for i in 0..<Self.voiceCount where voices[i].sustained {
                voices[i].sustained = false
                voices[i].ampEnv.gateOff()
                voices[i].filterEnv.gateOff()
            }
        }
    }

    /// Reuse the voice already playing this note, else a free voice,
    /// else steal the quietest one.
    private func voiceIndexFor(note: UInt8) -> Int {
        var quietest = 0
        var quietestLevel = Float.greatestFiniteMagnitude
        for i in 0..<Self.voiceCount {
            if voices[i].isActive && voices[i].note == note { return i }
            if !voices[i].isActive {
                if quietestLevel >= 0 { quietestLevel = -1; quietest = i }
            } else if quietestLevel >= 0 && voices[i].ampEnv.level < quietestLevel {
                quietestLevel = voices[i].ampEnv.level
                quietest = i
            }
        }
        return quietest
    }

    private static func fillLFO(_ buf: UnsafeMutablePointer<Float>,
                                phase: inout Double, sh: inout Float, rng: inout UInt32,
                                wave: Int, rateNorm: Float,
                                frameCount: Int, sampleRate: Float) {
        let inc = Double(ParamMap.lfoHz(rateNorm)) / Double(sampleRate)
        for f in 0..<frameCount {
            phase += inc
            if phase >= 1 {
                phase -= 1
                sh = nextRand(&rng) * 2 - 1
            }
            let p = Float(phase)
            switch wave {
            case 0: buf[f] = sinf(2 * .pi * p)
            case 1: buf[f] = 1 - 4 * abs(p - 0.5)
            case 2: buf[f] = p < 0.5 ? 1 : -1
            default: buf[f] = sh
            }
        }
    }

    mutating func render(left: UnsafeMutablePointer<Float>,
                         right: UnsafeMutablePointer<Float>,
                         frameCount: Int,
                         patch: Patch,
                         pitchBendSemitones: Float,
                         modWheel: Float,
                         masterGain: Float) {
        var sounding = 0
        let sr = Double(sampleRate)
        let bend = pow(2.0, Double(pitchBendSemitones) / 12.0)

        // Per-buffer derived values shared by all voices.
        let aAtk = envCoeff(patch.ampAttack)
        let aDec = envCoeff(patch.ampDecay)
        let aRel = envCoeff(patch.ampRelease)
        let fAtk = envCoeff(patch.filterAttack)
        let fDec = envCoeff(patch.filterDecay)
        let fRel = envCoeff(patch.filterRelease)
        let oct1 = pow(2.0, Double(patch.osc1Octave))
        let oct2 = pow(2.0, Double(patch.osc2Octave) + Double(patch.osc2Detune) / 1200.0)
        let oct3 = pow(2.0, Double(patch.osc3Octave) + Double(patch.osc3Detune) / 1200.0)
        let filterEnvOctaves = patch.filterEnvAmount * 6.0
        let resonance = patch.resonance
        let makeup = 1.0 + resonance   // ladder loses passband gain as resonance rises

        // LFOs: render both into their buffers, then fold destination + wheel
        // scaling into per-route coefficients shared by all voices.
        let frames = min(frameCount, 8192)
        var p1 = lfoPhase1, p2 = lfoPhase2
        var sh1 = lfoSH1, sh2 = lfoSH2
        var rng = lfoRng
        Self.fillLFO(lfoBuf1, phase: &p1, sh: &sh1, rng: &rng,
                     wave: patch.lfo1Wave, rateNorm: patch.lfo1Rate,
                     frameCount: frames, sampleRate: sampleRate)
        Self.fillLFO(lfoBuf2, phase: &p2, sh: &sh2, rng: &rng,
                     wave: patch.lfo2Wave, rateNorm: patch.lfo2Rate,
                     frameCount: frames, sampleRate: sampleRate)
        lfoPhase1 = p1; lfoPhase2 = p2
        lfoSH1 = sh1; lfoSH2 = sh2
        lfoRng = rng

        let depth1 = patch.lfo1Depth * (patch.lfo1Wheel > 0.5 ? modWheel : 1)
        let depth2 = patch.lfo2Depth * (patch.lfo2Wheel > 0.5 ? modWheel : 1)
        let pitchCents1: Float = patch.lfo1Dest == 0 ? depth1 * 100 : 0
        let pitchCents2: Float = patch.lfo2Dest == 0 ? depth2 * 100 : 0
        let filterOct1: Float = patch.lfo1Dest == 1 ? depth1 * 4 : 0
        let filterOct2: Float = patch.lfo2Dest == 1 ? depth2 * 4 : 0
        let ampDepth1: Float = patch.lfo1Dest == 2 ? depth1 : 0
        let ampDepth2: Float = patch.lfo2Dest == 2 ? depth2 : 0
        let hasPitchLFO = pitchCents1 != 0 || pitchCents2 != 0
        let hasAmpLFO = ampDepth1 != 0 || ampDepth2 != 0

        for i in 0..<Self.voiceCount {
            guard voices[i].isActive else { continue }
            sounding += 1
            var v = voices[i]

            let shapedVel = powf(max(v.velocity, 0.0001), patch.velocityCurve)
            let velGain = (1 - patch.ampVelocity) + patch.ampVelocity * shapedVel * shapedVel
            let velOctaves = patch.filterVelocity * shapedVel * 3.0
            let keyOctaves = patch.filterKeyTrack * Float(Int(v.note) - 60) / 12.0
            let modOctaves = velOctaves + keyOctaves

            // Drift evolves at buffer rate: pick a fresh random target for each
            // osc every 0.15-0.65 s, glide toward it with a ~0.4 s time constant.
            // Phase stays continuous, so buffer-rate frequency nudges are inaudible
            // as steps.
            var driftF1 = 1.0, driftF2 = 1.0, driftF3 = 1.0
            if patch.oscDrift > 0.001 {
                v.driftCountdown -= frameCount
                if v.driftCountdown <= 0 {
                    v.driftCountdown = Int(sampleRate * (0.15 + 0.5 * Self.nextRand(&v.noiseState)))
                    v.driftT1 = Self.nextRand(&v.noiseState) * 2 - 1
                    v.driftT2 = Self.nextRand(&v.noiseState) * 2 - 1
                    v.driftT3 = Self.nextRand(&v.noiseState) * 2 - 1
                }
                let alpha = min(1, Float(frameCount) / (0.4 * sampleRate))
                v.drift1 += (v.driftT1 - v.drift1) * alpha
                v.drift2 += (v.driftT2 - v.drift2) * alpha
                v.drift3 += (v.driftT3 - v.drift3) * alpha
                let depth = patch.oscDrift * 10.0 / 1200.0   // up to ±10 cents
                driftF1 = Double(exp2f(v.drift1 * depth))
                driftF2 = Double(exp2f(v.drift2 * depth))
                driftF3 = Double(exp2f(v.drift3 * depth))
            }

            let inc1 = v.baseFreq * oct1 * bend * driftF1 / sr
            let inc2 = v.baseFreq * oct2 * bend * driftF2 / sr
            let inc3 = v.baseFreq * oct3 * bend * driftF3 / sr
            if v.smoothCutoff < 0 { v.smoothCutoff = patch.cutoff }

            for frame in 0..<frameCount {
                let aEnv = v.ampEnv.next(attack: aAtk, decay: aDec, sustain: patch.ampSustain, release: aRel)
                if v.ampEnv.stage == .idle { break }
                let fEnv = v.filterEnv.next(attack: fAtk, decay: fDec, sustain: patch.filterSustain, release: fRel)

                v.smoothCutoff += (patch.cutoff - v.smoothCutoff) * cutoffSmooth

                var mix: Float = 0
                mix += patch.osc1Level * oscSample(wave: patch.osc1Wave, t: v.t1, dt: inc1)
                mix += patch.osc2Level * oscSample(wave: patch.osc2Wave, t: v.t2, dt: inc2)
                mix += patch.osc3Level * oscSample(wave: patch.osc3Wave, t: v.t3, dt: inc3)
                if patch.noiseLevel > 0 {
                    v.noiseState = v.noiseState ^ (v.noiseState << 13)
                    v.noiseState = v.noiseState ^ (v.noiseState >> 17)
                    v.noiseState = v.noiseState ^ (v.noiseState << 5)
                    mix += patch.noiseLevel * (Float(v.noiseState) / Float(UInt32.max) * 2 - 1)
                }

                let lfo1 = lfoBuf1[frame]
                let lfo2 = lfoBuf2[frame]

                let cutoffHz = 20.0 * exp2f(v.smoothCutoff * 10.0 + filterEnvOctaves * fEnv
                                            + modOctaves + filterOct1 * lfo1 + filterOct2 * lfo2)
                var sample = v.filter.process(mix * 0.4, cutoff: cutoffHz,
                                              resonance: resonance, sampleRate: sampleRate)
                sample *= makeup * aEnv * velGain * masterGain
                if hasAmpLFO {
                    let tremolo = (1 - ampDepth1 * (0.5 - 0.5 * lfo1))
                                * (1 - ampDepth2 * (0.5 - 0.5 * lfo2))
                    sample *= max(0, tremolo)
                }

                left[frame] += sample
                right[frame] += sample

                var vib = 1.0
                if hasPitchLFO {
                    vib = Double(exp2f((pitchCents1 * lfo1 + pitchCents2 * lfo2) / 1200))
                }
                v.t1 += inc1 * vib; if v.t1 >= 1 { v.t1 -= 1 }
                v.t2 += inc2 * vib; if v.t2 >= 1 { v.t2 -= 1 }
                v.t3 += inc3 * vib; if v.t3 >= 1 { v.t3 -= 1 }
            }

            if v.ampEnv.stage == .idle && !v.isHeld && !v.sustained {
                v.isActive = false
            }
            voices[i] = v
        }
        activeVoiceCount = sounding
    }

    @inline(__always)
    private static func nextRand(_ state: inout UInt32) -> Float {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Float(state) / Float(UInt32.max)
    }

    private func envCoeff(_ norm: Float) -> Float {
        1 - expf(-1.0 / (ParamMap.seconds(norm) * sampleRate))
    }
}
