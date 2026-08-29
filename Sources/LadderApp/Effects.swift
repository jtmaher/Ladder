import Foundation
import Synchronization

// MARK: - RBJ biquad (Audio EQ Cookbook)

struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0
    private var a1: Float = 0, a2: Float = 0
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    mutating func setLowShelf(freq: Float, gainDB: Float, sampleRate: Float) {
        let A = powf(10, gainDB / 40)
        let w = 2 * Float.pi * freq / sampleRate
        let alpha = sinf(w) / 2 * sqrtf(2)
        let cw = cosf(w)
        let sqA = sqrtf(A)
        let a0 = (A + 1) + (A - 1) * cw + 2 * sqA * alpha
        b0 = A * ((A + 1) - (A - 1) * cw + 2 * sqA * alpha) / a0
        b1 = 2 * A * ((A - 1) - (A + 1) * cw) / a0
        b2 = A * ((A + 1) - (A - 1) * cw - 2 * sqA * alpha) / a0
        a1 = -2 * ((A - 1) + (A + 1) * cw) / a0
        a2 = ((A + 1) + (A - 1) * cw - 2 * sqA * alpha) / a0
    }

    mutating func setHighShelf(freq: Float, gainDB: Float, sampleRate: Float) {
        let A = powf(10, gainDB / 40)
        let w = 2 * Float.pi * freq / sampleRate
        let alpha = sinf(w) / 2 * sqrtf(2)
        let cw = cosf(w)
        let sqA = sqrtf(A)
        let a0 = (A + 1) - (A - 1) * cw + 2 * sqA * alpha
        b0 = A * ((A + 1) + (A - 1) * cw + 2 * sqA * alpha) / a0
        b1 = -2 * A * ((A - 1) + (A + 1) * cw) / a0
        b2 = A * ((A + 1) + (A - 1) * cw - 2 * sqA * alpha) / a0
        a1 = 2 * ((A - 1) - (A + 1) * cw) / a0
        a2 = ((A + 1) + (A - 1) * cw - 2 * sqA * alpha) / a0
    }

    mutating func setPeaking(freq: Float, gainDB: Float, q: Float, sampleRate: Float) {
        let A = powf(10, gainDB / 40)
        let w = 2 * Float.pi * freq / sampleRate
        let alpha = sinf(w) / (2 * q)
        let cw = cosf(w)
        let a0 = 1 + alpha / A
        b0 = (1 + alpha * A) / a0
        b1 = -2 * cw / a0
        b2 = (1 - alpha * A) / a0
        a1 = -2 * cw / a0
        a2 = (1 - alpha / A) / a0
    }
}

// MARK: - FX chain (master bus): Pultec-style EQ -> stereo delay -> Freeverb

/// All buffers are allocated in init, before the audio thread starts.
/// process() is audio-thread-only and never allocates.
final class FXChain {
    private let sampleRate: Float

    // EQ — broad, musical curves in the Pultec spirit:
    // 100 Hz low shelf, wide mid bell, 8 kHz high shelf.
    private var eqLowL = Biquad(), eqMidL = Biquad(), eqHighL = Biquad()
    private var eqLowR = Biquad(), eqMidR = Biquad(), eqHighR = Biquad()

    // Delay — cross-fed stereo, delay time smoothed per sample so moving the
    // knob gives tape-style pitch sweeps instead of clicks.
    private let delayCapacity: Int
    private let delayBufL: UnsafeMutablePointer<Float>
    private let delayBufR: UnsafeMutablePointer<Float>
    private var delayWrite = 0
    private var smoothedDelaySamples: Float

    // Freeverb: 8 combs + 4 allpasses per channel, right offset for width.
    private static let combTunings = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassTunings = [556, 441, 341, 225]
    private static let stereoSpread = 23
    private var combBufs: [UnsafeMutablePointer<Float>] = []
    private var combSizes: [Int] = []
    private var combIdx: [Int]
    private var combStore: [Float]
    private var allpassBufs: [UnsafeMutablePointer<Float>] = []
    private var allpassSizes: [Int] = []
    private var allpassIdx: [Int]

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        let srScale = sampleRate / 44100.0

        delayCapacity = Int(sampleRate * 2)
        delayBufL = .allocate(capacity: delayCapacity)
        delayBufR = .allocate(capacity: delayCapacity)
        delayBufL.initialize(repeating: 0, count: delayCapacity)
        delayBufR.initialize(repeating: 0, count: delayCapacity)
        smoothedDelaySamples = 0.3 * sampleRate

        for tuning in Self.combTunings {
            for offset in [0, Self.stereoSpread] {
                let size = Int(Float(tuning + offset) * srScale)
                let buf = UnsafeMutablePointer<Float>.allocate(capacity: size)
                buf.initialize(repeating: 0, count: size)
                combBufs.append(buf)
                combSizes.append(size)
            }
        }
        combIdx = [Int](repeating: 0, count: combBufs.count)
        combStore = [Float](repeating: 0, count: combBufs.count)

        for tuning in Self.allpassTunings {
            for offset in [0, Self.stereoSpread] {
                let size = Int(Float(tuning + offset) * srScale)
                let buf = UnsafeMutablePointer<Float>.allocate(capacity: size)
                buf.initialize(repeating: 0, count: size)
                allpassBufs.append(buf)
                allpassSizes.append(size)
            }
        }
        allpassIdx = [Int](repeating: 0, count: allpassBufs.count)
    }

    deinit {
        delayBufL.deallocate()
        delayBufR.deallocate()
        for buf in combBufs { buf.deallocate() }
        for buf in allpassBufs { buf.deallocate() }
    }

    func process(left: UnsafeMutablePointer<Float>,
                 right: UnsafeMutablePointer<Float>,
                 frameCount: Int,
                 patch: Patch) {
        // EQ coefficients once per buffer (knobs move at UI rate).
        eqLowL.setLowShelf(freq: 100, gainDB: patch.eqLowGain, sampleRate: sampleRate)
        eqLowR.setLowShelf(freq: 100, gainDB: patch.eqLowGain, sampleRate: sampleRate)
        let midHz = ParamMap.eqMidHz(patch.eqMidFreq)
        eqMidL.setPeaking(freq: midHz, gainDB: patch.eqMidGain, q: 0.6, sampleRate: sampleRate)
        eqMidR.setPeaking(freq: midHz, gainDB: patch.eqMidGain, q: 0.6, sampleRate: sampleRate)
        eqHighL.setHighShelf(freq: 8000, gainDB: patch.eqHighGain, sampleRate: sampleRate)
        eqHighR.setHighShelf(freq: 8000, gainDB: patch.eqHighGain, sampleRate: sampleRate)

        let delayTarget = ParamMap.delaySeconds(patch.delayTime) * sampleRate
        let delayFeedback = min(patch.delayFeedback, 0.9)
        let delayMix = patch.delayMix

        let roomFeedback = 0.7 + patch.reverbSize * 0.28
        let damp = patch.reverbDamp * 0.5
        let reverbMix = patch.reverbMix

        for frame in 0..<frameCount {
            var l = left[frame]
            var r = right[frame]

            l = eqHighL.process(eqMidL.process(eqLowL.process(l)))
            r = eqHighR.process(eqMidR.process(eqLowR.process(r)))

            if delayMix > 0.001 {
                smoothedDelaySamples += (delayTarget - smoothedDelaySamples) * 0.0003
                let readL = readDelay(delayBufL, at: Float(delayWrite) - smoothedDelaySamples)
                let readR = readDelay(delayBufR, at: Float(delayWrite) - smoothedDelaySamples)
                // Cross-feed for a gentle ping-pong.
                delayBufL[delayWrite] = l + readR * delayFeedback
                delayBufR[delayWrite] = r + readL * delayFeedback
                delayWrite += 1
                if delayWrite >= delayCapacity { delayWrite = 0 }
                l += readL * delayMix
                r += readR * delayMix
            }

            if reverbMix > 0.001 {
                let input = (l + r) * 0.015
                var wetL: Float = 0
                var wetR: Float = 0
                for c in 0..<8 {
                    wetL += combProcess(2 * c, input, feedback: roomFeedback, damp: damp)
                    wetR += combProcess(2 * c + 1, input, feedback: roomFeedback, damp: damp)
                }
                for a in 0..<4 {
                    wetL = allpassProcess(2 * a, wetL)
                    wetR = allpassProcess(2 * a + 1, wetR)
                }
                l += wetL * reverbMix * 3
                r += wetR * reverbMix * 3
            }

            left[frame] = l
            right[frame] = r
        }
    }

    @inline(__always)
    private func readDelay(_ buf: UnsafeMutablePointer<Float>, at position: Float) -> Float {
        var pos = position
        while pos < 0 { pos += Float(delayCapacity) }
        let i0 = Int(pos)
        let frac = pos - Float(i0)
        let a = buf[i0 % delayCapacity]
        let b = buf[(i0 + 1) % delayCapacity]
        return a + (b - a) * frac
    }

    @inline(__always)
    private func combProcess(_ i: Int, _ input: Float, feedback: Float, damp: Float) -> Float {
        let buf = combBufs[i]
        let idx = combIdx[i]
        let output = buf[idx]
        combStore[i] = output * (1 - damp) + combStore[i] * damp
        buf[idx] = input + combStore[i] * feedback
        combIdx[i] = idx + 1 == combSizes[i] ? 0 : idx + 1
        return output
    }

    @inline(__always)
    private func allpassProcess(_ i: Int, _ input: Float) -> Float {
        let buf = allpassBufs[i]
        let idx = allpassIdx[i]
        let bufOut = buf[idx]
        buf[idx] = input + bufOut * 0.5
        allpassIdx[i] = idx + 1 == allpassSizes[i] ? 0 : idx + 1
        return bufOut - input
    }
}

// MARK: - Audio -> UI sample tap (for the waterfall)

/// SPSC ring of output samples: audio thread produces, UI thread consumes.
final class SampleFIFO: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    init(capacity: Int = 16384) {
        precondition(capacity & (capacity - 1) == 0)
        self.capacity = capacity
        self.mask = capacity - 1
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    /// Push a mono mixdown of the buffer. Overwrites nothing: drops when full
    /// (the UI just misses a frame of visualization).
    func push(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let free = capacity - (t - h)
        let n = min(count, free)
        for i in 0..<n {
            storage[(t + i) & mask] = (left[i] + right[i]) * 0.5
        }
        tail.store(t + n, ordering: .releasing)
    }

    /// Drain up to `into.count` samples; returns how many were read.
    func pop(into buffer: inout [Float]) -> Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let n = min(buffer.count, t - h)
        for i in 0..<n {
            buffer[i] = storage[(h + i) & mask]
        }
        head.store(h + n, ordering: .releasing)
        return n
    }
}
