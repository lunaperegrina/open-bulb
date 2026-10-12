import Foundation
import CryptoKit

#if canImport(Darwin)
import Darwin
#endif

/// A device found via Tuya UDP broadcast.
public struct TuyaDiscoveredDevice: Equatable {
    public var id: String        // gwId
    public var ip: String
    public var version: String   // "3.1", "3.3", "3.4"...
    public var productKey: String
    public var raw: [String: Any]

    public static func == (lhs: TuyaDiscoveredDevice, rhs: TuyaDiscoveredDevice) -> Bool {
        lhs.id == rhs.id && lhs.ip == rhs.ip
    }
}

/// Listens for Tuya UDP broadcasts to find devices on the local network.
///
/// - Port 6666: v3.1/3.2 plaintext JSON (or AES-ECB with the shared udp key)
/// - Port 6667: v3.3/3.4 framed `UDP_NEW` (0x13) packets, AES-ECB(udpKey)
/// - 6699 prefix frames (v3.5): AES-GCM with the same shared key
///
/// Devices broadcast every few seconds, so listening for ~6-10s sees them all.
public enum TuyaDiscovery {
    public static let udpPort = 6666
    public static let udpPortEncrypted = 6667

    /// Listen for broadcasts for `duration` seconds and return everything found.
    public static func scan(duration: TimeInterval = 8) -> [TuyaDiscoveredDevice] {
        var found: [String: TuyaDiscoveredDevice] = [:]
        var sockets: [Int32] = []

        for port in [UInt16(6666), UInt16(6667)] {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { continue }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
            let bindRC = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRC != 0 {
                close(fd)
                continue
            }
            var tv = timeval(tv_sec: 0, tv_usec: 200_000) // 200ms read timeout
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            sockets.append(fd)
        }
        defer { sockets.forEach { close($0) } }
        guard !sockets.isEmpty else { return [] }

        let deadline = Date().addingTimeInterval(duration)
        var buffer = [UInt8](repeating: 0, count: 512)
        var pfd = sockets.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }

        while Date() < deadline {
            let waitMs = Int32(min(1.0, deadline.timeIntervalSinceNow) * 1000)
            let rc = poll(&pfd, nfds_t(pfd.count), max(waitMs, 50))
            if rc <= 0 { continue }
            for i in 0..<pfd.count where pfd[i].revents & Int16(POLLIN) != 0 {
                let n = recv(pfd[i].fd, &buffer, buffer.count, 0)
                guard n > 0 else { continue }
                let data = Data(buffer[0..<n])
                if let device = parse(data) {
                    // the JSON "ip" field is what the device claims; fall back to it
                    found[device.id] = device
                }
            }
        }
        return Array(found.values)
    }

    /// Find one device by id, or the first device if id is nil.
    public static func findDevice(id: String? = nil, ip: String? = nil,
                                  duration: TimeInterval = 8) -> TuyaDiscoveredDevice? {
        let devices = scan(duration: duration)
        if let id { return devices.first { $0.id == id } }
        if let ip { return devices.first { $0.ip == ip } }
        return devices.first
    }

    // MARK: - Active scan (TCP port 6668)

    /// IPv4 networks of this Mac (Wi-Fi/Ethernet interfaces, non-loopback),
    /// addresses in host byte order.
    public static func localNetworks() -> [(addr: UInt32, mask: UInt32)] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var result: [(UInt32, UInt32)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(ifa.pointee.ifa_flags) & IFF_UP) == IFF_UP,
                  (Int32(ifa.pointee.ifa_flags) & IFF_LOOPBACK) == 0,
                  let netmask = ifa.pointee.ifa_netmask else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard mask > 0, addr & mask != 0 else { continue }
            if !result.contains(where: { $0.0 & $0.1 == addr & mask }) {
                result.append((addr, mask))
            }
        }
        return result
    }

    /// All usable host IPs of the local networks (network and broadcast
    /// excluded). Networks wider than /22 are clamped per-interface.
    public static func candidateHosts(limitPerNetwork: Int = 1024) -> [String] {
        var hosts: [String] = []
        for (addr, mask) in localNetworks() {
            let size = UInt32.max & ~mask          // number of host addresses
            guard size >= 2 else { continue }
            let network = addr & mask
            let step = max(size / UInt32(limitPerNetwork), 1)
            var host = network + 1
            while host < network + size {
                hosts.append(String(format: "%d.%d.%d.%d",
                                    (host >> 24) & 0xff, (host >> 16) & 0xff,
                                    (host >> 8) & 0xff, host & 0xff))
                host += max(step, 1)
                if step > 1 { /* wide network: sampled, still covers .1/.254 etc. */ }
            }
        }
        return hosts
    }

    /// Quick non-blocking TCP connect check.
    static func portOpen(_ host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        return soError == 0
    }

    /// Nudge macOS to show the Local Network permission prompt: apps that
    /// only listen passively never trigger it, and broadcasts are then
    /// dropped silently. One harmless UDP packet does the trick.
    public static func triggerLocalNetworkPrompt() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(6666).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_BROADCAST)
        let payload = Data("ping".utf8)
        _ = payload.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// The local IPv4 address the default route would use (UDP connect sends
    /// nothing; it just makes the routing table pick an interface).
    public static func defaultRouteIPv4() -> UInt32? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(53).bigEndian
        inet_pton(AF_INET, "8.8.8.8", &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 || errno == EINPROGRESS else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRC = withUnsafeMutablePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard nameRC == 0 else { return nil }
        return UInt32(bigEndian: local.sin_addr.s_addr)
    }

    /// Sweep the local network(s) for hosts with Tuya's TCP port open.
    /// The default-route network goes first, VM bridges later.
    public static func tcpScan(port: UInt16 = 6668, timeout: TimeInterval = 1.0,
                               progress: ((Int, Int) -> Void)? = nil) -> [String] {
        triggerLocalNetworkPrompt()
        let primary = defaultRouteIPv4()
        func isPrimary(_ net: (addr: UInt32, mask: UInt32)) -> Bool {
            guard let primary else { return false }
            return primary & net.mask == net.addr & net.mask
        }
        let networks = localNetworks().sorted { a, b in
            let (pa, pb) = (isPrimary(a), isPrimary(b))
            if pa != pb { return pa }
            return a.addr < b.addr
        }
        var hosts: [String] = []
        for (addr, mask) in networks {
            let size = UInt32.max & ~mask
            guard size >= 2 else { continue }
            let network = addr & mask
            var host = network + 1
            while host < network + size {
                hosts.append(String(format: "%d.%d.%d.%d",
                                    (host >> 24) & 0xff, (host >> 16) & 0xff,
                                    (host >> 8) & 0xff, host & 0xff))
                host += 1
            }
        }
        let queue = DispatchQueue(label: "openbulb.tcpscan", attributes: .concurrent)
        let semaphore = DispatchSemaphore(value: 96)
        let group = DispatchGroup()
        let lock = NSLock()
        var openHosts: [String] = []
        var done = 0

        for host in hosts {
            group.enter()
            queue.async {
                defer { group.leave() }
                semaphore.wait()
                defer { semaphore.signal() }
                if portOpen(host, port: port, timeout: timeout) {
                    lock.lock()
                    openHosts.append(host)
                    lock.unlock()
                }
                lock.lock()
                done += 1
                let snapshot = (done, hosts.count)
                lock.unlock()
                progress?(snapshot.0, snapshot.1)
            }
        }
        group.wait()
        return openHosts.sorted { a, b in
            Int(a.split(separator: ".").last.map { Int($0) ?? 0 } ?? 0)
                < Int(b.split(separator: ".").last.map { Int($0) ?? 0 } ?? 0)
        }
    }

    /// Confirm a candidate host is *our* device by asking for its status with
    /// the real local key — only the right device/key decrypts to valid JSON.
    /// Returns the protocol version that worked and the dps map.
    public static func probe(host: String, deviceID: String,
                             localKey: Data) -> (version: Double, dps: [String: Any])? {
        for v in [3.3, 3.4, 3.5, 3.1] {
            let device = TuyaDevice(config: .init(deviceID: deviceID, host: host,
                                                  localKey: localKey, version: v, timeout: 2.5))
            defer { device.disconnect() }
            if let result = try? device.status(),
               let dps = result["dps"] as? [String: Any] {
                return (v, dps)
            }
        }
        return nil
    }

    /// Active discovery: TCP-sweep the subnet for port 6668, then confirm the
    /// device with the local key. Works even when UDP broadcasts never reach
    /// the Mac (macOS Local Network privacy, band isolation, …).
    public static func activeScan(deviceID: String, localKey: Data,
                                  progress: ((String) -> Void)? = nil) -> TuyaDiscoveredDevice? {
        progress?("varrendo a rede…")
        var hosts = tcpScan { done, total in
            if done % 32 == 0 || done == total {
                progress?("varrendo a rede… \(done)/\(total)")
            }
        }
        // the first sweep may have raced the Local Network permission prompt
        // (macOS blocks local traffic until the user taps Allow) — one retry
        if hosts.isEmpty {
            progress?("aguardando a permissão de Rede Local…")
            Thread.sleep(forTimeInterval: 2.5)
            progress?("varrendo a rede de novo…")
            hosts = tcpScan { _, _ in }
        }
        for host in hosts {
            progress?("testando \(host)…")
            if let hit = probe(host: host, deviceID: deviceID, localKey: localKey) {
                return TuyaDiscoveredDevice(id: deviceID, ip: host,
                                            version: String(hit.version),
                                            productKey: "", raw: hit.dps)
            }
        }
        return nil
    }

    // MARK: - packet parsing

    public static func parse(_ data: Data) -> TuyaDiscoveredDevice? {
        guard !data.isEmpty else { return nil }
        var json: Data? = nil

        if data.starts(with: Data("{".utf8)) {
            // plaintext JSON broadcast (port 6666, common for 3.1)
            json = data
        } else if data.readBE32(0) == 0x0000_6699 {
            // v3.5 GCM-framed broadcast
            json = decrypt6699(data)
        } else if data.readBE32(0) == TuyaFrame.prefix {
            // 55AA-framed (port 6667: cmd 0x13 UDP_NEW, or odd 6666 variants)
            json = decrypt55AAUDP(data)
        } else {
            // raw AES-ECB(udpKey) JSON on port 6666
            json = TuyaCrypto.aesECBDecrypt(key: TuyaCrypto.udpKey, ciphertext: data)
        }

        guard let json, let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let id = obj["gwId"] as? String ?? obj["devId"] as? String else {
            return nil
        }
        let ip = (obj["ip"] as? String) ?? ""
        let version = (obj["version"] as? String) ?? ""
        let productKey = (obj["productKey"] as? String) ?? ""
        guard !ip.isEmpty, !version.isEmpty else { return nil }
        return TuyaDiscoveredDevice(id: id, ip: ip, version: version,
                                    productKey: productKey, raw: obj)
    }

    static func decrypt55AAUDP(_ data: Data) -> Data? {
        // header(16) + [4-byte retcode-ish] + payload + crc(4) + suffix(4)
        guard data.count > 16 + 4 + 4 + 4 else { return nil }
        let length = Int(data.readBE32(12))
        guard 16 + length <= data.count else { return nil }
        var payload = data.subdata(in: 16..<(16 + length))
        // strip trailer
        guard payload.count > 8 else { return nil }
        payload = payload.prefix(payload.count - 8)
        // strip 4-byte leading field (tinytuya treats it as a return code)
        guard payload.count > 4 else { return nil }
        payload = payload.suffix(from: 4)
        if payload.first == UInt8(ascii: "{") {
            return payload
        }
        return TuyaCrypto.aesECBDecrypt(key: TuyaCrypto.udpKey, ciphertext: payload)
    }

    static func decrypt6699(_ data: Data) -> Data? {
        // 6699 header: prefix(4) + unknown(2) + seqno(4) + cmd(4) + length(4) = 18
        guard data.count > 18 + 12 + 16 + 4 else { return nil }
        let headerLen = 18
        var body = data.subdata(in: headerLen..<data.count)
        // trailer: 16-byte GCM tag + 4-byte suffix
        guard body.count > 20 else { return nil }
        let tag = body.suffix(20).prefix(16)
        body = body.prefix(body.count - 20)
        let iv = body.prefix(12)
        let ciphertext = body.suffix(from: 12)
        do {
            let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                               ciphertext: ciphertext, tag: tag)
            let key = SymmetricKey(data: TuyaCrypto.udpKey)
            let plain = try AES.GCM.open(sealed, using: key,
                                         authenticating: data.subdata(in: 4..<headerLen))
            var text = String(data: plain, encoding: .utf8) ?? ""
            // app sometimes appends NUL bytes
            while text.hasSuffix("\0") { text.removeLast() }
            return Data(text.utf8)
        } catch {
            return nil
        }
    }
}
