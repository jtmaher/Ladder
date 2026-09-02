import SwiftUI
import CoreText

@main
struct LadderApp: App {
    @State private var model = EngineModel()

    init() {
        // Segmented LED font (DSEG, SIL OFL) for the status displays.
        if let url = Bundle.module.url(forResource: "DSEG14Classic-Regular",
                                       withExtension: "ttf",
                                       subdirectory: "Resources") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    var body: some Scene {
        WindowGroup("Ladder") {
            ContentView(model: model)
                .onAppear {
                    // Launched as a bare SPM executable there is no app bundle,
                    // so promote ourselves to a regular foreground app.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)
    }
}

@Observable
final class EngineModel {
    let engine = AudioEngine()
    private var midi: MidiInput?
    private var pollTimer: Timer?

    var stats = EngineStats()
    var startupError: String?
    var midiSources: [String] = []
    var activeVoices = 0
    var lastNoteText = "—"

    // Mirror of ParamStore for SwiftUI observation; writes go to both.
    var paramValues: [Float] = ParamID.allCases.map { $0.defaultValue }

    enum PanelMode { case play, tweak }
    var mode: PanelMode = .play

    let presets = PresetStore()
    var presetNames: [String] = []
    var currentPresetName = "Fat Saws"
    var isDirty = false
    var vis: VisProcessor?

    func param(_ id: ParamID) -> Binding<Float> {
        Binding(
            get: { self.paramValues[id.rawValue] },
            set: { newValue in
                self.setParam(id, to: newValue)
                self.isDirty = true
            }
        )
    }

    func intParam(_ id: ParamID) -> Binding<Int> {
        Binding(
            get: { Int(self.paramValues[id.rawValue].rounded()) },
            set: { newValue in
                self.setParam(id, to: Float(newValue))
                self.isDirty = true
            }
        )
    }

    private func setParam(_ id: ParamID, to newValue: Float) {
        paramValues[id.rawValue] = newValue
        engine.params[id] = newValue
    }

    func loadPreset(named name: String) {
        guard let preset = presets.load(name: name) else { return }
        for id in ParamID.allCases {
            setParam(id, to: preset.value(for: id))
        }
        currentPresetName = preset.name
        isDirty = false
    }

    /// Save the current sound under `name` (overwrites an existing preset of
    /// the same name).
    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try? presets.save(Preset(name: trimmed, values: paramValues))
        currentPresetName = trimmed
        isDirty = false
        presetNames = presets.listNames()
    }

    func deletePreset(named name: String) {
        presets.delete(name: name)
        presetNames = presets.listNames()
        if currentPresetName == name {
            isDirty = true
        }
    }

    var demoIndex = -1 {
        didSet { engine.demoSelect.store(demoIndex, ordering: .relaxed) }
    }

    var toneOn = false {
        didSet { engine.toneOn.store(toneOn, ordering: .relaxed) }
    }
    var frequency: Float = 220 {
        didSet { engine.frequency.store(frequency.bitPattern, ordering: .relaxed) }
    }
    var gain: Float = 0.2 {
        didSet { engine.targetGain.store(gain.bitPattern, ordering: .relaxed) }
    }
    var masterGain: Float = 0.35 {
        didSet { engine.masterGain.store(masterGain.bitPattern, ordering: .relaxed) }
    }

    init() {
        do {
            try engine.start(preferredBufferFrames: 128)
            stats = engine.stats
        } catch {
            startupError = error.localizedDescription
            return
        }

        let midi = MidiInput(fifo: engine.midiFIFO)
        midi.onSourcesChanged = { [weak self] names in
            self?.midiSources = names
        }
        midi.start()
        self.midi = midi

        presetNames = presets.listNames()
        vis = VisProcessor(fifo: engine.visFIFO, sampleRate: Float(stats.sampleRate))

        // .common mode so the timer keeps firing during knob drags
        // (the default mode is paused while the run loop tracks the mouse).
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.vis?.poll()
                self.activeVoices = Int(self.engine.uiActiveVoices.load(ordering: .relaxed))
                let note = self.engine.uiLastNote.load(ordering: .relaxed)
                let velocity = Float(bitPattern: self.engine.uiLastVelocity.load(ordering: .relaxed))
                if note > 0 {
                    self.lastNoteText = "\(Self.noteName(UInt8(note))) VEL \(Int(velocity * 127))"
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // Flats, not sharps: the segmented LED font has no '#' glyph, but its
    // lowercase 'b' reads as a flat sign — the classic hardware-tuner trick.
    static func noteName(_ note: UInt8) -> String {
        let names = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 1)"
    }
}
