import Foundation
import Synchronization

/// Every user-tweakable synth parameter. Raw values double as indices into
/// ParamStore, and the case names double as preset JSON keys later.
enum ParamID: Int, CaseIterable {
    case osc1Wave, osc1Octave, osc1Level
    case osc2Wave, osc2Octave, osc2Detune, osc2Level
    case osc3Wave, osc3Octave, osc3Detune, osc3Level
    case noiseLevel, oscDrift
    case cutoff, resonance, filterEnvAmount, filterKeyTrack, filterVelocity
    case filterAttack, filterDecay, filterSustain, filterRelease
    case ampAttack, ampDecay, ampSustain, ampRelease, ampVelocity
    case velocityCurve
    case lfo1Wave, lfo1Rate, lfo1Depth, lfo1Dest, lfo1Wheel
    case lfo2Wave, lfo2Rate, lfo2Depth, lfo2Dest, lfo2Wheel
    case eqLowGain, eqMidGain, eqMidFreq, eqHighGain
    case delayTime, delayFeedback, delayMix
    case reverbSize, reverbDamp, reverbMix

    /// A warm, fat 3-saw patch as the boot-up sound.
    var defaultValue: Float {
        switch self {
        case .osc1Wave, .osc2Wave, .osc3Wave: return 1      // saw
        case .osc1Octave, .osc2Octave, .osc3Octave: return 0 // 8'
        case .osc1Level: return 0.8
        case .osc2Level, .osc3Level: return 0.7
        case .osc2Detune: return 7
        case .osc3Detune: return -5
        case .noiseLevel: return 0
        case .oscDrift: return 0.3
        case .cutoff: return 0.55
        case .resonance: return 0.35
        case .filterEnvAmount: return 0.45
        case .filterKeyTrack: return 0.5
        case .filterVelocity: return 0.4
        case .filterAttack: return 0.15
        case .filterDecay: return 0.55
        case .filterSustain: return 0.3
        case .filterRelease: return 0.5
        case .ampAttack: return 0.1
        case .ampDecay: return 0.5
        case .ampSustain: return 0.8
        case .ampRelease: return 0.45
        case .ampVelocity: return 0.8
        case .velocityCurve: return 1.0
        // LFO1 boots as mod-wheel vibrato; LFO2 idle, aimed at the filter.
        case .lfo1Wave: return 0
        case .lfo1Rate: return 0.78     // ~5.5 Hz
        case .lfo1Depth: return 0.25
        case .lfo1Dest: return 0        // pitch
        case .lfo1Wheel: return 1
        case .lfo2Wave: return 1
        case .lfo2Rate: return 0.35
        case .lfo2Depth: return 0
        case .lfo2Dest: return 1        // filter
        case .lfo2Wheel: return 0
        case .eqLowGain, .eqMidGain, .eqHighGain: return 0
        case .eqMidFreq: return 0.5
        case .delayTime: return 0.3
        case .delayFeedback: return 0.35
        case .delayMix: return 0.18
        case .reverbSize: return 0.55
        case .reverbDamp: return 0.4
        case .reverbMix: return 0.22
        }
    }
}

extension ParamID {
    /// Stable string key used in preset JSON.
    var key: String { String(describing: self) }
    static let byKey: [String: ParamID] =
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.key, $0) })
}

final class AtomicFloat: @unchecked Sendable {
    private let bits: Atomic<UInt32>
    init(_ value: Float) { bits = Atomic(value.bitPattern) }
    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

/// Lock-free parameter table: the UI writes, the audio thread snapshots once
/// per buffer.
final class ParamStore: @unchecked Sendable {
    private let values: [AtomicFloat]

    init() {
        values = ParamID.allCases.map { AtomicFloat($0.defaultValue) }
    }

    subscript(id: ParamID) -> Float {
        get { values[id.rawValue].value }
        set { values[id.rawValue].value = newValue }
    }

    func snapshot() -> Patch {
        var p = Patch()
        p.osc1Wave = Int(self[.osc1Wave])
        p.osc1Octave = self[.osc1Octave]
        p.osc1Level = self[.osc1Level]
        p.osc2Wave = Int(self[.osc2Wave])
        p.osc2Octave = self[.osc2Octave]
        p.osc2Detune = self[.osc2Detune]
        p.osc2Level = self[.osc2Level]
        p.osc3Wave = Int(self[.osc3Wave])
        p.osc3Octave = self[.osc3Octave]
        p.osc3Detune = self[.osc3Detune]
        p.osc3Level = self[.osc3Level]
        p.noiseLevel = self[.noiseLevel]
        p.oscDrift = self[.oscDrift]
        p.cutoff = self[.cutoff]
        p.resonance = self[.resonance]
        p.filterEnvAmount = self[.filterEnvAmount]
        p.filterKeyTrack = self[.filterKeyTrack]
        p.filterVelocity = self[.filterVelocity]
        p.filterAttack = self[.filterAttack]
        p.filterDecay = self[.filterDecay]
        p.filterSustain = self[.filterSustain]
        p.filterRelease = self[.filterRelease]
        p.ampAttack = self[.ampAttack]
        p.ampDecay = self[.ampDecay]
        p.ampSustain = self[.ampSustain]
        p.ampRelease = self[.ampRelease]
        p.ampVelocity = self[.ampVelocity]
        p.velocityCurve = self[.velocityCurve]
        p.lfo1Wave = Int(self[.lfo1Wave])
        p.lfo1Rate = self[.lfo1Rate]
        p.lfo1Depth = self[.lfo1Depth]
        p.lfo1Dest = Int(self[.lfo1Dest])
        p.lfo1Wheel = self[.lfo1Wheel]
        p.lfo2Wave = Int(self[.lfo2Wave])
        p.lfo2Rate = self[.lfo2Rate]
        p.lfo2Depth = self[.lfo2Depth]
        p.lfo2Dest = Int(self[.lfo2Dest])
        p.lfo2Wheel = self[.lfo2Wheel]
        p.eqLowGain = self[.eqLowGain]
        p.eqMidGain = self[.eqMidGain]
        p.eqMidFreq = self[.eqMidFreq]
        p.eqHighGain = self[.eqHighGain]
        p.delayTime = self[.delayTime]
        p.delayFeedback = self[.delayFeedback]
        p.delayMix = self[.delayMix]
        p.reverbSize = self[.reverbSize]
        p.reverbDamp = self[.reverbDamp]
        p.reverbMix = self[.reverbMix]
        return p
    }
}

/// Plain-value copy of all parameters, taken once per audio buffer.
struct Patch {
    var osc1Wave = 1; var osc1Octave: Float = 0; var osc1Level: Float = 0
    var osc2Wave = 1; var osc2Octave: Float = 0; var osc2Detune: Float = 0; var osc2Level: Float = 0
    var osc3Wave = 1; var osc3Octave: Float = 0; var osc3Detune: Float = 0; var osc3Level: Float = 0
    var noiseLevel: Float = 0
    var oscDrift: Float = 0
    var cutoff: Float = 0.5; var resonance: Float = 0
    var filterEnvAmount: Float = 0; var filterKeyTrack: Float = 0; var filterVelocity: Float = 0
    var filterAttack: Float = 0; var filterDecay: Float = 0; var filterSustain: Float = 1; var filterRelease: Float = 0
    var ampAttack: Float = 0; var ampDecay: Float = 0; var ampSustain: Float = 1; var ampRelease: Float = 0
    var ampVelocity: Float = 1
    var velocityCurve: Float = 1
    var lfo1Wave = 0; var lfo1Rate: Float = 0.5; var lfo1Depth: Float = 0; var lfo1Dest = 0; var lfo1Wheel: Float = 0
    var lfo2Wave = 0; var lfo2Rate: Float = 0.5; var lfo2Depth: Float = 0; var lfo2Dest = 1; var lfo2Wheel: Float = 0
    var eqLowGain: Float = 0; var eqMidGain: Float = 0; var eqMidFreq: Float = 0.5; var eqHighGain: Float = 0
    var delayTime: Float = 0.3; var delayFeedback: Float = 0.35; var delayMix: Float = 0
    var reverbSize: Float = 0.5; var reverbDamp: Float = 0.4; var reverbMix: Float = 0
}

enum ParamMap {
    /// Normalized 0...1 -> 20 Hz ... ~20.5 kHz, exponential.
    static func cutoffHz(_ norm: Float) -> Float {
        20.0 * exp2f(norm * 10.0)
    }

    /// Normalized 0...1 -> 1 ms ... 5 s, exponential.
    static func seconds(_ norm: Float) -> Float {
        0.001 * powf(5000.0, norm)
    }

    static func timeLabel(_ norm: Float) -> String {
        let s = seconds(norm)
        return s < 1 ? String(format: "%.0f ms", s * 1000) : String(format: "%.2f s", s)
    }

    static func cutoffLabel(_ norm: Float) -> String {
        hzLabel(cutoffHz(norm))
    }

    static func hzLabel(_ hz: Float) -> String {
        hz < 1000 ? String(format: "%.0f Hz", hz) : String(format: "%.2f kHz", hz / 1000)
    }

    /// Normalized 0...1 -> 20 ms ... 1.2 s, linear.
    static func delaySeconds(_ norm: Float) -> Float {
        0.02 + norm * 1.18
    }

    /// Normalized 0...1 -> 250 Hz ... 5 kHz, exponential (Pultec mid bell).
    static func eqMidHz(_ norm: Float) -> Float {
        250.0 * exp2f(norm * 4.32)
    }

    /// Normalized 0...1 -> 0.05 Hz ... 20 Hz, exponential.
    static func lfoHz(_ norm: Float) -> Float {
        0.05 * powf(400.0, norm)
    }
}
