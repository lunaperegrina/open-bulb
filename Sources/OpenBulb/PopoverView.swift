import SwiftUI
import TuyaLocal

/// Popover root: wizard when unconfigured, controls otherwise.
struct PopoverRootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            switch app.connection {
            case .unconfigured:
                WizardView()
            default:
                BulbControlsView()
            }
        }
        .frame(width: 320)
    }
}

struct BulbControlsView: View {
    @EnvironmentObject var app: AppState

    private var accent: Color { Theme.accent(for: app.bulb) }

    var body: some View {
        VStack(spacing: 12) {
            // Keep the controls up whenever we have a last-known state: the
            // old design swapped the whole card for a spinner while
            // reconnecting, which locked the user out of the power button —
            // exactly when they needed to turn the lamp back on.
            if let bulb = app.bulb {
                controlCard(bulb)
                if case .offline = app.connection {
                    retryRow
                }
            } else {
                switch app.connection {
                case .offline(let why):
                    OfflineBanner(reason: why)
                default:
                    connectingView
                }
            }

            actionCards
        }
        .padding(14)
        .background(Theme.background)
    }

    private var retryRow: some View {
        Button {
            app.rediscover()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("Tentar de novo")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Theme.hairline))
        }
        .buttonStyle(PressableStyle())
        .help("Procurar a lâmpada na rede de novo")
        .accessibilityLabel("Tentar reconectar")
    }

    // MARK: Card

    private func controlCard(_ bulb: BulbState) -> some View {
        VStack(spacing: 16) {
            header(bulb)
            BrightnessSection(bulb: bulb, accent: accent)
            ModeSegmentedControl(selection: app.modeBinding, enabled: bulb.isOn)

            // Mode content: colour wheel (taller) or white temperature slider;
            // the popover resizes smoothly between modes.
            Group {
                if bulb.mode == .colour {
                    ColorWheelView(hue: app.hueBinding,
                                   saturation: app.saturationBinding,
                                   value: app.colorValueBinding,
                                   lit: bulb.isOn)
                        .frame(height: 176)
                        .transition(.opacity)
                } else if bulb.colorTemperature != nil {
                    WhiteTempSlider(value: app.colorTemperatureBinding, isEnabled: bulb.isOn)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: bulb.mode)

            if !app.favorites.isEmpty {
                FavoritesRow()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.card)
                .shadow(color: accent.opacity(bulb.isOn ? 0.22 : 0), radius: 26)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.hairline)
        )
    }

    private func header(_ bulb: BulbState) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(accent.opacity(bulb.isOn ? 0.16 : 0.07))
                    .frame(width: 44, height: 44)
                Image(systemName: "lightbulb.max.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(bulb.isOn ? AnyShapeStyle(accent) : AnyShapeStyle(Theme.textSecondary))
                    .shadow(color: accent.opacity(bulb.isOn ? 0.7 : 0), radius: 7)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.deviceName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            PowerButton()
        }
        .animation(.easeInOut(duration: 0.25), value: bulb)
    }

    private var statusText: String {
        switch app.connection {
        case .online:
            guard let bulb = app.bulb else { return "" }
            guard bulb.isOn else { return "apagada" }
            switch bulb.mode {
            case .colour:
                return "acesa · \(ColorNames.name(hue: bulb.hue))"
            default:
                if let t = bulb.colorTemperature {
                    return t < 0.5 ? "acesa · branco quente" : "acesa · branco frio"
                }
                return "acesa"
            }
        case .connecting: return "reconectando…"
        case .offline: return "offline · tentando de novo"
        case .unconfigured: return ""
        }
    }

    private var connectingView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("conectando…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: Footer

    private var actionCards: some View {
        HStack(spacing: 10) {
            ActionCard(icon: "plus", title: "Favorito", tint: accent) {
                app.saveFavorite()
            }
            .disabled(app.bulb == nil)

            ActionCard(icon: "gearshape", title: "Ajustes", tint: Theme.textSecondary,
                       iconColor: Theme.textPrimary) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }

            ActionCard(icon: "power", title: "Sair", tint: Theme.textSecondary,
                       iconColor: Theme.textPrimary) {
                NSApp.terminate(nil)
            }
        }
        .frame(height: 74)
    }
}

// MARK: - Header power

struct PowerButton: View {
    @EnvironmentObject var app: AppState
    @State private var hovering = false

    var body: some View {
        let on = app.bulb?.isOn ?? false
        let accent = Theme.accent(for: app.bulb)
        Button {
            app.setPower(!on)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(on ? 0.10 : 0.06))
                    .frame(width: 46, height: 46)
                    .overlay(
                        Circle().strokeBorder(
                            on ? accent.opacity(0.55) : (hovering ? Color.white.opacity(0.14) : Theme.hairline),
                            lineWidth: 1.5)
                    )
                    .shadow(color: accent.opacity(on ? 0.4 : 0), radius: 12)
                Image(systemName: "power")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Theme.textSecondary)
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(app.bulb == nil)
        .help(on ? "Desligar" : "Ligar")
        .accessibilityLabel(on ? "Desligar lâmpada" : "Ligar lâmpada")
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.25), value: on)
    }
}

// MARK: - Brightness

private struct BrightnessSection: View {
    @EnvironmentObject var app: AppState
    let bulb: BulbState
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("BRILHO")
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(round(bulb.brightness * 100)))")
                    .font(.system(size: 42, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(bulb.isOn ? Theme.textPrimary : Theme.textSecondary)
                Text("%")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.45))
                LuminousSlider(value: app.brightnessBinding,
                               fill: .luminous(accent: accent),
                               trackHeight: 10,
                               isEnabled: bulb.isOn,
                               label: "Brilho",
                               valueText: "\(Int(round(bulb.brightness * 100))) por cento")
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(bulb.isOn ? accent : Theme.textSecondary)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: bulb.isOn)
    }
}

private func sectionLabel(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 10.5, weight: .semibold))
        .tracking(1.4)
        .foregroundStyle(Theme.textSecondary)
}

// MARK: - Mode segmented control

struct ModeSegmentedControl: View {
    @Binding var selection: BulbState.Mode
    var enabled: Bool
    @Namespace private var pillSpace

    var body: some View {
        HStack(spacing: 3) {
            segment("Branco", mode: .white)
            segment("Cor", mode: .colour)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Theme.segmentRadius)
                .fill(Theme.segmentedContainer)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.segmentRadius)
                .strokeBorder(Theme.hairline)
        )
    }

    private func segment(_ title: String, mode: BulbState.Mode) -> some View {
        let selected = selection == mode
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selection = mode
            }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: Theme.segmentPillRadius)
                            .fill(Theme.segmentPill)
                            .matchedGeometryEffect(id: "mode-pill", in: pillSpace)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(title)
        .help(title)
    }
}

// MARK: - White temperature

/// Warm→cool slider for white mode.
struct WhiteTempSlider: View {
    @Binding var value: Double
    var isEnabled = true

    var body: some View {
        VStack(spacing: 8) {
            LuminousSlider(value: $value,
                           fill: .gradient(Theme.temperatureGradient),
                           trackHeight: 12,
                           showsKnob: true,
                           isEnabled: isEnabled,
                           label: "Temperatura de cor",
                           valueText: value < 0.5 ? "mais quente" : "mais fria")
            HStack {
                Text("quente")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("frio")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Favorites

struct FavoritesRow: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("FAVORITOS")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(app.favorites) { fav in
                        FavoriteChip(favorite: fav)
                    }
                }
            }
            .frame(height: 52)
        }
    }
}

struct FavoriteChip: View {
    @EnvironmentObject var app: AppState
    let favorite: Favorite
    @State private var hovering = false

    var body: some View {
        Button {
            app.applyFavorite(favorite)
        } label: {
            VStack(spacing: 5) {
                Circle()
                    .fill(favorite.state.isOn ? favorite.color : Color.white.opacity(0.07))
                    .frame(width: 32, height: 32)
                    .overlay {
                        if !favorite.state.isOn {
                            Image(systemName: "moon.zzz.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .overlay(
                        Circle().strokeBorder(
                            favorite.state.isOn ? Color.white.opacity(0.25) : Theme.hairline,
                            lineWidth: 1)
                    )
                    .shadow(color: favorite.state.isOn ? favorite.color.opacity(0.5) : Color.clear,
                            radius: 6)
                Text(favorite.label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            }
            .frame(width: 50)
            .scaleEffect(hovering ? 1.05 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remover", role: .destructive) {
                app.removeFavorite(favorite.id)
            }
        }
        .help("Aplicar \(favorite.label)")
        .accessibilityLabel("Aplicar favorito \(favorite.label)")
        .onHover { hovering = $0 }
    }
}

// MARK: - Action cards

struct ActionCard: View {
    let icon: String
    let title: String
    var tint: Color
    /// Overrides the icon color; defaults to `tint`.
    var iconColor: Color?
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(tint.opacity(0.14))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(iconColor ?? tint)
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.actionCardRadius)
                    .fill(Theme.actionCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.actionCardRadius)
                    .strokeBorder(hovering ? Color.white.opacity(0.12) : Theme.hairline)
            )
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(PressableStyle())
        .focused($focused)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.actionCardRadius)
                .strokeBorder(Color.white.opacity(focused ? 0.3 : 0), lineWidth: 1.5)
                .padding(-3)
        )
        .help(title)
        .accessibilityLabel(title)
        .onHover { hovering = $0 }
    }
}

/// Shared pressed feedback for card-like buttons.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Offline

struct OfflineBanner: View {
    @EnvironmentObject var app: AppState
    let reason: String

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 46, height: 46)
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("Lâmpada fora de alcance")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Confira se ela está ligada na tomada e no mesmo Wi-Fi deste Mac.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                app.rediscover()
            } label: {
                Text("Tentar de novo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .overlay(Capsule().strokeBorder(Theme.hairline))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 210)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.hairline)
        )
    }
}

// MARK: - Helpers

enum ColorNames {
    static func name(hue: Double) -> String {
        let names: [(Double, String)] = [
            (15, "vermelho"), (45, "laranja"), (70, "amarelo"), (160, "verde"),
            (200, "ciano"), (260, "azul"), (300, "roxo"), (345, "rosa"), (361, "vermelho"),
        ]
        for (maxH, name) in names where hue < maxH { return name }
        return "branco"
    }
}
