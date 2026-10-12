import Foundation
import CommonCrypto
import CryptoKit

#if canImport(Glibc)
import Glibc
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Debug logging helper (stderr, env-gated).
enum DeviceDebug {
    static var enabled = ProcessInfo.processInfo.environment["OPENBULB_DEBUG"] != nil
    static func log(_ s: String) {
        guard enabled else { return }
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
    static func hex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }
}

/// Blocking TCP client for a Tuya device on the local network (port 6668).
///
/// All methods are synchronous and must be called from a single background
/// thread/queue (the app serializes on one). Implements protocol versions
/// 3.1, 3.3 (AES-ECB + CRC32) and 3.4 (session key negotiation, AES-ECB +
/// HMAC-SHA256). Ported from tinytuya's XenonDevice.
public final class TuyaDevice {
    public enum DeviceError: Error, CustomStringConvertible {
        case offline
        case connectFailed(String)
        case timeout
        case keyOrVersion
        case payload(String)
        case jsonError(String)
        case unsupportedVersion(Double)
        case device22Detected
        case hmacFailed
        case notConnected

        public var description: String {
            switch self {
            case .offline: return "device offline (not found on network)"
            case .connectFailed(let why): return "connect failed: \(why)"
            case .timeout: return "timed out talking to device"
            case .keyOrVersion: return "bad local key or protocol version"
            case .payload(let why): return "bad payload: \(why)"
            case .jsonError(let why): return "JSON error: \(why)"
            case .unsupportedVersion(let v): return "unsupported protocol version \(v)"
            case .device22Detected: return "device requires device22 quirks (unsupported)"
            case .hmacFailed: return "HMAC verification failed"
            case .notConnected: return "not connected"
            }
        }
    }

    public struct Config {
        public var deviceID: String
        public var host: String
        public var localKey: Data   // exactly 16 bytes
        public var version: Double  // 3.1, 3.3 or 3.4
        public var port: UInt16 = 6668
        public var timeout: TimeInterval = 5

        public init(deviceID: String, host: String, localKey: Data, version: Double,
                    port: UInt16 = 6668, timeout: TimeInterval = 5) {
            self.deviceID = deviceID
            self.host = host
            self.localKey = localKey
            self.version = version
            self.port = port
            self.timeout = timeout
        }
    }

    public private(set) var config: Config
    var sockfd: Int32 = -1
    var seqno: UInt32 = 1
    /// 3.4: set after session key negotiation; nil until then.
    var sessionKey: Data?

    public init(config: Config) {
        self.config = config
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection lifecycle

    public var isConnected: Bool { sockfd >= 0 }

    /// Open the TCP connection. For 3.4/3.5 devices this also runs the session
    /// key negotiation handshake. Safe to call repeatedly.
    public func connect() throws {
        if sockfd >= 0 { return }
        guard config.version == 3.1 || config.version == 3.3
                || config.version == 3.4 || config.version == 3.5 else {
            throw DeviceError.unsupportedVersion(config.version)
        }
        let fd = try openSocket(host: config.host, port: config.port, timeout: config.timeout)
        sockfd = fd
        sessionKey = nil
        if config.version >= 3.4 {
            do {
                try negotiateSessionKey()
            } catch {
                disconnect()
                throw error
            }
        }
    }

    public func disconnect() {
        if sockfd >= 0 {
            close(sockfd)
            sockfd = -1
        }
        sessionKey = nil
    }

    // MARK: - High-level operations

    /// DP_QUERY: full DPS map, e.g. ["20": true, "21": "colour", ...].
    public func status() throws -> [String: Any] {
        let json: Data
        switch config.version {
        case 3.4, 3.5:
            json = try encodeJSON([:])
            let msg = try request(TuyaCommand.dpQueryNew.rawValue, payload: json,
                                  hmacKey: sessionKey ?? config.localKey)
            return try decodePayload(msg.payload)
        default:
            let payload: [String: Any] = [
                "gwId": config.deviceID, "devId": config.deviceID,
                "uid": config.deviceID, "t": String(Int(Date().timeIntervalSince1970)),
            ]
            json = try encodeJSON(payload)
            let msg = try request(TuyaCommand.dpQuery.rawValue, payload: json, hmacKey: nil)
            return try decodePayload(msg.payload)
        }
    }

    /// CONTROL: write DPS values, e.g. ["20": true].
    @discardableResult
    public func setDPS(_ dps: [String: Any]) throws -> [String: Any]? {
        let json: Data
        switch config.version {
        case 3.4, 3.5:
            let payload: [String: Any] = [
                "protocol": 5,
                "t": Int(Date().timeIntervalSince1970),
                "data": ["dps": dps],
            ]
            json = try encodeJSON(payload)
            let msg = try request(TuyaCommand.controlNew.rawValue, payload: json,
                                  hmacKey: sessionKey ?? config.localKey)
            return try? decodePayload(msg.payload)
        default:
            let payload: [String: Any] = [
                "devId": config.deviceID, "uid": config.deviceID,
                "t": String(Int(Date().timeIntervalSince1970)),
                "dps": dps,
            ]
            json = try encodeJSON(payload)
            let msg = try request(TuyaCommand.control.rawValue, payload: json, hmacKey: nil)
            return try? decodePayload(msg.payload)
        }
    }

    /// Keep-alive; the reply carries an empty payload.
    public func heartbeat() throws {
        let payload: [String: Any] = ["gwId": config.deviceID, "devId": config.deviceID]
        let json = try encodeJSON(payload)
        _ = try request(TuyaCommand.heartbeat.rawValue, payload: json, hmacKey: hmacKeyForFraming)
    }

    /// Read one already-pushed message (e.g. STATUS frames on a persistent
    /// connection). Returns nil on timeout.
    public func readPushed(timeout: TimeInterval) throws -> TuyaMessage? {
        guard sockfd >= 0 else { throw DeviceError.notConnected }
        do {
            return try receiveFrame(timeout: timeout)
        } catch let e as DeviceError {
            if case .timeout = e { return nil }
            throw e
        }
    }

    // MARK: - Session key negotiation (3.4 / 3.5)

    func negotiateSessionKey() throws {
        sessionKey = nil
        let localNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        // step 1: our raw nonce — encodePayload adds the version-specific
        // crypto wrap (ECB inside 55AA for 3.4, GCM/6699 for 3.5)
        let step1 = try request(TuyaCommand.sessionKeyNegStart.rawValue,
                                payload: localNonce,
                                hmacKey: config.localKey,
                                expectCmd: TuyaCommand.sessionKeyNegResponse.rawValue)

        // step 2: remote nonce + HMAC(localKey, localNonce). For 3.5 the GCM
        // framing layer already decrypted it (with a 4-byte retcode prefix);
        // for 3.4 it is still AES-ECB(localKey) ciphertext.
        var resp = Data(step1.payload) // 0-based copy (slices keep old indices)
        if config.version < 3.5 {
            guard let decrypted = TuyaCrypto.aesECBDecrypt(key: config.localKey, ciphertext: resp) else {
                throw DeviceError.keyOrVersion
            }
            resp = decrypted
        } else if resp.count > 4 {
            resp = Data(resp.dropFirst(4)) // strip the inner return code
        }
        DeviceDebug.log("neg35 step2 resp[\(resp.count)]=\(DeviceDebug.hex(resp))")
        guard resp.count >= 48 else { throw DeviceError.keyOrVersion }
        let remoteNonce = Data(resp.prefix(16))
        let hmacCheck = Data(resp.suffix(32))
        let hmacExpect = TuyaCrypto.hmacSHA256(key: config.localKey, data: localNonce)
        DeviceDebug.log("neg35 step2 hmac local[\(localNonce.count)] check=\(DeviceDebug.hex(hmacCheck)) expect=\(DeviceDebug.hex(hmacExpect))")
        guard hmacExpect == hmacCheck else {
            throw DeviceError.keyOrVersion
        }

        // step 3: HMAC(localKey, remoteNonce), raw — wrapped by encodePayload
        let step3payload = TuyaCrypto.hmacSHA256(key: config.localKey, data: remoteNonce)
        _ = try request(TuyaCommand.sessionKeyNegFinish.rawValue,
                        payload: step3payload,
                        hmacKey: config.localKey,
                        getResponse: false)

        // session key from the XOR of the nonces:
        //  - 3.4: AES-ECB(realKey, xor), unpadded single block
        //  - 3.5: first 16 bytes of the GCM keystream — equivalently, the
        //    ciphertext of seal(realKey, xor, nonce = localNonce[0..<12])
        var xored = Data()
        for (a, b) in zip(localNonce, remoteNonce) { xored.append(a ^ b) }
        guard xored.count == 16 else { throw DeviceError.keyOrVersion }
        if config.version < 3.5 {
            guard let session = TuyaCrypto.aesECBEncryptUnpadded(key: config.localKey, plaintext: xored) else {
                throw DeviceError.keyOrVersion
            }
            sessionKey = session
        } else {
            do {
                let sealed = try AES.GCM.seal(xored, using: SymmetricKey(data: config.localKey),
                                              nonce: AES.GCM.Nonce(data: localNonce.prefix(12)))
                sessionKey = sealed.ciphertext
            } catch {
                throw DeviceError.keyOrVersion
            }
        }
    }

    // MARK: - Encoding

    /// Commands sent without the "3.3"/"3.4" + 12-zero payload header.
    static let noHeaderCommands: Set<UInt32> = [
        TuyaCommand.dpQuery.rawValue, TuyaCommand.dpQueryNew.rawValue,
        TuyaCommand.updateDPS.rawValue, TuyaCommand.heartbeat.rawValue,
        TuyaCommand.sessionKeyNegStart.rawValue, TuyaCommand.sessionKeyNegResponse.rawValue,
        TuyaCommand.sessionKeyNegFinish.rawValue, 0x40,
    ]

    var hmacKeyForFraming: Data? {
        config.version >= 3.4 ? (sessionKey ?? config.localKey) : nil
    }

    func encodeJSON(_ obj: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(obj) else {
            throw DeviceError.jsonError("invalid JSON object")
        }
        return try JSONSerialization.data(withJSONObject: obj) // compact, no spaces
    }

    /// Build the wire payload for a command: version header + AES-ECB.
    /// `json` is the already-serialized command JSON (or raw negotiation
    /// bytes); the crypto wrap is applied exactly once here.
    func encodePayload(cmd: UInt32, json: Data) throws -> Data {
        switch config.version {
        case 3.5:
            // GCM encryption happens in the 6699 framing layer; here we only
            // prepend the version header for commands that carry one
            var payload = json
            if !TuyaDevice.noHeaderCommands.contains(cmd) {
                payload = versionHeader("3.5") + payload
            }
            return payload
        case 3.4:
            var payload = json
            if !TuyaDevice.noHeaderCommands.contains(cmd) {
                payload = versionHeader("3.4") + payload
            }
            let key = sessionKey ?? config.localKey
            return TuyaCrypto.aesECBEncrypt(key: key, plaintext: payload)
        case 3.3:
            var payload = TuyaCrypto.aesECBEncrypt(key: config.localKey, plaintext: json)
            if !TuyaDevice.noHeaderCommands.contains(cmd) {
                payload = versionHeader("3.3") + payload
            }
            return payload
        case 3.1:
            if cmd == TuyaCommand.control.rawValue {
                // "3.1" + md5hex[8..24] + base64(AES(json))
                let encrypted = TuyaCrypto.aesECBEncrypt(key: config.localKey, plaintext: json)
                    .base64EncodedString()
                var preMd5 = Data("data=\(encrypted)||lpv=3.1||".utf8)
                preMd5.append(config.localKey)
                let digest = TuyaCrypto.md5(preMd5).map { String(format: "%02x", $0) }.joined()
                let hexSlice = String(digest.dropFirst(8).prefix(16))
                return Data(("3.1" + hexSlice + encrypted).utf8)
            }
            return json
        default:
            throw DeviceError.unsupportedVersion(config.version)
        }
    }

    func versionHeader(_ v: String) -> Data {
        Data(v.utf8) + Data(repeating: 0, count: 12)
    }

    /// Send a command JSON and wait for the first frame with a non-empty
    /// payload (empty frames are ACKs; heartbeat replies are empty).
    @discardableResult
    func request(_ cmd: UInt32, payload json: Data, hmacKey: Data?,
                 expectCmd: UInt32? = nil, getResponse: Bool = true) throws -> TuyaMessage {
        try connect()
        let wirePayload = try encodePayload(cmd: cmd, json: json)
        let message = TuyaMessage(seqno: seqno, cmd: cmd, payload: wirePayload)
        seqno &+= 1
        let frame: Data
        if config.version >= 3.5 {
            let iv = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
            frame = try TuyaFrame.pack6699(message, key: sessionKey ?? config.localKey, iv: iv)
        } else {
            frame = TuyaFrame.pack(message, hmacKey: hmacKey)
        }
        try sendAll(frame)

        guard getResponse else { return TuyaMessage(seqno: 0, cmd: cmd, payload: Data()) }

        var attempts = 0
        while attempts < 3 {
            attempts += 1
            let msg = try receiveFrame(timeout: config.timeout)
            if msg.payload.isEmpty { continue } // empty ACK, keep reading
            if let expected = expectCmd, msg.cmd != expected { continue }
            return msg
        }
        throw DeviceError.timeout
    }

    // MARK: - Decoding

    /// Decrypt a response payload and parse the JSON, unwrapping the common
    /// 3.4 `{"data":{"dps":...}}` wrapper into the top level.
    func decodePayload(_ payload: Data) throws -> [String: Any] {
        var data = payload

        if config.version >= 3.5 {
            // the GCM framing layer already decrypted; strip the inner
            // version header (when present) and the 4-byte return code that
            // 3.5 devices carry inside the plaintext
            let vh = versionHeader("3.5")
            if data.starts(with: vh) { data = data.dropFirst(vh.count) }
            if data.count > 4, data.first != UInt8(ascii: "{"), data.first != UInt8(ascii: "[") {
                data = data.dropFirst(4)
            }
        } else if config.version == 3.4 {
            guard let decrypted = TuyaCrypto.aesECBDecrypt(key: sessionKey ?? config.localKey, ciphertext: data) else {
                throw DeviceError.payload("3.4 decrypt failed")
            }
            data = decrypted
        }

        if data.starts(with: Data("3.1".utf8)) {
            data = data.dropFirst(3)
            guard data.count > 16,
                  let decrypted = TuyaCrypto.aesECBDecrypt(key: config.localKey, ciphertext: data.dropFirst(16)) else {
                throw DeviceError.payload("3.1 decrypt failed")
            }
            data = decrypted
        } else if config.version >= 3.3 {
            let header = versionHeader(String(format: "%.1f", config.version))
            if data.starts(with: header) {
                data = data.dropFirst(header.count)
            }
            if config.version < 3.4 {
                guard let decrypted = TuyaCrypto.aesECBDecrypt(key: config.localKey, ciphertext: data) else {
                    throw DeviceError.payload("3.3 decrypt failed")
                }
                data = decrypted
            }
        }

        if let text = String(data: data, encoding: .utf8), text.contains("data unvalid") {
            throw DeviceError.device22Detected
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeviceError.jsonError(String(data: data.prefix(64), encoding: .utf8) ?? "<binary>")
        }
        var result = obj
        if result["dps"] == nil,
           let inner = result["data"] as? [String: Any],
           let innerDps = inner["dps"] as? [String: Any] {
            result["dps"] = innerDps
        }
        return result
    }

    // MARK: - Socket plumbing

    func receiveFrame(timeout: TimeInterval) throws -> TuyaMessage {
        guard sockfd >= 0 else { throw DeviceError.notConnected }
        if config.version >= 3.5 {
            return try receiveFrame6699(timeout: timeout)
        }
        // minimum frame: 16 header + 4 retcode + 4 crc + 4 suffix
        var buffer = Data()
        let minLen = 16 + 4 + 4 + 4
        try recvInto(&buffer, length: minLen, timeout: timeout)

        // resync: search for the 55AA prefix
        while buffer.readBE32(0) != TuyaFrame.prefix {
            guard let range = buffer.range(of: TuyaFrame.prefixBytes) else {
                buffer = buffer.suffix(3)
                try recvInto(&buffer, length: minLen - buffer.count, timeout: timeout)
                continue
            }
            buffer = buffer.subdata(in: range.lowerBound..<buffer.endIndex)
            if buffer.count < minLen {
                try recvInto(&buffer, length: minLen - buffer.count, timeout: timeout)
            }
        }

        let total = try TuyaFrame.totalLength(of: buffer)
        if buffer.count < total {
            try recvInto(&buffer, length: total - buffer.count, timeout: timeout)
        }

        let hmacKey = hmacKeyForFraming
        let msg = try TuyaFrame.unpack(buffer, hmacKey: hmacKey)
        if config.version >= 3.4 && !msg.crcGood {
            throw DeviceError.hmacFailed
        }
        return msg
    }

    /// 3.5 receive path: 18-byte header, iv+ciphertext+tag body, 4-byte suffix.
    func receiveFrame6699(timeout: TimeInterval) throws -> TuyaMessage {
        var buffer = Data()
        let minLen = TuyaFrame.headerLength6699 + 12 + 16 + 4
        try recvInto(&buffer, length: minLen, timeout: timeout)

        while buffer.readBE32(0) != TuyaFrame.prefix6699 {
            guard let range = buffer.range(of: TuyaFrame.prefix6699Bytes) else {
                buffer = buffer.suffix(3)
                try recvInto(&buffer, length: minLen - buffer.count, timeout: timeout)
                continue
            }
            buffer = buffer.subdata(in: range.lowerBound..<buffer.endIndex)
            if buffer.count < minLen {
                try recvInto(&buffer, length: minLen - buffer.count, timeout: timeout)
            }
        }

        let total = try TuyaFrame.totalLength6699(of: buffer)
        if buffer.count < total {
            try recvInto(&buffer, length: total - buffer.count, timeout: timeout)
        }
        do {
            return try TuyaFrame.unpack6699(buffer, key: sessionKey ?? config.localKey)
        } catch {
            throw DeviceError.hmacFailed
        }
    }

    func sendAll(_ data: Data) throws {
        guard sockfd >= 0 else { throw DeviceError.notConnected }
        var sent = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while sent < data.count {
                let n = send(sockfd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if n <= 0 {
                    throw errno == EAGAIN ? DeviceError.timeout : DeviceError.connectFailed("send: errno \(errno)")
                }
                sent += n
            }
        }
    }

    func recvInto(_ buffer: inout Data, length: Int, timeout: TimeInterval) throws {
        var chunk = [UInt8](repeating: 0, count: max(length, 1))
        var remaining = length
        while remaining > 0 {
            let n = recv(sockfd, &chunk, min(remaining, chunk.count), 0)
            if n == 0 { throw DeviceError.connectFailed("connection closed by device") }
            if n < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN || errno == EWOULDBLOCK
                    ? DeviceError.timeout
                    : DeviceError.connectFailed("recv: errno \(errno)")
            }
            buffer.append(contentsOf: chunk[0..<n])
            remaining -= n
        }
    }

    func openSocket(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM // TCP
        var infoPtr: UnsafeMutablePointer<addrinfo>? = nil
        let rc = getaddrinfo(host, String(port), &hints, &infoPtr)
        guard rc == 0, let info = infoPtr else {
            throw DeviceError.connectFailed("cannot resolve \(host)")
        }
        defer { freeaddrinfo(infoPtr) }

        var lastError = "no address"
        var infoCursor: UnsafeMutablePointer<addrinfo>? = info
        while let ai = infoCursor {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd < 0 {
                lastError = "socket() failed"
                infoCursor = ai.pointee.ai_next
                continue
            }

            // non-blocking connect with poll-based timeout
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let connectRC = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
            if connectRC == 0 {
                makeBlocking(fd, timeout: timeout)
                return fd
            }
            if errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let prc = poll(&pfd, 1, Int32(timeout * 1000))
                if prc > 0 {
                    var soError: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
                    if soError == 0 {
                        makeBlocking(fd, timeout: timeout)
                        return fd
                    }
                    lastError = "connect: \(soError)"
                } else {
                    lastError = prc == 0 ? "connect timed out" : "poll failed"
                }
            } else {
                lastError = "connect: errno \(errno)"
            }
            close(fd)
            infoCursor = ai.pointee.ai_next
        }
        throw DeviceError.connectFailed(lastError)
    }

    func makeBlocking(_ fd: Int32, timeout: TimeInterval) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // TCP_NODELAY
        var noDelay: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
    }
}

extension TuyaCrypto {
    /// AES-ECB encrypt of exactly one block with no padding (used by the 3.4
    /// session key derivation).
    static func aesECBEncryptUnpadded(key: Data, plaintext: Data) -> Data? {
        guard plaintext.count == 16 else { return nil }
        var out = Data(count: 16)
        var outLen: Int = 0
        let status = plaintext.withUnsafeBytes { pIn -> CCCryptorStatus in
            out.withUnsafeMutableBytes { pOut -> CCCryptorStatus in
                key.withUnsafeBytes { pKey -> CCCryptorStatus in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode),
                            pKey.baseAddress, kCCKeySizeAES128, nil,
                            pIn.baseAddress, 16,
                            pOut.baseAddress, 16, &outLen)
                }
            }
        }
        guard status == kCCSuccess, outLen == 16 else { return nil }
        return out
    }
}
