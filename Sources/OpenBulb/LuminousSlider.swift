import SwiftUI

/// Custom capsule slider used for brightness (luminous fill, no knob) and
/// white temperature (gradient track with a knob).
///
/// Supports pointer drag, arrow keys when keyboard-focused and VoiceOver
/// adjustable actions.
struct LuminousSlider: View {
    enum Fill {
        /// Dim track with a glowing accent fill (brightness).
        case luminous(accent: Color)
        /// Full track painted with a continuous gradient (temperature).
        case gradient([Color])
    }

    @Binding var value: Double
    var fill: Fill
    var trackHeight: CGFloat = 10
    var showsKnob = false
    var isEnabled = true
    var label = ""
    var valueText = ""

    @FocusState private var isFocused: Bool
    private let step: Double = 0.05

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knobSize: CGFloat = 24
            let travel = max(width - knobSize, 0)
            ZStack(alignment: .leading) {
                trackShape
                if case .luminous(let accent) = fill {
                    Capsule()
                        .fill(accent)
                        .frame(width: max(fillWidth(width: width, knobSize: showsKnob ? knobSize : 0), trackHeight))
                        .shadow(color: glowColor.opacity(isEnabled ? 0.55 : 0), radius: 8)
                }
                if showsKnob {
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: glowColor.opacity(isEnabled ? 0.5 : 0), radius: 5)
                        .offset(x: min(max(value * travel, 0), travel))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    guard isEnabled else { return }
                    value = min(max(g.location.x / width, 0), 1)
                }
            )
        }
        .frame(height: showsKnob ? trackHeight + 14 : trackHeight)
        .animation(.easeOut(duration: 0.15), value: value)
        .opacity(isEnabled ? 1 : 0.45)
        .focusable()
        .focused($isFocused)
        .onMoveCommand { direction in
            guard isEnabled else { return }
            switch direction {
            case .left, .down: value = min(max(value - step, 0), 1)
            case .right, .up: value = min(max(value + step, 0), 1)
            @unknown default: break
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: trackHeight)
                .strokeBorder(accentForFocus.opacity(isFocused ? 0.6 : 0), lineWidth: 1.5)
                .padding(-4)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(valueText))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: value = min(max(value + step, 0), 1)
            case .decrement: value = min(max(value - step, 0), 1)
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private var trackShape: some View {
        switch fill {
        case .luminous:
            Capsule().fill(Theme.track)
        case .gradient(let colors):
            Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
        }
    }

    private var glowColor: Color {
        switch fill {
        case .luminous(let accent): return accent
        case .gradient(let colors): return colors.first ?? .white
        }
    }

    private var accentForFocus: Color {
        if case .luminous(let accent) = fill { return accent }
        return Color.white.opacity(0.4)
    }

    private func fillWidth(width: CGFloat, knobSize: CGFloat) -> CGFloat {
        let available = max(width - knobSize, 0)
        return max(value * available + (showsKnob ? knobSize / 2 : 0), trackHeight)
    }
}
