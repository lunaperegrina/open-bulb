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

    var body: some View {
        VStack(spacing: 14) {
            header

            switch app.connection {
            case .offline(let why):
                OfflineBanner(reason: why)
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("conectando…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            default:
                if let bulb = app.bulb {
                    controls(for: bulb)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 140)
                }
            }

            if !app.favorites.isEmpty {
                FavoritesRow()
            }

            footer
        }
        .padding(16)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.deviceName).font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            PowerToggle()
        }
    }

    private var statusText: String {
        switch app.connection {
        case .online: return app.bulb?.isOn == true ? "acesa" : "apagada"
        case .connecting: return "procurando…"
        case .offline: return "offline"
        case .unconfigured: return ""
        }
    }

    @ViewBuilder
    private func controls(for bulb: BulbState) -> some View {
        VStack(spacing: 12) {
            // Brightness
            HStack {
                Image(systemName: "sun.max")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: app.brightnessBinding, in: 0...1)
                    .disabled(!bulb.isOn)
                Text("\(Int(round(bulb.brightness * 100)))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            // Mode picker
            Picker("modo", selection: app.modeBinding) {
                Text("Branco").tag(BulbState.Mode.white)
                Text("Cor").tag(BulbState.Mode.colour)
            }
            .pickerStyle(.segmented)
            .disabled(!bulb.isOn)

            if bulb.mode == .colour {
                ColorWheelView(hue: app.hueBinding,
                               saturation: app.saturationBinding,
                               value: app.colorValueBinding)
                    .frame(height: 200)
            } else if bulb.colorTemperature != nil {
                WhiteTempSlider(value: app.colorTemperatureBinding)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                app.saveFavorite()
            } label: {
                Label("Favorito", systemImage: "plus.circle")
                    .font(.caption)
            }
            .disabled(app.bulb == nil)
            .buttonStyle(.link)

            Spacer()

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.link)
            .help("Ajustes")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.link)
            .help("Sair do Open Bulb")
        }
    }
}

struct PowerToggle: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let on = app.bulb?.isOn ?? false
        Button {
            app.setPower(!on)
        } label: {
            ZStack {
                Circle()
                    .fill(on ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                             : AnyShapeStyle(Color.primary.opacity(0.08)))
                    .frame(width: 40, height: 40)
                Image(systemName: "power")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(app.bulb == nil)
        .help(on ? "Desligar" : "Ligar")
    }
}

struct OfflineBanner: View {
    @EnvironmentObject var app: AppState
    let reason: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Lâmpada fora de alcance")
                .font(.headline)
            Text("Confira se ela está ligada na tomada e no mesmo Wi-Fi deste Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Tentar de novo") { app.rediscover() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }
}

struct FavoritesRow: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Favoritos").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(app.favorites) { fav in
                        FavoriteChip(favorite: fav)
                    }
                }
            }
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
            VStack(spacing: 4) {
                Circle()
                    .fill(favorite.state.isOn ? favorite.color : Color.primary.opacity(0.15))
                    .frame(width: 26, height: 26)
                    .overlay {
                        if !favorite.state.isOn {
                            Image(systemName: "moon.zzz")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                Text(favorite.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 54)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remover", role: .destructive) {
                app.removeFavorite(favorite.id)
            }
        }
        .help("Aplicar \(favorite.label)")
    }
}

/// Warm→cool slider for white mode.
struct WhiteTempSlider: View {
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color(red: 1, green: 0.68, blue: 0.4),
                                     Color(red: 1, green: 0.93, blue: 0.84),
                                     Color(red: 0.78, green: 0.87, blue: 1)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(height: 14)
                        .offset(y: (geo.size.height - 14) / 2)
                    Circle()
                        .fill(Color.white)
                        .shadow(radius: 1)
                        .frame(width: 16, height: 16)
                        .offset(x: min(max(value * (width - 16), 0), width - 16),
                                y: geo.size.height / 2 - 8)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { g in
                        value = min(max(g.location.x / width, 0), 1)
                    }
                )
            }
            .frame(height: 20)
            HStack {
                Text("quente").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text("frio").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}
