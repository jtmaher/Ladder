import SwiftUI

struct ContentView: View {
    @Bindable var model: EngineModel
    @State private var showingSaveAs = false
    @State private var saveAsName = ""

    var body: some View {
        VStack(spacing: 12) {
            headerBar
            presetBar

            if let error = model.startupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if model.mode == .play {
                playView
            } else {
                signalFlow
                if let vis = model.vis {
                    WaterfallView(vis: vis)
                        .frame(height: 180)
                }
            }
        }
        .padding(16)
        .fixedSize()
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .alert("Save preset as", isPresented: $showingSaveAs) {
            TextField("Preset name", text: $saveAsName)
            Button("Save") { model.savePreset(named: saveAsName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("LADDER")
                .font(.system(size: 26, weight: .black, design: .monospaced))
                .tracking(6)
                .foregroundStyle(
                    LinearGradient(colors: [Theme.cyan, Theme.magenta],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .shadow(color: Theme.magenta.opacity(0.6), radius: 8)
            Text("POLYPHONIC ANALOG")
                .font(Theme.led(9))
                .tracking(2)
                .foregroundStyle(Theme.green.opacity(0.8))
                .shadow(color: Theme.green.opacity(0.7), radius: 4)

            Spacer()

            Group {
                Label(model.midiSources.isEmpty ? "NO MIDI"
                        : model.midiSources.joined(separator: " + ").uppercased(),
                      systemImage: "pianokeys")
                Text(model.lastNoteText)
                    .frame(width: 130, alignment: .trailing)
                Text("\(model.activeVoices)/16")
                    .frame(width: 48, alignment: .trailing)
                Text("\(model.stats.totalOutputLatencyMS, format: .number.precision(.fractionLength(1))) MS")
                    .frame(width: 64, alignment: .trailing)
            }
            .font(Theme.led(9))
            .foregroundStyle(Theme.green)
            .shadow(color: Theme.green.opacity(0.7), radius: 4)
        }
    }

    // MARK: - Preset bar

    private var presetBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(model.presetNames, id: \.self) { name in
                    Button(name) { model.loadPreset(named: name) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(model.currentPresetName.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.5)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(Theme.cyan)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(width: 220, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.cyan.opacity(0.5), lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)

            if model.isDirty {
                Text("EDITED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.orange)
                    .shadow(color: Theme.orange, radius: 4)
            }

            Button("SAVE") { model.savePreset(named: model.currentPresetName) }
                .buttonStyle(NeonButtonStyle())
                .disabled(!model.isDirty)
            Button("SAVE AS") {
                saveAsName = model.currentPresetName
                showingSaveAs = true
            }
            .buttonStyle(NeonButtonStyle())
            Button("DELETE") { model.deletePreset(named: model.currentPresetName) }
                .buttonStyle(NeonButtonStyle(accent: Theme.magenta))

            Spacer()

            Menu {
                Button("OFF") { model.demoIndex = -1 }
                ForEach(Array(Demos.names.enumerated()), id: \.0) { i, name in
                    Button(name) { model.demoIndex = i }
                }
            } label: {
                let playing = model.demoIndex >= 0
                HStack(spacing: 6) {
                    Image(systemName: playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 8))
                    Text(playing ? Demos.names[model.demoIndex] : "DEMO")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.5)
                }
                .foregroundStyle(Theme.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(playing ? Theme.green.opacity(0.15) : Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(Theme.green.opacity(playing ? 0.9 : 0.5), lineWidth: 1))
                .shadow(color: playing ? Theme.green.opacity(0.6) : .clear, radius: 5)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)

            HStack(spacing: 4) {
                modeButton("PLAY", .play)
                modeButton("TWEAK", .tweak)
            }
        }
    }

    private func modeButton(_ title: String, _ mode: EngineModel.PanelMode) -> some View {
        let selected = model.mode == mode
        return Button {
            model.mode = mode
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selected ? Theme.magenta.opacity(0.22) : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(selected ? Theme.magenta : Color.white.opacity(0.15), lineWidth: 1)
                )
                .foregroundStyle(selected ? Theme.magenta : Theme.textDim)
                .shadow(color: selected ? Theme.magenta.opacity(0.7) : .clear, radius: 5)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Play mode

    private var playView: some View {
        VStack(spacing: 16) {
            Text("PATCH BANK")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(Theme.cyan)
                .shadow(color: Theme.cyan.opacity(0.9), radius: 5)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(Array(model.presetNames.enumerated()), id: \.element) { index, name in
                    patchCard(number: index + 1, name: name)
                }
            }

            if let vis = model.vis {
                WaterfallView(vis: vis)
                    .frame(height: 300)
            }

            HStack(spacing: 48) {
                Knob(value: $model.masterGain, range: 0...1, label: "VOLUME",
                     accent: Theme.green, size: 52, defaultValue: 0.35)
                VStack(spacing: 3) {
                    Text("\(model.activeVoices)")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(model.activeVoices > 0 ? Theme.green : Theme.textDim)
                        .shadow(color: model.activeVoices > 0 ? Theme.green.opacity(0.8) : .clear,
                                radius: 6)
                    Text("VOICES")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
        .frame(width: 1180)
    }

    private func patchCard(number: Int, name: String) -> some View {
        let selected = name == model.currentPresetName
        return Button {
            model.loadPreset(named: name)
        } label: {
            HStack(spacing: 12) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 24, weight: .black, design: .monospaced))
                    .foregroundStyle(selected ? Theme.magenta : Theme.cyan.opacity(0.45))
                    .shadow(color: selected ? Theme.magenta.opacity(0.9) : .clear, radius: 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(name.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(selected ? .white : .white.opacity(0.75))
                        .lineLimit(1)
                    Text(selected ? "◉ ACTIVE" : " ")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(Theme.magenta.opacity(0.9))
                }

                Spacer(minLength: 0)

                Image(systemName: "waveform")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.magenta : Color.white.opacity(0.1))
                    .shadow(color: selected ? Theme.magenta.opacity(0.8) : .clear, radius: 5)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [Theme.panel, Theme.panel.opacity(0.55)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Theme.magenta : Theme.cyan.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: selected ? Theme.magenta.opacity(0.35) : .black.opacity(0.4), radius: 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tweak mode: signal flow, left to right

    private var signalFlow: some View {
        HStack(alignment: .top, spacing: 4) {
            oscSection
            SignalWire(from: Theme.cyan, to: Theme.magenta).padding(.top, 90)
            filterSection
            SignalWire(from: Theme.magenta, to: Theme.purple).padding(.top, 90)
            envSection
            SignalWire(from: Theme.purple, to: Theme.yellow).padding(.top, 90)
            lfoSection
            SignalWire(from: Theme.yellow, to: Theme.orange).padding(.top, 90)
            fxSection
            SignalWire(from: Theme.orange, to: Theme.green).padding(.top, 90)
            outSection
        }
    }

    private var oscSection: some View {
        SynthSection(title: "OSCILLATORS", accent: Theme.cyan) {
            oscRow(label: "OSC 1", wave: .osc1Wave, octave: .osc1Octave,
                   detune: nil, level: .osc1Level)
            oscRow(label: "OSC 2", wave: .osc2Wave, octave: .osc2Octave,
                   detune: .osc2Detune, level: .osc2Level)
            oscRow(label: "OSC 3", wave: .osc3Wave, octave: .osc3Octave,
                   detune: .osc3Detune, level: .osc3Level)
            HStack(spacing: 4) {
                Text("ANALOG")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.cyan.opacity(0.8))
                    .frame(width: 132, alignment: .leading)
                Knob(value: model.param(.oscDrift), range: 0...1, label: "DRIFT",
                     accent: Theme.cyan, size: 38, defaultValue: 0.3)
                Knob(value: model.param(.noiseLevel), range: 0...1, label: "NOISE",
                     accent: Theme.cyan, size: 38, defaultValue: 0)
            }
        }
    }

    private func oscRow(label: String, wave: ParamID, octave: ParamID,
                        detune: ParamID?, level: ParamID) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.cyan.opacity(0.8))
                MiniSelector(selection: model.intParam(wave),
                             options: [("TRI", 0), ("SAW", 1), ("SQR", 2), ("PLS", 3)],
                             accent: Theme.cyan)
                MiniSelector(selection: model.intParam(octave),
                             options: [("32", -2), ("16", -1), ("8", 0), ("4", 1), ("2", 2)],
                             accent: Theme.cyan)
            }
            .frame(width: 132, alignment: .leading)

            if let detune {
                Knob(value: model.param(detune), range: -50...50, label: "DETUNE",
                     accent: Theme.cyan, size: 38,
                     format: { String(format: "%+.0fct", $0) }, defaultValue: 0)
            } else {
                Color.clear.frame(width: 58, height: 1)
            }
            Knob(value: model.param(level), range: 0...1, label: "LEVEL",
                 accent: Theme.cyan, size: 38, defaultValue: 0.8)
        }
    }

    private var filterSection: some View {
        SynthSection(title: "FILTER", accent: Theme.magenta) {
            Knob(value: model.param(.cutoff), range: 0...1, label: "CUTOFF",
                 accent: Theme.magenta, size: 64,
                 format: { ParamMap.cutoffLabel($0) }, defaultValue: 0.55)
            HStack(spacing: 2) {
                Knob(value: model.param(.resonance), range: 0...0.95, label: "RES",
                     accent: Theme.magenta, size: 40, defaultValue: 0.35)
                Knob(value: model.param(.filterEnvAmount), range: 0...1, label: "ENV",
                     accent: Theme.magenta, size: 40, defaultValue: 0.45)
            }
            HStack(spacing: 2) {
                Knob(value: model.param(.filterKeyTrack), range: 0...1, label: "KEYTRK",
                     accent: Theme.magenta, size: 40, defaultValue: 0.5)
                Knob(value: model.param(.filterVelocity), range: 0...1, label: "VEL",
                     accent: Theme.magenta, size: 40, defaultValue: 0.4)
            }
        }
    }

    private var envSection: some View {
        SynthSection(title: "ENVELOPES", accent: Theme.purple) {
            subheader("FILTER", Theme.purple)
            adsrRow(attack: .filterAttack, decay: .filterDecay,
                    sustain: .filterSustain, release: .filterRelease)
            subheader("AMP", Theme.purple)
            adsrRow(attack: .ampAttack, decay: .ampDecay,
                    sustain: .ampSustain, release: .ampRelease)
            subheader("VELOCITY", Theme.purple)
            HStack(spacing: 2) {
                Knob(value: model.param(.ampVelocity), range: 0...1, label: "AMOUNT",
                     accent: Theme.purple, size: 36, defaultValue: 0.8)
                Knob(value: model.param(.velocityCurve), range: 0.3...3, label: "CURVE",
                     accent: Theme.purple, size: 36, defaultValue: 1.0)
            }
        }
    }

    private func adsrRow(attack: ParamID, decay: ParamID,
                         sustain: ParamID, release: ParamID) -> some View {
        HStack(spacing: 2) {
            Knob(value: model.param(attack), range: 0...1, label: "A",
                 accent: Theme.purple, size: 34, format: { ParamMap.timeLabel($0) })
            Knob(value: model.param(decay), range: 0...1, label: "D",
                 accent: Theme.purple, size: 34, format: { ParamMap.timeLabel($0) })
            Knob(value: model.param(sustain), range: 0...1, label: "S",
                 accent: Theme.purple, size: 34)
            Knob(value: model.param(release), range: 0...1, label: "R",
                 accent: Theme.purple, size: 34, format: { ParamMap.timeLabel($0) })
        }
    }

    private var lfoSection: some View {
        SynthSection(title: "LFO", accent: Theme.yellow) {
            lfoBlock(label: "LFO 1", wave: .lfo1Wave, rate: .lfo1Rate,
                     depth: .lfo1Depth, dest: .lfo1Dest, wheel: .lfo1Wheel)
            Divider().overlay(Theme.yellow.opacity(0.2))
            lfoBlock(label: "LFO 2", wave: .lfo2Wave, rate: .lfo2Rate,
                     depth: .lfo2Depth, dest: .lfo2Dest, wheel: .lfo2Wheel)
        }
    }

    private func lfoBlock(label: String, wave: ParamID, rate: ParamID,
                          depth: ParamID, dest: ParamID, wheel: ParamID) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            subheader(label, Theme.yellow)
            MiniSelector(selection: model.intParam(wave),
                         options: [("SIN", 0), ("TRI", 1), ("SQR", 2), ("S&H", 3)],
                         accent: Theme.yellow)
            HStack(spacing: 4) {
                MiniSelector(selection: model.intParam(dest),
                             options: [("PIT", 0), ("FLT", 1), ("AMP", 2)],
                             accent: Theme.yellow)
                MiniSelector(selection: model.intParam(wheel),
                             options: [("FREE", 0), ("WHL", 1)],
                             accent: Theme.yellow)
            }
            HStack(spacing: 2) {
                Knob(value: model.param(rate), range: 0...1, label: "RATE",
                     accent: Theme.yellow, size: 36,
                     format: { String(format: "%.2fHz", ParamMap.lfoHz($0)) })
                Knob(value: model.param(depth), range: 0...1, label: "DEPTH",
                     accent: Theme.yellow, size: 36, defaultValue: 0)
            }
        }
    }

    private var fxSection: some View {
        SynthSection(title: "EFFECTS", accent: Theme.orange) {
            subheader("EQ", Theme.orange)
            HStack(spacing: 2) {
                Knob(value: model.param(.eqLowGain), range: -12...12, label: "LOW",
                     accent: Theme.orange, size: 34,
                     format: { String(format: "%+.1fdB", $0) }, defaultValue: 0)
                Knob(value: model.param(.eqMidGain), range: -12...12, label: "MID",
                     accent: Theme.orange, size: 34,
                     format: { String(format: "%+.1fdB", $0) }, defaultValue: 0)
                Knob(value: model.param(.eqMidFreq), range: 0...1, label: "FREQ",
                     accent: Theme.orange, size: 34,
                     format: { ParamMap.hzLabel(ParamMap.eqMidHz($0)) }, defaultValue: 0.5)
                Knob(value: model.param(.eqHighGain), range: -12...12, label: "HIGH",
                     accent: Theme.orange, size: 34,
                     format: { String(format: "%+.1fdB", $0) }, defaultValue: 0)
            }
            subheader("DELAY", Theme.orange)
            HStack(spacing: 2) {
                Knob(value: model.param(.delayTime), range: 0...1, label: "TIME",
                     accent: Theme.orange, size: 34,
                     format: { String(format: "%.0fms", ParamMap.delaySeconds($0) * 1000) },
                     defaultValue: 0.3)
                Knob(value: model.param(.delayFeedback), range: 0...0.9, label: "FDBK",
                     accent: Theme.orange, size: 34, defaultValue: 0.35)
                Knob(value: model.param(.delayMix), range: 0...1, label: "MIX",
                     accent: Theme.orange, size: 34, defaultValue: 0.18)
            }
            subheader("REVERB", Theme.orange)
            HStack(spacing: 2) {
                Knob(value: model.param(.reverbSize), range: 0...1, label: "SIZE",
                     accent: Theme.orange, size: 34, defaultValue: 0.55)
                Knob(value: model.param(.reverbDamp), range: 0...1, label: "DAMP",
                     accent: Theme.orange, size: 34, defaultValue: 0.4)
                Knob(value: model.param(.reverbMix), range: 0...1, label: "MIX",
                     accent: Theme.orange, size: 34, defaultValue: 0.22)
            }
        }
    }

    private var outSection: some View {
        SynthSection(title: "OUT", accent: Theme.green) {
            Knob(value: $model.masterGain, range: 0...1, label: "VOLUME",
                 accent: Theme.green, size: 52, defaultValue: 0.35)
            VStack(spacing: 3) {
                Text("\(model.activeVoices)")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(model.activeVoices > 0 ? Theme.green : Theme.textDim)
                    .shadow(color: model.activeVoices > 0 ? Theme.green.opacity(0.8) : .clear,
                            radius: 6)
                Text("VOICES")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.top, 6)
        }
    }

    private func subheader(_ text: String, _ accent: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(accent.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
