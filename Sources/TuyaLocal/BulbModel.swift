import Foundation

/// High-level state of a Tuya colour LED bulb, mapped to/from the device's
/// DPS (data points). Two DP layouts exist:
///
/// - Type B (protocol 3.3/3.4 "dj" category): switch=20 mode=21 brightness=22
///   (10-1000) colourtemp=23 (10-1000) colour=24 as `hhhhssssvvvv` hex.
/// - Type A (older 3.1/3.2): switch=1 mode=2 brightness=3 (25-255)
///   colourtemp=4 colour=5 as `rrggbbhhhhssvv` hex.
///
/// The layout is detected from the first status response. All UI values are
/// normalized to 0.0-1.0 doubles.
public struct BulbState: Equatable, Codable {
    public enum Mode: String, Equatable, Codable {
        case white
        case colour
        case scene
        case music
    }

    public var isOn: Bool
    public var mode: Mode
    /// 0...1
    public var brightness: Double
    /// 0...1 (warm...cool), nil when the bulb has no white temperature
    public var colorTemperature: Double?
    /// Hue 0...360, saturation 0...1, value 0...1 (current colour; valid in .colour mode)
    public var hue: Double
    public var saturation: Double
    public var colorValue: Double

    public init(isOn: Bool = false, mode: Mode = .white, brightness: Double = 1,
                colorTemperature: Double? = 0.5, hue: Double = 0,
                saturation: Double = 1, colorValue: Double = 1) {
        self.isOn = isOn
        self.mode = mode
        self.brightness = brightness
        self.colorTemperature = colorTemperature
        self.hue = hue
        self.saturation = saturation
        self.colorValue = colorValue
    }
}

public enum BulbModel {
    public enum BulbKind: Equatable {
        case typeB   // DPS 20-26, values 10-1000, colour hhhhssssvvvv
        case typeA   // DPS 1-5, values 25-255, colour rrggbbhhhhssvv
    }

    public static func detectKind(dps: [String: Any]) -> BulbKind? {
        if dps.keys.contains("20") { return .typeB }
        if dps.keys.contains("1") { return .typeA }
        return nil
    }

    // MARK: DPS -> BulbState

    public static func state(from dps: [String: Any]) -> BulbState? {
        guard let kind = detectKind(dps: dps) else { return nil }
        switch kind {
        case .typeB: return stateTypeB(dps)
        case .typeA: return stateTypeA(dps)
        }
    }

    static func stateTypeB(_ dps: [String: Any]) -> BulbState {
        var s = BulbState()
        s.isOn = (dps["20"] as? Bool) ?? false
        s.mode = BulbState.Mode(rawValue: (dps["21"] as? String) ?? "") ?? .white
        if let bright = dps["22"] as? Int {
            s.brightness = normalize(clamp(Double(bright), 10, 1000), 10, 1000)
        }
        if let temp = dps["23"] as? Int {
            s.colorTemperature = normalize(clamp(Double(temp), 0, 1000), 0, 1000)
        }
        if let color = dps["24"] as? String {
            let hsv = parseColourHex(color, kind: .typeB)
            s.hue = hsv.hue
            s.saturation = hsv.saturation
            s.colorValue = hsv.value
        }
        return s
    }

    static func stateTypeA(_ dps: [String: Any]) -> BulbState {
        var s = BulbState()
        s.isOn = (dps["1"] as? Bool) ?? false
        if let modeStr = dps["2"] as? String {
            if modeStr == "white" { s.mode = .white }
            else if modeStr == "colour" { s.mode = .colour }
            else if modeStr.hasPrefix("scene") { s.mode = .scene }
            else { s.mode = .white }
        }
        if let bright = dps["3"] as? Int {
            s.brightness = normalize(clamp(Double(bright), 25, 255), 25, 255)
        }
        if let temp = dps["4"] as? Int {
            s.colorTemperature = normalize(clamp(Double(temp), 0, 255), 0, 255)
        }
        if let color = dps["5"] as? String {
            let hsv = parseColourHex(color, kind: .typeA)
            s.hue = hsv.hue
            s.saturation = hsv.saturation
            s.colorValue = hsv.value
        }
        return s
    }

    // MARK: BulbState -> DPS payload

    /// DPS payload for a full state write (used by favourites).
    public static func dpsPayload(for state: BulbState, kind: BulbKind) -> [String: Any] {
        switch kind {
        case .typeB:
            var dps: [String: Any] = ["20": state.isOn, "21": state.mode.rawValue]
            dps["22"] = Int(round(denormalize(state.brightness, 10, 1000)))
            if let temp = state.colorTemperature {
                dps["23"] = Int(round(denormalize(temp, 0, 1000)))
            }
            dps["24"] = colourHex(for: state, kind: .typeB)
            return dps
        case .typeA:
            var dps: [String: Any] = ["1": state.isOn]
            dps["2"] = state.mode == .scene ? "scene" : state.mode.rawValue
            dps["3"] = Int(round(denormalize(state.brightness, 25, 255)))
            if let temp = state.colorTemperature {
                dps["4"] = Int(round(denormalize(temp, 0, 255)))
            }
            dps["5"] = colourHex(for: state, kind: .typeA)
            return dps
        }
    }

    public static func setPower(_ on: Bool, kind: BulbKind) -> [String: Any] {
        switch kind {
        case .typeB: return ["20": on]
        case .typeA: return ["1": on]
        }
    }

    public static func setMode(_ mode: BulbState.Mode, kind: BulbKind) -> [String: Any] {
        switch kind {
        case .typeB: return ["21": mode.rawValue]
        case .typeA: return ["2": mode.rawValue]
        }
    }

    public static func setBrightness(_ v: Double, kind: BulbKind) -> [String: Any] {
        switch kind {
        case .typeB: return ["22": Int(round(denormalize(clamp01(v), 10, 1000)))]
        case .typeA: return ["3": Int(round(denormalize(clamp01(v), 25, 255)))]
        }
    }

    public static func setColorTemperature(_ v: Double, kind: BulbKind) -> [String: Any] {
        switch kind {
        case .typeB: return ["23": Int(round(denormalize(clamp01(v), 0, 1000)))]
        case .typeA: return ["4": Int(round(denormalize(clamp01(v), 0, 255)))]
        }
    }

    /// DPS for a colour change: switches to colour mode and writes HSV data.
    public static func setColor(hue: Double, saturation: Double, value: Double, kind: BulbKind) -> [String: Any] {
        var state = BulbState()
        state.hue = hue
        state.saturation = saturation
        state.colorValue = value
        switch kind {
        case .typeB: return ["21": BulbState.Mode.colour.rawValue, "24": colourHex(for: state, kind: .typeB)]
        case .typeA: return ["2": BulbState.Mode.colour.rawValue, "5": colourHex(for: state, kind: .typeA)]
        }
    }

    // MARK: colour hex encoding (HSV <-> Tuya hex string)

    public static func colourHex(hue: Double, saturation: Double, value: Double, kind: BulbKind) -> String {
        var state = BulbState()
        state.hue = hue
        state.saturation = saturation
        state.colorValue = value
        return colourHex(for: state, kind: kind)
    }

    static func colourHex(for state: BulbState, kind: BulbKind) -> String {
        let h = Int(clamp(state.hue, 0, 360))
        switch kind {
        case .typeB:
            // hhhhssssvvvv — hue 0-360, sat 0-1000, val 0-1000
            let s = Int(round(clamp01(state.saturation) * 1000))
            let v = Int(round(clamp01(state.colorValue) * 1000))
            return String(format: "%04x%04x%04x", h, s, v)
        case .typeA:
            // rrggbbhhhhssvv — rgb 0-255, hue 0-360, sat 0-255, val 0-255
            let (r, g, b) = hsvToRGB(hue: state.hue, saturation: clamp01(state.saturation), value: clamp01(state.colorValue))
            let s = Int(round(clamp01(state.saturation) * 255))
            let v = Int(round(clamp01(state.colorValue) * 255))
            return String(format: "%02x%02x%02x%04x%02x%02x", r, g, b, h, s, v)
        }
    }

    public static func parseColourHex(_ hex: String, kind: BulbKind) -> (hue: Double, saturation: Double, value: Double) {
        let chars = Array(hex)
        func hexVal(_ from: Int, _ len: Int) -> Int {
            guard from + len <= chars.count else { return 0 }
            return Int(String(chars[from..<(from + len)]), radix: 16) ?? 0
        }
        switch kind {
        case .typeB:
            guard hex.count >= 12 else { return (0, 1, 1) }
            return (Double(hexVal(0, 4)), Double(hexVal(4, 4)) / 1000.0, Double(hexVal(8, 4)) / 1000.0)
        case .typeA:
            guard hex.count >= 14 else { return (0, 1, 1) }
            return (Double(hexVal(6, 4)), Double(hexVal(10, 2)) / 255.0, Double(hexVal(12, 2)) / 255.0)
        }
    }

    // MARK: color conversion

    /// HSV (h 0-360, s/v 0-1) -> RGB 0-255
    public static func hsvToRGB(hue: Double, saturation: Double, value: Double) -> (Int, Int, Int) {
        let c = value * saturation
        let hp = hue.truncatingRemainder(dividingBy: 360) / 60.0
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = value - c
        return (Int(round((r1 + m) * 255)), Int(round((g1 + m) * 255)), Int(round((b1 + m) * 255)))
    }

    /// RGB 0-255 -> HSV (h 0-360, s/v 0-1)
    public static func rgbToHSV(r: Double, g: Double, b: Double) -> (hue: Double, saturation: Double, value: Double) {
        let rn = r / 255, gn = g / 255, bn = b / 255
        let maxV = Swift.max(rn, Swift.max(gn, bn))
        let minV = Swift.min(rn, Swift.min(gn, bn))
        let delta = maxV - minV
        var hue: Double = 0
        if delta > 0 {
            if maxV == rn { hue = 60 * (((gn - bn) / delta).truncatingRemainder(dividingBy: 6)) }
            else if maxV == gn { hue = 60 * ((bn - rn) / delta + 2) }
            else { hue = 60 * ((rn - gn) / delta + 4) }
            if hue < 0 { hue += 360 }
        }
        let saturation = maxV == 0 ? 0 : delta / maxV
        return (hue, saturation, maxV)
    }

    // MARK: helpers

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.min(Swift.max(v, lo), hi)
    }

    static func clamp01(_ v: Double) -> Double {
        clamp(v, 0, 1)
    }

    static func normalize(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        hi == lo ? 0 : (v - lo) / (hi - lo)
    }

    static func denormalize(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        lo + clamp01(v) * (hi - lo)
    }
}
