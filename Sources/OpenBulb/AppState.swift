import Foundation
import SwiftUI
import TuyaLocal
import TuyaCloud


/// A saved favourite: a full bulb state snapshot.
struct Favorite: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var state: BulbState

    var color: Color {
        let rgb = BulbModel.hsvToRGB(hue: state.hue, saturation: state.saturation,
                                     value: max(state.colorValue, 0.35))
        return Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255)
    }

    var label: String {
        if state.mode == .colour {
            let names: [(Double, String)] = [
                (15, "Vermelho"), (45, "Laranja"), (70, "Amarelo"), (160, "Verde"),
                (200, "Ciano"), (260, "Azul"), (300, "Roxo"), (345, "Rosa"), (361, "Vermelho"),
            ]
            for (maxH, name) in names where state.hue < maxH { return name }
        }
        if state.mode == .white {
            if let t = state.colorTemperature { return t < 0.5 ? "Branco quente" : "Branco frio" }
        }
        return "Branco"
    }
}

/// Orchestrates the lamp connection, polling, optimistic UI state and favourites.
@MainActor
final class AppState: ObservableObject {
    enum ConnectionState: Equatable {
        case unconfigured
        case connecting
        case online
        case offline(String)
    }

    @Published var bulb: BulbState?
    @Published var connection: ConnectionState = .unconfigured
    @Published var bulbKind: BulbModel.BulbKind = .typeB
    @Published var deviceName: String = "Lâmpada"
    @Published var favorites: [Favorite] = []
    @Published var popoverVisible = false
    /// non-nil error text to surface in the popover
    @Published var lastError: String?

    private let worker = DispatchQueue(label: "openbulb.bulb-worker", qos: .userInitiated)
    private var pollTimer: Timer?
    private var pendingDPS: [String: Any] = [:]
    private var flushWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0

    var isConfigured: Bool {
        ConfigStore.load().isDeviceConfigured && ConfigStore.loadLocalKey() != nil
    }

    /// Shared instance: the AppDelegate status item, popover and the Settings
    /// scene all drive the same state.
    static let shared = AppState()

    init() {
        loadFavorites()
        let cfg = ConfigStore.load()
        if cfg.isDeviceConfigured, ConfigStore.loadLocalKey() != nil {
            deviceName = cfg.deviceName ?? "Lâmpada"
            connection = .connecting
        } else {
            connection = .unconfigured
        }
        startPolling()
    }

    // MARK: - Polling

    func startPolling() {
        pollTimer?.invalidate()
        let interval: TimeInterval = popoverVisible ? 5 : 30
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if case .unconfigured = self.connection { return }
                self.refresh()
                self.startPolling() // reschedule at the current cadence
            }
        }
    }

    func popoverWillShow() {
        popoverVisible = true
        refresh()
        startPolling()
    }

    func popoverDidClose() {
        popoverVisible = false
        startPolling()
    }

    // MARK: - Device operations

    func refresh() {
        if case .unconfigured = connection { return }
        run { device, _ in
            let result = try device.status()
            guard let dps = result["dps"] as? [String: Any] else {
                throw TuyaDevice.DeviceError.payload("sem dps na resposta")
            }
            return dps
        } onResult: { [weak self] dps, _ in
            guard let self else { return }
            if let kind = BulbModel.detectKind(dps: dps) { self.bulbKind = kind }
            if let state = BulbModel.state(from: dps) {
                self.bulb = state
                self.lastError = nil
            }
        }
    }

    func setPower(_ on: Bool) {
        optimistically { $0.isOn = on }
        sendDPS(BulbModel.setPower(on, kind: bulbKind))
    }

    func setMode(_ mode: BulbState.Mode) {
        optimistically { $0.mode = mode }
        sendDPS(BulbModel.setMode(mode, kind: bulbKind))
    }

    func setBrightness(_ value: Double) {
        optimistically { $0.brightness = value }
        sendDPS(BulbModel.setBrightness(value, kind: bulbKind))
    }

    func setColorTemperature(_ value: Double) {
        optimistically { $0.colorTemperature = value; $0.mode = .white }
        sendDPS(BulbModel.setColorTemperature(value, kind: bulbKind))
    }

    func setColor(hue: Double, saturation: Double, value: Double) {
        optimistically {
            $0.hue = hue
            $0.saturation = saturation
            $0.colorValue = value
            $0.mode = .colour
        }
        sendDPS(BulbModel.setColor(hue: hue, saturation: saturation, value: value, kind: bulbKind))
    }

    func applyFavorite(_ favorite: Favorite) {
        optimistically { $0 = favorite.state }
        sendDPS(BulbModel.dpsPayload(for: favorite.state, kind: bulbKind))
    }

    func saveFavorite() {
        guard let bulb else { return }
        favorites.append(Favorite(state: bulb))
        saveFavorites()
    }

    func removeFavorite(_ id: UUID) {
        favorites.removeAll { $0.id == id }
        saveFavorites()
    }

    /// Re-resolve the lamp's IP via UDP discovery (DHCP may have moved it).
    func rediscover() {
        connection = .connecting
        let cfg = ConfigStore.load()
        guard let id = cfg.deviceId else { return }
        worker.async { [weak self] in
            let found = TuyaDiscovery.findDevice(id: id, duration: 8)
            Task { @MainActor in
                guard let self else { return }
                if let found {
                    var cfg = ConfigStore.load()
                    cfg.ip = found.ip
                    cfg.version = Double(found.version) ?? cfg.version
                    ConfigStore.save(cfg)
                    self.connection = .connecting
                    self.refresh()
                } else {
                    self.connection = .offline("lâmpada não encontrada na rede")
                }
            }
        }
    }

    /// After the wizard finishes configuring the device.
    func deviceConfigured(name: String) {
        deviceName = name
        connection = .connecting
        lastError = nil
        refresh()
        startPolling()
    }

    func forgetDevice() {
        var cfg = ConfigStore.load()
        cfg.deviceId = nil
        cfg.ip = nil
        cfg.version = nil
        cfg.deviceName = nil
        ConfigStore.save(cfg)
        ConfigStore.saveLocalKey(nil)
        bulb = nil
        connection = .unconfigured
    }

    // MARK: - SwiftUI bindings (optimistic + throttled send)

    var brightnessBinding: Binding<Double> {
        Binding { [weak self] in self?.bulb?.brightness ?? 1 } set: { [weak self] v in
            guard let self else { return }
            self.optimistically { $0.brightness = v }
            self.sendDPS(BulbModel.setBrightness(v, kind: self.bulbKind))
        }
    }

    var modeBinding: Binding<BulbState.Mode> {
        Binding { [weak self] in self?.bulb?.mode ?? .white } set: { [weak self] mode in
            guard let self else { return }
            self.setMode(mode)
        }
    }

    var colorTemperatureBinding: Binding<Double> {
        Binding { [weak self] in self?.bulb?.colorTemperature ?? 0.5 } set: { [weak self] v in
            guard let self else { return }
            self.setColorTemperature(v)
        }
    }

    var hueBinding: Binding<Double> {
        Binding { [weak self] in self?.bulb?.hue ?? 0 } set: { [weak self] v in
            guard let self, var b = self.bulb else { return }
            b.hue = v
            self.setColorFrom(b)
        }
    }

    var saturationBinding: Binding<Double> {
        Binding { [weak self] in self?.bulb?.saturation ?? 1 } set: { [weak self] v in
            guard let self, var b = self.bulb else { return }
            b.saturation = v
            self.setColorFrom(b)
        }
    }

    var colorValueBinding: Binding<Double> {
        Binding { [weak self] in self?.bulb?.colorValue ?? 1 } set: { [weak self] v in
            guard let self, var b = self.bulb else { return }
            b.colorValue = v
            self.setColorFrom(b)
        }
    }

    private func setColorFrom(_ b: BulbState) {
        optimistically {
            $0.hue = b.hue; $0.saturation = b.saturation; $0.colorValue = b.colorValue
            $0.mode = .colour
        }
        sendDPS(BulbModel.setColor(hue: b.hue, saturation: b.saturation,
                                   value: b.colorValue, kind: bulbKind))
    }

    // MARK: - plumbing

    private func optimistically(_ mutate: (inout BulbState) -> Void) {
        var s = bulb ?? BulbState()
        mutate(&s)
        bulb = s
        connection = .online
    }

    /// Queue DPS writes, coalescing rapid slider updates into one flush.
    private func sendDPS(_ dps: [String: Any]) {
        for (k, v) in dps { pendingDPS[k] = v }
        flushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushPending() }
        flushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    private func flushPending() {
        guard !pendingDPS.isEmpty else { return }
        let dps = pendingDPS
        pendingDPS = [:]
        run { device, _ in
            try device.setDPS(dps)
            return ()
        } onResult: { _, _ in }
    }

    /// Runs a blocking device operation on the worker queue and applies the
    /// result on the main actor, translating errors into connection state.
    private func run<T>(_ op: @escaping (TuyaDevice, BulbModel.BulbKind) throws -> T,
                        onResult: @escaping (T, BulbModel.BulbKind) -> Void) {
        let cfg = ConfigStore.load()
        guard let deviceId = cfg.deviceId,
              let keyStr = ConfigStore.loadLocalKey(),
              let key = keyStr.data(using: .utf8) else {
            connection = .unconfigured
            return
        }
        let host = cfg.ip ?? ""
        let version = cfg.version ?? 3.3
        worker.async { [weak self] in
            let device = TuyaDevice(config: .init(deviceID: deviceId, host: host,
                                                  localKey: key, version: version,
                                                  timeout: 5))
            do {
                let result = try op(device, .typeB)
                Task { @MainActor in
                    guard let self else { return }
                    self.connection = .online
                    self.reconnectAttempt = 0
                    onResult(result, .typeB)
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.handleDeviceError(error)
                }
            }
        }
    }

    private func handleDeviceError(_ error: Error) {
        // retry with rediscovery a couple of times before declaring offline
        if reconnectAttempt < 2, isNetworkError(error) {
            reconnectAttempt += 1
            connection = .connecting
            rediscover()
            return
        }
        reconnectAttempt = 0
        connection = .offline(String(describing: error))
        lastError = String(describing: error)
    }

    private func isNetworkError(_ error: Error) -> Bool {
        let e = String(describing: error)
        return e.contains("offline") || e.contains("connect") || e.contains("timed out")
            || e.contains("timeout") || e.contains("No route") || e.contains("closed")
    }

    // MARK: - favorites persistence

    static var favoritesURL: URL {
        ConfigStore.directory.appendingPathComponent("favorites.json")
    }

    func loadFavorites() {
        guard let data = try? Data(contentsOf: Self.favoritesURL),
              let list = try? JSONDecoder().decode([Favorite].self, from: data) else { return }
        favorites = list
    }

    func saveFavorites() {
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(favorites) {
            try? data.write(to: Self.favoritesURL, options: .atomic)
        }
    }
}
