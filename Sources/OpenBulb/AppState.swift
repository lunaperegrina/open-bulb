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
///
/// Connection model: one device op in flight at a time, extra polls coalesced
/// into a single trailing request, writes re-queued if the lamp is unreachable,
/// and network sweeps (rediscovery) throttled by `ReconnectPlanner` — the old
/// design ran a full-subnet sweep per failure on the same serial queue as the
/// commands, which wedged the app in "conectando…" forever whenever the lamp
/// had a transient outage.
@MainActor
final class AppState: ObservableObject {
    enum ConnectionState: Equatable {
        case unconfigured
        case connecting
        case online
        case offline(String)
    }

    @Published var bulb: BulbState?
    @Published var connection: ConnectionState = .unconfigured {
        didSet { Self.traceLog("state \(oldValue) -> \(connection)") }
    }
    @Published var bulbKind: BulbModel.BulbKind = .typeB
    @Published var deviceName: String = "Lâmpada"
    @Published var favorites: [Favorite] = []
    @Published var popoverVisible = false
    /// non-nil error text to surface in the popover
    @Published var lastError: String?

    private let worker = DispatchQueue(label: "openbulb.bulb-worker", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "openbulb.bulb-scan", qos: .utility)
    private var pollTimer: Timer?
    private var pendingDPS: [String: Any] = [:]
    private var flushWorkItem: DispatchWorkItem?

    /// Cached device coordinates (loaded from ConfigStore once, not per op —
    /// keychain reads on every poll used to run on the main thread).
    private struct DeviceTarget {
        var deviceId: String
        var key: Data
        var host: String
        var version: Double
    }
    private var target: DeviceTarget?

    private var opInFlight = false
    private var pollQueued = false
    private var scanRunning = false
    private var planner = ReconnectPlanner()

    var isConfigured: Bool { target != nil }

    /// Shared instance: the AppDelegate status item, popover and the Settings
    /// scene all drive the same state.
    static let shared = AppState()

    init() {
        loadFavorites()
        loadLastState()
        connection = .connecting
        if ProcessInfo.processInfo.environment["OPENBULB_TEST_POPOVER"] != nil {
            // harness hook: simulate an open popover (5s poll cadence) in headless tests
            popoverVisible = true
        }
        loadConfigAsync()
        // if the keychain wedges (ACL prompt nobody can answer), degrade to an
        // actionable offline state instead of spinning "conectando…" forever
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.target == nil else { return }
            self.connection = .offline("não consegui ler a configuração (Keychain)")
        }
        startPolling()
    }

    /// Env-gated stderr tracing (OPENBULB_TRACE=1) — zero cost when off;
    /// the standard way to watch the connection loop during LAN debugging.
    static func traceLog(_ s: String) {
        guard ProcessInfo.processInfo.environment["OPENBULB_TRACE"] != nil else { return }
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        FileHandle.standardError.write("[openbulb] \(ms) \(s)\n".data(using: .utf8)!)
    }

    /// Load device coordinates off the main thread: the keychain read can
    /// block indefinitely waiting for an ACL approval prompt a menu bar app
    /// never shows — the old code did this on the main thread for every
    /// single poll, freezing the popover ("travado em conectando").
    private func loadConfigAsync(preferredName: String? = nil) {
        worker.async { [weak self] in
            let cfg = ConfigStore.load()
            let keyStr = ConfigStore.loadLocalKey()
            Self.traceLog("config.loaded id=\(cfg.deviceId != nil) key=\(keyStr != nil)")
            Task { @MainActor in
                self?.applyConfig(cfg, localKey: keyStr, preferredName: preferredName)
            }
        }
    }

    private func applyConfig(_ cfg: ConfigStore.AppConfig,
                             localKey: String?, preferredName: String? = nil) {
        guard let id = cfg.deviceId,
              let keyStr = localKey,
              let key = keyStr.data(using: .utf8) else {
            target = nil
            if case .online = connection {} else { connection = .unconfigured }
            return
        }
        deviceName = preferredName ?? cfg.deviceName ?? "Lâmpada"
        target = DeviceTarget(deviceId: id, key: key,
                              host: cfg.ip ?? "", version: cfg.version ?? 3.3)
        if connection != .online { connection = .connecting }
        pollQueued = true
        drainOps()
    }

    // MARK: - Polling

    func startPolling() {
        pollTimer?.invalidate()
        let interval: TimeInterval = popoverVisible ? 5 : 30
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if case .unconfigured = self.connection { return }
                self.pollNow()
                self.startPolling() // reschedule at the current cadence
            }
        }
    }

    func popoverWillShow() {
        popoverVisible = true
        pollNow()
        startPolling()
    }

    func popoverDidClose() {
        popoverVisible = false
        startPolling()
    }

    // MARK: - Device operations

    func refresh() { pollNow() }

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

    /// Re-resolve the lamp's IP (DHCP may have moved it). Uses the active TCP
    /// sweep + key-confirmed probe, like the wizard: the Elgin lamp (3.5)
    /// never answers UDP broadcasts, so passive listening would never find it.
    /// User-initiated: bypasses the sweep throttle.
    func rediscover() {
        connection = .connecting
        pollQueued = true
        if target != nil {
            startScan(userInitiated: true)
            drainOps()
        }
        // config still loading async — the first poll fires once it lands
    }

    /// After the wizard finishes configuring the device.
    func deviceConfigured(name: String) {
        deviceName = name
        connection = .connecting
        lastError = nil
        loadConfigAsync(preferredName: name)
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
        target = nil
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
    }

    /// Queue DPS writes, coalescing rapid slider updates into one flush.
    private func sendDPS(_ dps: [String: Any]) {
        for (k, v) in dps { pendingDPS[k] = v }
        flushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.drainOps() }
        flushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    /// Request a status poll; coalesced into a single trailing op while
    /// another one is in flight.
    func pollNow() {
        guard target != nil else { return }
        pollQueued = true
        drainOps()
    }

    /// The single lane onto the worker queue: at most one op in flight; a
    /// pending write goes first, then one coalesced status poll.
    private func drainOps() {
        guard target != nil, !opInFlight else { return }
        if !pendingDPS.isEmpty {
            let dps = pendingDPS
            pendingDPS = [:]
            execute(label: "set", op: { try $0.setDPS(dps) }) { [weak self] success, error in
                guard let self else { return }
                if !success {
                    // the command didn't make it — keep it queued so it fires
                    // on the next successful connection instead of vanishing
                    for (k, v) in dps { self.pendingDPS[k] = v }
                }
                self.opFinished(success: success, error: error)
            }
            return
        }
        if pollQueued {
            pollQueued = false
            execute(label: "status", op: { try $0.status() }) { [weak self] success, error in
                guard let self else { return }
                if success { self.lastError = nil }
                self.opFinished(success: success, error: error)
            }
        }
    }

    private func execute(label: String,
                         op: @escaping (TuyaDevice) throws -> [String: Any]?,
                         completion: @escaping (Bool, Error?) -> Void) {
        guard let t = target else { return }
        opInFlight = true
        Self.traceLog("op.start \(label) host=\(t.host)")
        worker.async { [weak self] in
            let device = TuyaDevice(config: .init(deviceID: t.deviceId, host: t.host,
                                                  localKey: t.key, version: t.version,
                                                  timeout: 5))
            do {
                let result = try op(device)
                Self.traceLog("op.ok \(label)")
                Task { @MainActor in
                    self?.opInFlight = false
                    self?.applyStatus(result)
                    completion(true, nil)
                }
            } catch {
                Self.traceLog("op.err \(label) \(error)")
                Task { @MainActor in
                    self?.opInFlight = false
                    completion(false, error)
                }
            }
        }
    }

    private func applyStatus(_ result: [String: Any]?) {
        guard let dps = result?["dps"] as? [String: Any] else { return }
        if let kind = BulbModel.detectKind(dps: dps) { bulbKind = kind }
        if let state = BulbModel.state(from: dps) {
            bulb = state
            saveLastState(state)
        }
    }

    private func opFinished(success: Bool, error: Error?) {
        if success {
            planner.opSucceeded()
            if connection != .online { connection = .online }
        } else {
            let sweep = planner.opFailed(now: Date().timeIntervalSinceReferenceDate)
            lastError = error.map { String(describing: $0) }
            if case .offline = connection {
                // already declared offline by a sweep that found nothing —
                // stay there quietly until a poll succeeds
            } else {
                connection = .connecting
            }
            if sweep { startScan(userInitiated: false) }
        }
        drainOps()
    }

    /// Network sweep for the lamp, on its own queue so it can never jam the
    /// command lane. Throttled by the planner unless user-initiated.
    private func startScan(userInitiated: Bool) {
        guard !scanRunning, let t = target else { return }
        if userInitiated {
            planner.userScanRequested(now: Date().timeIntervalSinceReferenceDate)
        }
        scanRunning = true
        Self.traceLog("scan.start")
        scanQueue.async { [weak self] in
            let found = TuyaDiscovery.activeScan(deviceID: t.deviceId, localKey: t.key)
            Self.traceLog("scan.end found=\(found != nil)")
            Task { @MainActor in
                guard let self else { return }
                self.scanRunning = false
                if let found {
                    var cfg = ConfigStore.load()
                    cfg.ip = found.ip
                    cfg.version = Double(found.version) ?? cfg.version
                    ConfigStore.save(cfg)
                    self.target?.host = found.ip
                    if let v = Double(found.version) { self.target?.version = v }
                    self.pollQueued = true
                } else if self.target != nil {
                    self.connection = .offline("lâmpada não encontrada na rede")
                }
                self.drainOps()
            }
        }
    }

    // MARK: - favorites persistence

    static var favoritesURL: URL {
        ConfigStore.directory.appendingPathComponent("favorites.json")
    }

    static var lastStateURL: URL {
        ConfigStore.directory.appendingPathComponent("last-state.json")
    }

    /// Last observed lamp state, so the popover can show controls (with a
    /// reconnect note) even before the first poll succeeds — or when the
    /// keychain/config is slow to load.
    func loadLastState() {
        guard bulb == nil,
              let data = try? Data(contentsOf: Self.lastStateURL),
              let state = try? JSONDecoder().decode(BulbState.self, from: data) else { return }
        bulb = state
    }

    func saveLastState(_ state: BulbState) {
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.lastStateURL, options: .atomic)
        }
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
