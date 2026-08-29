import SwiftUI

enum Theme {
    static let bg = Color(red: 0.035, green: 0.03, blue: 0.07)
    static let panel = Color(red: 0.075, green: 0.07, blue: 0.13)
    static let cyan = Color(red: 0.0, green: 0.92, blue: 1.0)
    static let magenta = Color(red: 1.0, green: 0.2, blue: 0.85)
    static let purple = Color(red: 0.65, green: 0.45, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.25)
    static let green = Color(red: 0.3, green: 1.0, blue: 0.65)
    static let yellow = Color(red: 1.0, green: 0.86, blue: 0.3)
    static let textDim = Color.white.opacity(0.5)
}

/// A titled neon panel; sections sit left-to-right in signal-flow order.
struct SynthSection<Content: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(accent)
                .shadow(color: accent.opacity(0.9), radius: 5)
            content
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Theme.panel, Theme.panel.opacity(0.6)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: accent.opacity(0.18), radius: 12)
    }
}

/// Arrow between sections, marking the signal flow.
struct FlowArrow: View {
    var body: some View {
        Image(systemName: "chevron.compact.right")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(Theme.textDim)
    }
}

/// Rotary knob: drag vertically to change, double-click to reset.
struct Knob: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let label: String
    var accent: Color = Theme.cyan
    var size: CGFloat = 46
    var format: ((Float) -> String)?
    var defaultValue: Float?

    @State private var dragAnchor: Float?

    private var norm: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.16), Color(white: 0.05)],
                                         center: .center, startRadius: 0, endRadius: size / 2))
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.1),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: norm * 0.75)
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .shadow(color: accent.opacity(0.9), radius: 4)
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: size * 0.28)
                    .offset(y: -size * 0.26)
                    .rotationEffect(.degrees(Double(norm) * 270 - 135))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .onTapGesture(count: 2) {
                if let defaultValue { value = defaultValue }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if dragAnchor == nil { dragAnchor = value }
                        let span = range.upperBound - range.lowerBound
                        let delta = Float(-g.translation.height) / 160 * span
                        value = min(range.upperBound, max(range.lowerBound, dragAnchor! + delta))
                    }
                    .onEnded { _ in dragAnchor = nil }
            )

            Text(label)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(Theme.textDim)
            Text(format.map { $0(value) } ?? String(format: "%.2f", value))
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(accent.opacity(0.85))
        }
        .frame(width: max(size + 14, 58))
    }
}

/// Neon-outlined push button for the preset bar and dialogs.
struct NeonButtonStyle: ButtonStyle {
    var accent: Color = Theme.cyan
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed ? accent.opacity(0.3) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(accent.opacity(isEnabled ? 0.7 : 0.25), lineWidth: 1)
            )
            .foregroundStyle(accent)
            .shadow(color: accent.opacity(configuration.isPressed ? 0.9 : 0.25), radius: 5)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Compact multi-option selector (waveform, octave).
struct MiniSelector: View {
    @Binding var selection: Int
    let options: [(String, Int)]
    var accent: Color = Theme.cyan

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { (name, tag) in
                let selected = selection == tag
                Button {
                    selection = tag
                } label: {
                    Text(name)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selected ? accent.opacity(0.25) : Color.white.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(selected ? accent : Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .foregroundStyle(selected ? accent : Theme.textDim)
                        .shadow(color: selected ? accent.opacity(0.7) : .clear, radius: 4)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
