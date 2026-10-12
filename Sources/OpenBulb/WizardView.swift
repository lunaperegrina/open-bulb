import SwiftUI
import CoreImage.CIFilterBuiltins
import TuyaCloud
import TuyaLocal

struct WizardView: View {
    @StateObject private var model = WizardModel()
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            step
        }
        .frame(width: 320, height: 470)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Open Bulb").font(.headline)
                Text("Configuração — \(model.stepNumber)/4").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "lightbulb.max.fill")
                .foregroundStyle(.yellow)
        }
        .padding(14)
    }

    @ViewBuilder
    private var step: some View {
        switch model.phase {
        case .welcome: welcomeStep
        case .credentials: credentialsStep
        case .linking: linkingStep
        case .pickDevice: pickDeviceStep
        case .done: doneStep
        case .failed(let message): failedStep(message)
        }
    }

    // 1 — welcome ----------------------------------------------------------

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vamos conectar sua lâmpada Elgin")
                .font(.title3.bold())

            numbered("1", "Crie uma conta gratuita em", "iot.tuya.com",
                     link: URL(string: "https://iot.tuya.com")!)
            numbered("2", "Em *Cloud → Development*, crie um projeto (escolha *Smart Home* e o data center *Western America*)")
            numbered("3", "Precisaremos do *Access ID* e *Access Secret* do projeto")

            Text("Depois desse setup de ~5 minutos, o app controla a lâmpada sozinho na rede local — sem nuvem e sem depender do iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
            Button("Tenho Access ID e Secret") { model.phase = .credentials }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
    }

    // 2 — credentials -------------------------------------------------------

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Credenciais da Tuya IoT")
                .font(.title3.bold())
            Text("iot.tuya.com → Cloud → seu projeto. Copie o Access ID e o Access Secret da aba Authorization.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                LabeledContent("Access ID") {
                    TextField("ex.: k7xxxxxxwxvyqwgxxxxx", text: $model.accessID)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Secret") {
                    SecureField("••••••••", text: $model.accessSecret)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .font(.caption)

            if model.checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("verificando…").font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()
            HStack {
                Button("Voltar") { model.phase = .welcome }.buttonStyle(.link)
                Spacer()
                Button("Verificar") {
                    Task { await model.verifyCredentials() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.accessID.count < 5 || model.accessSecret.count < 5 || model.checking)
            }
        }
        .padding(16)
    }

    // 3 — link account ------------------------------------------------------

    private var linkingStep: some View {
        VStack(spacing: 14) {
            Text("Vincule sua conta Elgin")
                .font(.title3.bold())

            if let qrString = model.qrString, let qrImage = QRCodeView.image(for: qrString) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 190, height: 190)
                Text("Abra o app **Elgin Smart** no iPhone → aba **Eu** → **ícone de scan** e leia este QR.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 54))
                    .foregroundStyle(.secondary)
                    .frame(height: 100)
                VStack(spacing: 8) {
                    Text("No portal da Tuya, abra seu projeto → **Devices** → **Link App Account** → **Add App Account**.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Text("Um QR aparece no navegador — leia com o app **Elgin Smart** (aba Eu → scan).")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                Button("Abrir portal da Tuya") {
                    NSWorkspace.shared.open(URL(string: "https://iot.tuya.com")!)
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            HStack(spacing: 8) {
                if model.polling {
                    ProgressView().controlSize(.small)
                    Text("aguardando o vínculo…").font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()
            HStack {
                Button("Voltar") { model.stopPolling(); model.phase = .credentials }.buttonStyle(.link)
                Spacer()
                Button("Já escaneei") {
                    Task { await model.pollDevices() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.polling)
            }
        }
        .padding(16)
        .onDisappear { model.stopPolling() }
    }

    // 4 — pick device -------------------------------------------------------

    private var pickDeviceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Escolha a lâmpada")
                .font(.title3.bold())
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.devices) { device in
                        Button {
                            Task { await model.select(device) }
                        } label: {
                            HStack {
                                Image(systemName: "lightbulb")
                                    .foregroundStyle(model.selecting == device.id ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.name ?? device.id).font(.callout.weight(.medium))
                                    Text(device.id).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selecting == device.id {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.04)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if model.discovering {
                Text(model.discoveryStatus.isEmpty
                     ? "procurando a lâmpada na rede Wi-Fi…"
                     : model.discoveryStatus)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    // done / failed ----------------------------------------------------------

    private var doneStep: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.green)
            Text("Pronto!")
                .font(.title3.bold())
            Text("\(model.configuredName) configurada.\nO ícone da barra reflete o estado dela.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Controlar a lâmpada") {
                app.deviceConfigured(name: model.configuredName)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private func failedStep(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Deu ruim")
                .font(.title3.bold())
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Tentar de novo") { model.phase = .credentials }
                .buttonStyle(.bordered)
            Spacer()
        }
        .padding(16)
    }

    // helper ------------------------------------------------------------------

    private func numbered(_ n: String, _ parts: String..., link: URL? = nil) -> some View {
        let composed = parts.map { try! AttributedString(markdown: $0) }
        var text = composed[0]
        for p in composed.dropFirst() { text += p }
        return HStack(alignment: .top, spacing: 10) {
            Text(n)
                .font(.caption2.bold())
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            if let link {
                Text(text).font(.callout) +
                Text(" ") +
                Text(link.host ?? "abrir")
                    .font(.callout)
                    .foregroundColor(.accentColor)
                    .underline() +
                Text(".")
            } else {
                Text(text).font(.callout)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let link { NSWorkspace.shared.open(link) }
        }
    }
}

@MainActor
final class WizardModel: ObservableObject {
    enum Phase {
        case welcome
        case credentials
        case linking
        case pickDevice
        case done
        case failed(String)
    }

    @Published var phase: Phase = .welcome
    @Published var accessID = ""
    @Published var accessSecret = ""
    @Published var checking = false
    @Published var polling = false
    @Published var qrString: String?
    @Published var devices: [TuyaCloudClient.Device] = []
    @Published var selecting: String?
    @Published var discovering = false
    @Published var discoveryStatus = ""
    @Published var configuredName = "Lâmpada"

    init() {
        // pre-fill from a previous run so a retry doesn't mean retyping
        let cfg = ConfigStore.load()
        if let id = cfg.apiKey { accessID = id }
        if let secret = ConfigStore.loadAPISecret(config: cfg) { accessSecret = secret }
    }

    private var cloud: TuyaCloudClient?
    private var pollTask: Task<Void, Never>?

    var stepNumber: Int {
        switch phase {
        case .welcome: return 1
        case .credentials: return 2
        case .linking: return 3
        case .pickDevice, .done: return 4
        case .failed: return 2
        }
    }

    func verifyCredentials() async {
        checking = true
        defer { checking = false }
        do {
            let client = try await TuyaCloudClient.detectDataCenter(
                apiKey: accessID, apiSecret: accessSecret)
            cloud = client
            // save credentials + try to get an in-app QR ticket (optional nicety)
            ConfigStore.saveAPISecret(accessSecret)
            var cfg = ConfigStore.load()
            cfg.apiKey = accessID
            cfg.dataCenter = client.dataCenter.rawValue
            ConfigStore.save(cfg)
            qrString = try? await client.fetchLinkQRTicket()
            phase = .linking
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Poll the device list until the app account gets linked (QR scanned).
    func pollDevices() async {
        guard let cloud else { return }
        polling = true
        defer { polling = false }
        pollTask = Task {
            for _ in 0..<100 { // ~5 minutes at 3s
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let list = try? await cloud.listDevices(), !list.isEmpty {
                    devices = list
                    phase = .pickDevice
                    return
                }
            }
            phase = .failed("O vínculo não apareceu em 5 minutos. Confirme se escaneou o QR com o app Elgin Smart e tente de novo.")
        }
        await pollTask?.value
    }

    func stopPolling() {
        pollTask?.cancel()
        polling = false
    }

    func select(_ device: TuyaCloudClient.Device) async {
        guard let localKey = device.localKey else {
            phase = .failed("A Tuya não devolveu o local_key deste dispositivo. Verifique se o projeto tem permissão de leitura de dispositivos.")
            return
        }
        selecting = device.id
        discovering = true
        discoveryStatus = "escutando broadcasts UDP…"
        defer {
            selecting = nil
            discovering = false
            discoveryStatus = ""
        }

        // 1) passive: IP + protocol version from the UDP broadcast
        var found = await Task.detached(priority: .userInitiated) {
            TuyaDiscovery.findDevice(id: device.id, duration: 6)
        }.value

        // 2) active: sweep the subnet (TCP 6668) and confirm with the local
        //    key — survives silent Local Network privacy blocks on broadcasts
        if found == nil, let keyData = localKey.data(using: .utf8) {
            found = await Task.detached(priority: .userInitiated) {
                TuyaDiscovery.activeScan(deviceID: device.id, localKey: keyData) { status in
                    Task { @MainActor in self.discoveryStatus = status }
                }
            }.value
        }

        guard let found else {
            phase = .failed("""
                Lâmpada não encontrada na rede local. Se o macOS pediu permissão de \
                “Rede Local”, toque em Permitir (ou ative em Ajustes do Sistema → \
                Privacidade e Segurança → Rede Local → Open Bulb) e tente de novo. \
                Confira também se Mac e lâmpada estão no mesmo Wi-Fi.
                """)
            return
        }

        ConfigStore.saveLocalKey(localKey)
        var cfg = ConfigStore.load()
        cfg.deviceId = device.id
        cfg.deviceName = device.name ?? "Lâmpada"
        cfg.ip = found.ip
        cfg.version = Double(found.version) ?? 3.3
        ConfigStore.save(cfg)
        configuredName = cfg.deviceName ?? "Lâmpada"
        phase = .done
    }
}

/// QR rendered with CoreImage (no dependencies).
enum QRCodeView {
    static func image(for string: String, scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
