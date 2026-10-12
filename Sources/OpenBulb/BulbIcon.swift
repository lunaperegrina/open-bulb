import AppKit
import SwiftUI
import TuyaLocal

/// Draws the menu bar icon from the lamp state: colored when lit in colour
/// mode, warm white in white mode, dim when off, warning when unreachable.
enum BulbIcon {
    static func image(for bulb: BulbState?, connection: AppState.ConnectionState) -> NSImage {
        let symbolName = "lightbulb.max"
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: "lâmpada")?
            .withSymbolConfiguration(configuration) else {
            return NSImage()
        }

        let tint: NSColor
        var dimmed = false
        switch connection {
        case .unconfigured:
            tint = .systemGray
            dimmed = true
        case .offline:
            tint = .systemRed
            dimmed = true
        case .connecting:
            tint = .systemGray
        case .online:
            guard let bulb, bulb.isOn else {
                tint = .systemGray
                dimmed = true
                break
            }
            if bulb.mode == .colour, bulb.saturation > 0.05 {
                let rgb = BulbModel.hsvToRGB(hue: bulb.hue,
                                             saturation: bulb.saturation,
                                             value: max(bulb.colorValue, 0.55))
                tint = NSColor(red: CGFloat(rgb.0) / 255,
                               green: CGFloat(rgb.1) / 255,
                               blue: CGFloat(rgb.2) / 255, alpha: 1)
            } else {
                // white mode: warm-white, brighter with brightness
                let warmth: CGFloat = bulb.colorTemperature.map { CGFloat(1 - $0) } ?? 0.6
                let level = CGFloat(0.55 + 0.45 * bulb.brightness)
                tint = NSColor(red: level, green: level * (0.98 - 0.08 * warmth),
                               blue: level * (0.92 - 0.35 * warmth), alpha: 1)
            }
        }

        let size = base.size
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        if dimmed {
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        }
        tint.setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }
}
