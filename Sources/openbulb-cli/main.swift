import Foundation
import TuyaLocal
import TuyaCloud

/// Debug CLI for Open Bulb — talk to the lamp directly from the terminal.
/// Config comes from ~/Library/Application Support/OpenBulb/config.json
/// (same store the app uses), or from flags.

struct CLIOptions {
    var id: String?
    var key: String?
    var ip: String?
    var version: Double?
    var timeout: TimeInterval = 6
    var discoverSeconds: TimeInterval = 8
    var brightness: Double?
    var temp: Double?
    var hsv: String?
    var rgb: String?
    var mode: String?
    var on: Bool?

    static func parse(_ args: [String]) -> (command: String?, opts: CLIOptions) {
        var o = CLIOptions()
        var command: String? = nil
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--id": o.id = args.value(at: i); i += 1
            case "--key": o.key = args.value(at: i); i += 1
            case "--ip": o.ip = args.value(at: i); i += 1
            case "--version": o.version = Double(args.value(at: i) ?? ""); i += 1
            case "--timeout": o.timeout = Double(args.value(at: i) ?? "") ?? 6; i += 1
            case "--discover-seconds": o.discoverSeconds = Double(args.value(at: i) ?? "") ?? 8; i += 1
            case "--brightness": o.brightness = Double(args.value(at: i) ?? ""); i += 1
            case "--temp": o.temp = Double(args.value(at: i) ?? ""); i += 1
            case "--hsv": o.hsv = args.value(at: i); i += 1
            case "--rgb": o.rgb = args.value(at: i); i += 1
            case "--mode": o.mode = args.value(at: i); i += 1
            default:
                if a.hasPrefix("--") {
                    FileHandle.standardError.write("unknown flag \(a)\n".data(using: .utf8)!)
                    exit(2)
                }
                command = a
            }
            i += 1
        }
        return (command, o)
    }
}

extension Array where Element == String {
    func value(at i: Int) -> String? {
        i + 1 < count ? self[i + 1] : nil
    }
}

func makeDevice(_ opts: CLIOptions, autoDiscover: Bool) throws -> TuyaDevice {
    let cfg = ConfigStore.load()
    let id = opts.id ?? cfg.deviceId
    let keyStr = opts.key ?? ConfigStore.loadLocalKey() ?? cfg.apiKey // --key wins; else keychain
    var ip = opts.ip ?? cfg.ip
    var version = opts.version ?? cfg.version

    guard let id, !id.isEmpty else {
        throw UsageError("device id missing: run `openbulb-cli config --id <deviceId> --key <localKey>` or pass --id")
    }
    guard let keyStr, keyStr.count == 16, let keyData = keyStr.data(using: .utf8) else {
        throw UsageError("local key missing or not 16 chars: pass --key or store it first")
    }

    if autoDiscover && (ip == nil || version == nil) {
        print("⌛ discovering device \(id) on the network (listening for UDP broadcasts)…")
        if let found = TuyaDiscovery.findDevice(id: id, duration: opts.discoverSeconds) {
            print("   found at \(found.ip) version \(found.version)")
            ip = found.ip
            version = Double(found.version) ?? version
        } else if ip == nil {
            throw UsageError("device not found on network (is it powered on and on this WiFi?)")
        }
    }

    guard let ip else { throw UsageError("device IP unknown: pass --ip or let discovery find it") }
    let v = version ?? 3.3
    return TuyaDevice(config: .init(deviceID: id, host: ip, localKey: keyData, version: v,
                                    timeout: opts.timeout))
}

struct UsageError: Error, CustomStringConvertible {
    var description: String
    init(_ s: String) { self.description = s }
}

func fmtHost(_ addr: UInt32) -> String {
    String(format: "%d.%d.%d.%d", (addr >> 24) & 0xff, (addr >> 16) & 0xff,
            (addr >> 8) & 0xff, addr & 0xff)
}

func printDPS(_ dps: [String: Any]) {
    let keys = dps.keys.sorted { Int($0) ?? 0 < Int($1) ?? 0 }
    for k in keys {
        print("  dps[\(k)] = \(dps[k]!)" + (dps[k] is String ? "  \"\(dps[k]!)\"" : ""))
    }
}

func printState(_ state: BulbState) {
    print("state: \(state.isOn ? "ON" : "OFF")  mode=\(state.mode.rawValue)  brightness=\(Int(round(state.brightness * 100)))%")
    if let temp = state.colorTemperature {
        print("       white temp=\(Int(round(temp * 100)))% (0=warm, 100=cool)")
    }
    print("       colour h=\(Int(state.hue))° s=\(Int(round(state.saturation * 100)))% v=\(Int(round(state.colorValue * 100)))%")
    let rgb = BulbModel.hsvToRGB(hue: state.hue, saturation: state.saturation, value: state.colorValue)
    print("       rgb=(\(rgb.0), \(rgb.1), \(rgb.2))")
}

// MARK: - main

let (command, opts) = CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))

do {
    switch command {
    case nil, "help":
        print("""
        openbulb-cli — debug tool for the Open Bulb menu bar app

        Usage:
          openbulb-cli config [--id ID] [--key KEY] [--ip IP] [--version 3.4]   store config
          openbulb-cli config --show                                           print stored config
          openbulb-cli discover [--discover-seconds 8]                         list Tuya devices on the LAN (passive UDP)
          openbulb-cli scan [--id ID --key KEY]                                sweep the subnet for Tuya devices (active TCP); with id+key probes each
          openbulb-cli dump                                                    full DPS + decoded state
          openbulb-cli on | off                                                power
          openbulb-cli set --brightness 0.5                                    brightness 0-1
          openbulb-cli set --temp 0.5                                          white temperature 0-1 (warm-cool)
          openbulb-cli set --rgb 255,0,0                                       colour as r,g,b
          openbulb-cli set --hsv 120,1,1                                       colour as h,s,v
          openbulb-cli set --mode white|colour                                 mode switch

        Flags override stored config: --id --key --ip --version --timeout
        """)

    case "config":
        if opts.id != nil || opts.key != nil || opts.ip != nil || opts.version != nil {
            var cfg = ConfigStore.load()
            if let v = opts.id { cfg.deviceId = v }
            if let v = opts.ip { cfg.ip = v }
            if let v = opts.version { cfg.version = v }
            if let v = opts.key { ConfigStore.saveLocalKey(v) }
            ConfigStore.save(cfg)
            print("saved \(ConfigStore.fileURL.path)")
        }
        let cfg = ConfigStore.load()
        let key = ConfigStore.loadLocalKey() ?? "<none>"
        print("config file : \(ConfigStore.fileURL.path)")
        print("device id   : \(cfg.deviceId ?? "<none>")")
        print("local key   : \(key.prefix(4))…\(key.suffix(2)) (\(key.count) chars)")
        print("ip          : \(cfg.ip ?? "<auto-discover>")")
        print("version     : \(cfg.version.map { String($0) } ?? "<auto>")")
        print("api key     : \(cfg.apiKey ?? "<none>") / dc \(cfg.dataCenter ?? "?")")

    case "discover":
        print("⌛ listening for Tuya UDP broadcasts for \(Int(opts.discoverSeconds))s…")
        let devices = TuyaDiscovery.scan(duration: opts.discoverSeconds)
        if devices.isEmpty {
            print("no Tuya devices found")
        } else {
            for d in devices {
                print("  \(d.ip)  id=\(d.id)  version=\(d.version)  product=\(d.productKey)")
            }
        }

    case "scan":
        let cfg = ConfigStore.load()
        let id = opts.id ?? cfg.deviceId
        let keyStr = opts.key ?? ConfigStore.loadLocalKey()
        let nets = TuyaDiscovery.localNetworks()
        if nets.isEmpty {
            throw UsageError("no IPv4 network found (Wi-Fi/Ethernet down?)")
        }
        for (addr, mask) in nets {
            print("network: \(fmtHost(addr & mask))/\(mask.nonzeroBitCount)")
        }
        print("⌛ sweeping subnet(s) for TCP port 6668…")
        let hosts = TuyaDiscovery.tcpScan { done, total in
            print("\rswept \(done)/\(total)", terminator: "")
            fflush(stdout)
        }
        print("")
        if hosts.isEmpty {
            print("no host with port 6668 open — check Local Network permission for the terminal")
        }
        for host in hosts {
            if let id, let keyStr, keyStr.count == 16 {
                if let hit = TuyaDiscovery.probe(host: host, deviceID: id,
                                                 localKey: Data(keyStr.utf8)) {
                    print("  ✅ \(host)  OUR device \(id)  version=\(hit.version)")
                    for (k, v) in hit.dps.sorted(by: { Int($0.key) ?? 0 < Int($1.key) ?? 0 }) {
                        print("       dps[\(k)] = \(v)")
                    }
                } else {
                    print("  ❓ \(host)  Tuya port open but probe failed (other device?)")
                }
            } else {
                print("  ❓ \(host)  Tuya-compatible (pass --id/--key to confirm)")
            }
        }

    case "dump":
        let device = try makeDevice(opts, autoDiscover: true)
        let result = try device.status()
        guard let dps = result["dps"] as? [String: Any] else {
            print("raw response: \(result)")
            throw UsageError("no dps in response")
        }
        print("raw DPS:")
        printDPS(dps)
        if let state = BulbModel.state(from: dps) {
            printState(state)
        } else {
            print("(could not map DPS to a known bulb layout)")
        }

    case "on", "off":
        let device = try makeDevice(opts, autoDiscover: true)
        let result = try device.status()
        guard let dps = result["dps"] as? [String: Any],
              let kind = BulbModel.detectKind(dps: dps) else {
            throw UsageError("could not detect bulb type — run `dump` first")
        }
        try device.setDPS(BulbModel.setPower(command == "on", kind: kind))
        print(command == "on" ? "💡 on" : "⚫ off")

    case "set":
        let device = try makeDevice(opts, autoDiscover: true)
        let result = try device.status()
        guard let dps = result["dps"] as? [String: Any],
              let kind = BulbModel.detectKind(dps: dps) else {
            throw UsageError("could not detect bulb type — run `dump` first")
        }
        if let m = opts.mode {
            guard let mode = BulbState.Mode(rawValue: m) else {
                throw UsageError("mode must be white or colour")
            }
            try device.setDPS(BulbModel.setMode(mode, kind: kind))
            print("mode → \(m)")
        }
        if let b = opts.brightness {
            try device.setDPS(BulbModel.setBrightness(b, kind: kind))
            print("brightness → \(Int(round(b * 100)))%")
        }
        if let t = opts.temp {
            try device.setDPS(BulbModel.setColorTemperature(t, kind: kind))
            print("white temp → \(Int(round(t * 100)))%")
        }
        if let hsvStr = opts.hsv {
            let parts = hsvStr.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 3 else { throw UsageError("--hsv expects h,s,v e.g. 120,1,1") }
            try device.setDPS(BulbModel.setColor(hue: parts[0], saturation: parts[1],
                                                 value: parts[2], kind: kind))
            print("colour → h\(Int(parts[0])) s\(parts[1]) v\(parts[2])")
        }
        if let rgbStr = opts.rgb {
            let parts = rgbStr.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 3 else { throw UsageError("--rgb expects r,g,b e.g. 255,0,0") }
            let hsv = BulbModel.rgbToHSV(r: parts[0], g: parts[1], b: parts[2])
            try device.setDPS(BulbModel.setColor(hue: hsv.hue, saturation: hsv.saturation,
                                                 value: hsv.value, kind: kind))
            print("colour → rgb(\(rgbStr))")
        }

    default:
        throw UsageError("unknown command '\(command!)' — try `help`")
    }
} catch let e as UsageError {
    FileHandle.standardError.write("error: \(e.description)\n".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
