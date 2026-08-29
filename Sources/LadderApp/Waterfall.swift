import Accelerate
import SwiftUI

/// Pulls output samples from the engine's FIFO, runs a windowed FFT, and keeps
/// a rolling history of log-spaced spectra for the waterfall. Main thread only.
@Observable
final class VisProcessor {
    static let fftSize = 4096
    static let log2n: vDSP_Length = 12
    static let displayBins = 640
    static let historyRows = 90
    /// New row every `hop` samples, decoupled from fftSize so a bigger window
    /// doesn't slow the scroll rate.
    static let hop = 5120

    private let fifo: SampleFIFO
    private let sampleRate: Float
    private let fftSetup: FFTSetup
    private var window = [Float](repeating: 0, count: fftSize)
    private var windowed = [Float](repeating: 0, count: fftSize)
    private var realPart = [Float](repeating: 0, count: fftSize / 2)
    private var imagPart = [Float](repeating: 0, count: fftSize / 2)
    private var magnitudes = [Float](repeating: 0, count: fftSize / 2)
    private var recent = [Float](repeating: 0, count: fftSize)  // last fftSize samples seen
    private var drainBuffer = [Float](repeating: 0, count: 8192)
    private var newSamples = 0
    private let binRanges: [Range<Int>]

    /// Rows of normalized 0...1 magnitudes, oldest first.
    private(set) var history: [[Float]] = []

    init(fifo: SampleFIFO, sampleRate: Float) {
        self.fifo = fifo
        self.sampleRate = sampleRate
        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        var hann = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&hann, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))

        // Log-spaced display bins, 30 Hz ... 16 kHz.
        let binHz = sampleRate / Float(Self.fftSize)
        var ranges: [Range<Int>] = []
        for k in 0..<Self.displayBins {
            let f0 = 30.0 * powf(16000.0 / 30.0, Float(k) / Float(Self.displayBins))
            let f1 = 30.0 * powf(16000.0 / 30.0, Float(k + 1) / Float(Self.displayBins))
            let lo = max(1, Int(f0 / binHz))
            let hi = min(Self.fftSize / 2 - 1, max(lo + 1, Int(f1 / binHz)))
            ranges.append(lo..<hi)
        }
        binRanges = ranges
        window = hann
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Called ~30x/sec by a UI timer.
    func poll() {
        let got = fifo.pop(into: &drainBuffer)
        guard got > 0 else { return }
        if got >= Self.fftSize {
            recent.replaceSubrange(0..<Self.fftSize,
                                   with: drainBuffer[(got - Self.fftSize)..<got])
        } else {
            recent.removeFirst(got)
            recent.append(contentsOf: drainBuffer[0..<got])
        }
        newSamples += got
        guard newSamples >= Self.hop else { return }
        newSamples = 0
        appendRow(computeSpectrum())
    }

    private func computeSpectrum() -> [Float] {
        vDSP_vmul(recent, 1, window, 1, &windowed, 1, vDSP_Length(Self.fftSize))
        realPart.withUnsafeMutableBufferPointer { real in
            imagPart.withUnsafeMutableBufferPointer { imag in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              &split, 1, vDSP_Length(Self.fftSize / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
            }
        }

        var row = [Float](repeating: 0, count: Self.displayBins)
        let scale = 1.0 / Float(Self.fftSize)
        for k in 0..<Self.displayBins {
            var peak: Float = 0
            for b in binRanges[k] where magnitudes[b] > peak { peak = magnitudes[b] }
            let amplitude = sqrtf(peak) * scale
            let db = 20 * log10f(amplitude + 1e-7)
            row[k] = min(1, max(0, (db + 60) / 60))
        }
        return row
    }

    private func appendRow(_ row: [Float]) {
        history.append(row)
        if history.count > Self.historyRows {
            history.removeFirst(history.count - Self.historyRows)
        }
    }
}

/// Perspective ridgeline waterfall: newest spectrum front-and-bottom in hot
/// magenta, receding into cyan haze.
struct WaterfallView: View {
    var vis: VisProcessor

    var body: some View {
        Canvas { context, size in
            let rows = vis.history
            guard rows.count > 1 else { return }
            let count = rows.count
            let topPad: CGFloat = 12
            let baseBand = size.height - topPad

            for (i, row) in rows.enumerated() {
                let t = CGFloat(i) / CGFloat(count - 1)   // 0 = oldest/back
                let inset = (1 - t) * size.width * 0.07
                let yBase = topPad + t * baseBand * 0.92 + baseBand * 0.06
                let amplitude = (18 + t * 42)

                var path = Path()
                let n = row.count
                for j in 0..<n {
                    let x = inset + (size.width - 2 * inset) * CGFloat(j) / CGFloat(n - 1)
                    let y = yBase - CGFloat(row[j]) * amplitude
                    if j == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }

                // Opaque fill under the line so front rows occlude back rows.
                var silhouette = path
                silhouette.addLine(to: CGPoint(x: size.width - inset, y: yBase + 2))
                silhouette.addLine(to: CGPoint(x: inset, y: yBase + 2))
                silhouette.closeSubpath()
                context.fill(silhouette, with: .color(Theme.bg.opacity(0.92)))

                let color = Color(
                    red: 0.1 + 0.9 * t,
                    green: 0.85 - 0.65 * t,
                    blue: 1.0 - 0.16 * t
                )
                // With densely packed rows, keep the back rows faint so the
                // overlap doesn't bloom into a solid glow.
                context.stroke(path, with: .color(color.opacity(0.1 + 0.8 * t * t)),
                               lineWidth: t > 0.95 ? 1.5 : 1.0)
            }
        }
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.cyan.opacity(0.25), lineWidth: 1)
        )
    }
}
