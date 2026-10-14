import SwiftUI
import TuyaLocal

/// Design tokens for the bulb control UI — a dark, premium smart-home style.
/// Dark-only by design: the palette is fixed, not adaptive.
enum Theme {
    // MARK: Surfaces

    static let background = Color(hex: 0x0A0A0C)
    static let card = Color(hex: 0x151518)
    static let actionCard = Color(hex: 0x16161A)
    static let hairline = Color.white.opacity(0.06)

    static let segmentedContainer = Color(hex: 0x1A1A1D)
    static let segmentPill = Color(hex: 0x2E2E33)
    static let track = Color(hex: 0x232326)

    // MARK: Text

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color(hex: 0x8A8A8E)

    // MARK: White-temperature accents (warm → neutral → cool)

    static let warmWhite = Color(hex: 0xFFB56B)
    static let neutralWhite = Color(hex: 0xFFE9C7)
    static let coolWhite = Color(hex: 0xBFD7FF)
    /// Fallback for white-mode bulbs without a temperature DPS.
    static let softWhite = Color(hex: 0xFFE3B3)
    static let offAccent = Color(hex: 0x6E6E73)

    /// Continuous warm→cool gradient for the temperature slider track.
    static let temperatureGradient: [Color] = [
        Color(hex: 0xFFB56B),
        Color(hex: 0xFFF6E5),
        Color(hex: 0xC8DCFF),
    ]

    // MARK: Radii

    static let cardRadius: CGFloat = 24
    static let actionCardRadius: CGFloat = 20
    static let segmentRadius: CGFloat = 13
    static let segmentPillRadius: CGFloat = 10

    // MARK: Contextual accent

    /// The accent mirrors what the lamp is emitting right now: the white
    /// temperature tint in white mode, the current HSV colour in colour mode,
    /// or a neutral grey when off.
    static func accent(for bulb: BulbState?) -> Color {
        guard let bulb, bulb.isOn else { return offAccent }
        switch bulb.mode {
        case .colour:
            let rgb = BulbModel.hsvToRGB(hue: bulb.hue,
                                         saturation: max(bulb.saturation, 0.05),
                                         value: max(bulb.colorValue, 0.55))
            return Color(red: Double(rgb.0) / 255,
                         green: Double(rgb.1) / 255,
                         blue: Double(rgb.2) / 255)
        default:
            guard let t = bulb.colorTemperature else { return softWhite }
            if t <= 0.5 {
                return lerp(warmWhite, neutralWhite, t / 0.5)
            } else {
                return lerp(neutralWhite, coolWhite, (t - 0.5) / 0.5)
            }
        }
    }

    private static func lerp(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let cl = min(max(t, 0), 1)
        let na = NSColor(a).usingColorSpace(.deviceRGB) ?? .white
        let nb = NSColor(b).usingColorSpace(.deviceRGB) ?? .white
        return Color(red: Double(na.redComponent) + Double(nb.redComponent - na.redComponent) * cl,
                     green: Double(na.greenComponent) + Double(nb.greenComponent - na.greenComponent) * cl,
                     blue: Double(na.blueComponent) + Double(nb.blueComponent - na.blueComponent) * cl)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
