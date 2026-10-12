import SwiftUI
import ServiceManagement
import TuyaCloud

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            deviceSection
            startupSection
            advancedSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 430)
    }

    private var cfg: ConfigStore.AppConfig { ConfigStore.load() }

    private var deviceSection: some View {
        Section("Lâmpada") {
            LabeledContent("Nome") { Text(cfg.deviceName ?? "—") }
            LabeledContent("Device ID") { Text(cfg.deviceId ?? "—").font(.system(.caption, design: .monospaced)) }
            LabeledContent("IP") {
                HStack {
                    Text(cfg.ip ?? "auto")
                    Button("Atualizar") { app.rediscover() }
                        .controlSize(.small)
                }
            }
            LabeledContent("Protocolo") { Text(cfg.version.map { "Tuya \($0)" } ?? "—") }
            LabeledContent("Status") {
                switch app.connection {
                case .online: Text("online").foregroundStyle(.green)
                case .connecting: Text("conectando…").foregroundStyle(.orange)
                case .offline: Text("offline").foregroundStyle(.red)
                case .unconfigured: Text("não configurada")
                }
            }
        }
    }

    private var startupSection: some View {
        Section("Inicialização") {
            Toggle("Abrir ao ligar o Mac", isOn: Binding(
                get: { LoginItem.isEnabled },
                set: { LoginItem.setEnabled($0) }))
        }
    }

    private var advancedSection: some View {
        Section("Avançado") {
            DisclosureGroup("Chave local (device local_key)") {
                SecureField("16 caracteres", text: $localKeyText)
                    .font(.system(.caption, design: .monospaced))
                HStack {
                    Button("Salvar") {
                        ConfigStore.saveLocalKey(localKeyText)
                        localKeySaved = true
                    }
                    .disabled(localKeyText.count != 16)
                    if localKeySaved { Image(systemName: "checkmark").foregroundStyle(.green) }
                    Spacer()
                    Button("Refazer setup completo", role: .destructive) {
                        app.forgetDevice()
                    }
                }
            }
        }
    }

    @State private var localKeyText: String = ConfigStore.loadLocalKey() ?? ""
    @State private var localKeySaved = false
}

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("login item error: \(error)")
        }
    }
}
