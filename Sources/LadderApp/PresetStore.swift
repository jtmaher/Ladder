import Foundation

/// One saved patch. Params are keyed by ParamID case name; missing keys fall
/// back to defaults and unknown keys are ignored, so presets survive future
/// parameter additions.
struct Preset: Codable {
    var name: String
    var params: [String: Float]

    init(name: String, values: [Float]) {
        self.name = name
        var dict: [String: Float] = [:]
        for id in ParamID.allCases {
            dict[id.key] = values[id.rawValue]
        }
        params = dict
    }

    init(name: String, overrides: [ParamID: Float]) {
        self.name = name
        var dict: [String: Float] = [:]
        for id in ParamID.allCases {
            dict[id.key] = overrides[id] ?? id.defaultValue
        }
        params = dict
    }

    func value(for id: ParamID) -> Float {
        params[id.key] ?? id.defaultValue
    }
}

/// Reads and writes preset JSON files in Application Support. Main thread only.
final class PresetStore {
    let directory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
        directory = appSupport.appendingPathComponent("Ladder/Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        installFactoryPresetsIfNeeded()
    }

    func listNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Preset.self, from: Data(contentsOf: $0)).name }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func load(name: String) -> Preset? {
        guard let data = try? Data(contentsOf: fileURL(for: name)) else { return nil }
        return try? JSONDecoder().decode(Preset.self, from: data)
    }

    func save(_ preset: Preset) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: fileURL(for: preset.name))
    }

    func delete(name: String) {
        try? FileManager.default.removeItem(at: fileURL(for: name))
    }

    private func fileURL(for name: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let safe = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return directory.appendingPathComponent("\(safe).json")
    }

    private func installFactoryPresetsIfNeeded() {
        guard listNames().isEmpty else { return }
        for preset in Self.factoryPresets {
            try? save(preset)
        }
    }

    static let factoryPresets: [Preset] = [
        Preset(name: "Fat Saws", overrides: [:]),

        Preset(name: "Phat Bass", overrides: [
            .osc1Octave: -1, .osc2Octave: -1, .osc2Detune: 5,
            .osc3Wave: 2, .osc3Octave: -2, .osc3Level: 0.5,
            .cutoff: 0.45, .resonance: 0.3, .filterEnvAmount: 0.5,
            .filterKeyTrack: 0.3, .filterDecay: 0.45, .filterSustain: 0.15,
            .ampSustain: 0.9, .ampRelease: 0.3, .filterRelease: 0.3,
        ]),

        Preset(name: "Funky Pluck", overrides: [
            .cutoff: 0.35, .resonance: 0.55, .filterEnvAmount: 0.6,
            .filterDecay: 0.38, .filterSustain: 0.05, .filterVelocity: 0.6,
            .ampDecay: 0.55, .ampSustain: 0.6, .ampRelease: 0.35,
        ]),

        Preset(name: "Warm Pad", overrides: [
            .osc1Wave: 0, .osc2Detune: 10, .osc3Detune: -12,
            .cutoff: 0.5, .resonance: 0.2, .filterEnvAmount: 0.2,
            .filterAttack: 0.7, .filterSustain: 0.8,
            .ampAttack: 0.68, .ampRelease: 0.8, .filterRelease: 0.8,
            .ampVelocity: 0.5,
        ]),

        Preset(name: "Square Lead", overrides: [
            .osc1Wave: 2, .osc2Wave: 2, .osc2Detune: 10, .osc3Level: 0,
            .cutoff: 0.65, .resonance: 0.4, .filterEnvAmount: 0.35,
            .filterSustain: 0.5, .ampSustain: 0.9,
        ]),

        Preset(name: "Breath", overrides: [
            .osc1Wave: 0, .osc1Level: 0.4, .osc2Level: 0, .osc3Level: 0,
            .noiseLevel: 0.6, .cutoff: 0.6, .resonance: 0.6,
            .filterKeyTrack: 0.8, .filterEnvAmount: 0.15,
            .ampAttack: 0.5, .ampRelease: 0.6,
        ]),
    ]
}
