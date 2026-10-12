import Foundation
import CryptoKit

/// Client for the Tuya IoT OpenAPI — used only by the setup wizard to link
/// the app account and fetch the bulb's `device_id` + `local_key`.
/// Signing ported from tinytuya Cloud.py (post-2021 algorithm).
public final class TuyaCloudClient {
    public enum DataCenter: String, CaseIterable {
        case us = "us"        // Western America (AZ) — usual home for Brazil accounts
        case usEast = "us-e"  // Eastern America (UE)
        case eu = "eu"
        case euWest = "eu-w"  // Western Europe (WE)
        case in_ = "in"
        case sg = "sg"
        case cn = "cn"

        public var host: String {
            switch self {
            case .us: return "openapi.tuyaus.com"
            case .usEast: return "openapi-ueaz.tuyaus.com"
            case .eu: return "openapi.tuyaeu.com"
            case .euWest: return "openapi-weaz.tuyaeu.com"
            case .in_: return "openapi.tuyain.com"
            case .sg: return "openapi-sg.iotbing.com"
            case .cn: return "openapi.tuyacn.com"
            }
        }
    }

    public enum CloudError: Error, CustomStringConvertible {
        case badCredentials(String)
        case http(Int, String)
        case api(String, String)   // code, msg
        case noDataCenter

        public var description: String {
            switch self {
            case .badCredentials(let why): return "credenciais inválidas: \(why)"
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
            case .api(let code, let msg): return "Tuya API erro \(code): \(msg)"
            case .noDataCenter: return "nenhum data center aceitou as credenciais"
            }
        }
    }

    public struct Device: Decodable, Identifiable {
        public var id: String
        public var name: String?
        public var localKey: String?
        public var category: String?
        public var product_name: String?
        public var online: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name, category, online
            case localKey = "local_key"
            case product_name
        }
    }

    public struct CloudConfig: Codable {
        public var apiKey: String
        public var apiSecret: String
        public var dataCenter: String
        public init(apiKey: String, apiSecret: String, dataCenter: String) {
            self.apiKey = apiKey
            self.apiSecret = apiSecret
            self.dataCenter = dataCenter
        }
    }

    public private(set) var config: CloudConfig
    var session: URLSession
    var token: String?
    var tokenExpiry = Date.distantPast

    /// Token validity window (Tuya tokens last 2h; refresh earlier).
    let tokenLifetime: TimeInterval = 3600

    public init(config: CloudConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public var dataCenter: DataCenter {
        DataCenter(rawValue: config.dataCenter) ?? .us
    }

    public var dataCenterHost: String { dataCenter.host }

    /// Try each data center with the given credentials until one accepts
    /// them. Returns the working config.
    @discardableResult
    public static func detectDataCenter(apiKey: String, apiSecret: String,
                                        session: URLSession = .shared) async throws -> TuyaCloudClient {
        for dc in DataCenter.allCases {
            let client = TuyaCloudClient(
                config: CloudConfig(apiKey: apiKey, apiSecret: apiSecret, dataCenter: dc.rawValue),
                session: session)
            do {
                try await client.fetchToken(force: true)
                return client
            } catch let e as CloudError {
                if case .badCredentials = e { throw e } // 1010/1005: wrong key, no point trying others
            }
        }
        throw CloudError.noDataCenter
    }

    // MARK: - Public API

    /// Devices linked to the app account bound to this cloud project.
    public func listDevices() async throws -> [Device] {
        let obj: [String: Any] = try await get("/v1.0/iot-01/associated-users/devices",
                                               query: ["size": "75"])
        guard let result = obj["result"] as? [String: Any] else { return [] }
        let list = result["devices"] as? [[String: Any]] ?? []
        return list.compactMap { try? JSONDecoder().decode(Device.self, from: JSONSerialization.data(withJSONObject: $0)) }
    }

    /// Fetch a fresh QR ticket for app-account linking. Returns the raw
    /// ticket/URL string to render as a QR code, or nil when the endpoint is
    /// not available for this project (the web portal QR remains the fallback).
    public func fetchLinkQRTicket() async throws -> String? {
        do {
            let obj: [String: Any] = try await get("/v1.0/iot-01/oauth/third/qrcode/ticket",
                                                   query: ["app_schema": "tuyaSmart"])
            guard let result = obj["result"] as? [String: Any] else { return nil }
            if let ticket = result["ticket"] as? String { return ticket }
            if let url = result["url"] as? String { return url }
            return nil
        } catch let e as CloudError {
            if case .http(404, _) = e { return nil }
            if case .http(405, _) = e { return nil }
            throw e
        }
    }

    // MARK: - Token

    func fetchToken(force: Bool = false) async throws {
        if !force, let token, Date() < tokenExpiry { return }
        let obj: [String: Any] = try await get("/v1.0/token", query: ["grant_type": "1"], withToken: false)
        guard let result = obj["result"] as? [String: Any],
              let accessToken = result["access_token"] as? String else {
            throw CloudError.badCredentials("resposta sem access_token")
        }
        self.token = accessToken
        self.tokenExpiry = Date().addingTimeInterval(tokenLifetime)
    }

    // MARK: - Signed request

    func get(_ path: String, query: [String: String]? = nil, withToken: Bool = true) async throws -> [String: Any] {
        if withToken { try await fetchToken() }
        var components = URLComponents()
        components.scheme = "https"
        components.host = dataCenterHost
        components.path = path
        // signature is computed over the unencoded query string with keys sorted
        var signQuery = ""
        if let query, !query.isEmpty {
            let sorted = query.sorted { $0.key < $1.key }
            signQuery = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            components.queryItems = sorted.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let url = components.url!
        let signURL = signQuery.isEmpty ? path : path + "?" + signQuery

        let request = signedRequest(url: url, method: "GET", body: nil, signPath: signURL, withToken: withToken)
        return try await perform(request)
    }

    func signedRequest(url: URL, method: String, body: Data?, signPath: String, withToken: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        let now = String(Int(Date().timeIntervalSince1970 * 1000))

        var payload = config.apiKey
        if withToken { payload += (token ?? "") }
        payload += now
        // post-2021 string-to-sign: METHOD \n SHA256(body) \n headers \n path
        let bodyHash = TuyaCloudSign.sha256Hex(body ?? Data())
        payload += "\(method)\n\(bodyHash)\n\n\(signPath)"

        let sign = TuyaCloudSign.hmacSHA256HexUpper(key: Data(config.apiSecret.utf8),
                                                    data: Data(payload.utf8))
        request.setValue(config.apiKey, forHTTPHeaderField: "client_id")
        request.setValue(sign, forHTTPHeaderField: "sign")
        request.setValue(now, forHTTPHeaderField: "t")
        request.setValue("HMAC-SHA256", forHTTPHeaderField: "sign_method")
        request.setValue("cors", forHTTPHeaderField: "mode")
        if withToken { request.setValue(token, forHTTPHeaderField: "access_token") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    func perform(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudError.http(-1, error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CloudError.http(-1, "no HTTP response")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        // success flag may be missing; treat explicit false + code as error
        if let success = obj["success"] as? Bool, !success {
            let code = String(describing: obj["code"] ?? "?")
            let msg = (obj["msg"] as? String) ?? ""
            // 1010 = permission denied / expired trial; 1005 = bad key
            if code == "1010" || code == "1005" || code == "1003" {
                throw CloudError.badCredentials("\(code) \(msg)")
            }
            throw CloudError.api(code, msg)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        return obj
    }
}

enum TuyaCloudSign {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256HexUpper(key: Data, data: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return mac.map { String(format: "%02X", $0) }.joined()
    }
}
