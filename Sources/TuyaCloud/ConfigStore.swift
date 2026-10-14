import Foundation
import Security

/// Shared configuration between the app and the CLI: a JSON file in
/// Application Support plus the device local key in the Keychain.
public enum ConfigStore {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("OpenBulb", isDirectory: true)
    }

    public static var fileURL: URL {
        directory.appendingPathComponent("config.json")
    }

    public struct AppConfig: Codable, Equatable {
        public var apiKey: String?
        public var apiSecret: String?   // kept in the file only if Keychain unavailable
        public var dataCenter: String?
        public var deviceId: String?
        public var deviceName: String?
        public var ip: String?
        public var version: Double?
        /// Device local key, file-backed. The Keychain turned out to be a trap
        /// here: the item's ACL only trusts the binary that created it, and an
        /// ad-hoc re-sign on every rebuild makes reads block forever on an
        /// approval prompt a menu bar app can't show.
        public var localKey: String?

        public init() {}

        public var isDeviceConfigured: Bool {
            deviceId != nil && (ip != nil || version != nil)
        }
    }

    public static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return AppConfig() }
        return (try? JSONDecoder().decode(AppConfig.self, from: data)) ?? AppConfig()
    }

    public static func save(_ config: AppConfig) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Keychain (local key, API secret)

    static let keychainService = "com.lunaperegrina.openbulb"

    public static func keychainGet(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func keychainSet(_ value: String?, account: String) {
        guard let value else {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
    }

    public static let localKeyAccount = "device-local-key"
    public static let apiSecretAccount = "tuya-api-secret"

    /// Local key resolution order: env override (harness), config file,
    /// Keychain (legacy migration path — may block on old installs, so it is
    /// only consulted last and off the main thread).
    public static func loadLocalKey(config: AppConfig = ConfigStore.load()) -> String? {
        if let k = ProcessInfo.processInfo.environment["OPENBULB_LOCAL_KEY"],
           k.count == 16 { return k }
        if let k = config.localKey, k.count == 16 { return k }
        if let key = keychainGet(localKeyAccount), !key.isEmpty {
            migrateKeychainKeyToFile(key, config: config)
            return key
        }
        return nil
    }

    /// Once we manage to read the legacy Keychain copy, persist it to the
    /// config file so the app never needs the Keychain again.
    private static func migrateKeychainKeyToFile(_ key: String, config: AppConfig) {
        var cfg = config
        cfg.localKey = key
        save(cfg)
    }

    public static func saveLocalKey(_ key: String?) {
        // File is the source of truth; the Keychain copy is best-effort and
        // async (SecItemAdd/Update can also block on an ACL prompt).
        var cfg = load()
        cfg.localKey = key
        save(cfg)
        let queryAccount = localKeyAccount
        DispatchQueue.global(qos: .utility).async {
            keychainSet(key, account: queryAccount)
        }
    }

    public static func loadAPISecret(config: AppConfig = ConfigStore.load()) -> String? {
        if let s = keychainGet(apiSecretAccount), !s.isEmpty { return s }
        return config.apiSecret
    }

    public static func saveAPISecret(_ secret: String?) {
        keychainSet(secret, account: apiSecretAccount)
    }
}
