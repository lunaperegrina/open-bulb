import SwiftUI
import TuyaLocal

/// HSL-style color wheel: angle = hue, distance from center = saturation.
/// A vertical brightness mini-slider sits on the right.
struct ColorWheelView: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    @Binding var value: Double
    /// When false (lamp off) glows are suppressed and the control dims.
    var lit = true

    @State private var isDragging = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let radius = side / 2

                ZStack {
                    ColorWheelImage(side: side)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                        .shadow(color: currentColor.opacity(lit ? 0.4 : 0), radius: 14)
                        .opacity(lit ? 1 : 0.55)
                    // knob
                    let knobPos = knobCenter(center: center, radius: radius)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 24, height: 24)
                        .shadow(color: currentColor.opacity(lit ? 0.55 : 0), radius: 5)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
                        .overlay(
                            Circle()
                                .fill(currentColor)
                                .frame(width: 15, height: 15)
                        )
                        .position(knobPos)
                        .animation(.easeOut(duration: 0.12), value: saturation)
                        .animation(.easeOut(duration: 0.12), value: hue)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            isDragging = true
                            apply(location: g.location, center: center, radius: radius)
                        }
                        .onEnded { _ in isDragging = false }
                )
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Roda de cores")
            .accessibilityValue(ColorNames.name(hue: hue))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: hue = (hue + 15).truncatingRemainder(dividingBy: 360)
                case .decrement: hue = (hue - 15 + 360).truncatingRemainder(dividingBy: 360)
                @unknown default: break
                }
            }

            // brightness of the colour
            VStack(spacing: 8) {
                Image(systemName: "sun.max")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        Capsule()
                            .fill(LinearGradient(
                                stops: [
                                    .init(color: Color.black.opacity(0.45), location: 0),
                                    .init(color: currentColor, location: 1),
                                ],
                                startPoint: .bottom, endPoint: .top))
                            .frame(width: 14)
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                            .offset(x: -2)
                        Circle()
                            .fill(Color.white)
                            .shadow(color: currentColor.opacity(lit ? 0.5 : 0), radius: 4)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
                            .frame(width: 16, height: 16)
                            .position(x: 5, y: (1 - value) * geo.size.height)
                            .animation(.easeOut(duration: 0.12), value: value)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { g in
                            value = min(max(1 - g.location.y / geo.size.height, 0), 1)
                        }
                    )
                }
                .frame(width: 20)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Intensidade da cor")
                .accessibilityValue("\(Int(round(value * 100))) por cento")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: value = min(value + 0.05, 1)
                    case .decrement: value = max(value - 0.05, 0)
                    @unknown default: break
                    }
                }
                Text("\(Int(round(value * 100)))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var currentColor: Color {
        let rgb = BulbModel.hsvToRGB(hue: hue, saturation: max(saturation, 0.05),
                                     value: max(value, 0.4))
        return Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255)
    }

    private func knobCenter(center: CGPoint, radius: Double) -> CGPoint {
        let r = radius * 0.85 * min(saturation, 1)
        let angle = (hue - 90) * .pi / 180
        return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
    }

    private func apply(location: CGPoint, center: CGPoint, radius: Double) {
        let dx = Double(location.x - center.x)
        let dy = Double(location.y - center.y)
        var angle = atan2(dy, dx) * 180 / .pi + 90
        if angle < 0 { angle += 360 }
        hue = angle
        let dist = sqrt(dx * dx + dy * dy) / (radius * 0.85)
        saturation = min(max(dist, 0), 1)
    }
}

/// Pre-rendered hue/saturation disc (generated once, cached by side).
struct ColorWheelImage: View {
    var side: CGFloat

    var body: some View {
        Image(nsImage: ColorWheelImageCache.image(side: side))
            .interpolation(.high)
            .resizable()
            .frame(width: side, height: side)
    }
}

enum ColorWheelImageCache {
    private static var cache: [Int: NSImage] = [:]

    static func image(side: CGFloat) -> NSImage {
        let px = Int(side) * 2 // retina
        if let cached = cache[px] { return cached }
        let img = NSImage.makeColorWheel(pixels: px)
        cache[px] = img
        return img
    }
}

extension NSImage {
    static func makeColorWheel(pixels: Int) -> NSImage {
        let size = pixels
        var data = [UInt8](repeating: 0, count: size * size * 4)
        let radius = Double(size) / 2

        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) - radius + 0.5
                let dy = Double(y) - radius + 0.5
                let dist = sqrt(dx * dx + dy * dy) / radius
                let offset = (y * size + x) * 4
                if dist > 1.0 {
                    // transparent outside the disc
                    data[offset + 3] = 0
                    continue
                }
                var angle = atan2(dy, dx) * 180 / .pi + 90
                if angle < 0 { angle += 360 }
                let saturation = min(dist / 0.85, 1)
                let (r, g, b) = BulbModel.hsvToRGB(hue: angle, saturation: saturation, value: 1)
                data[offset] = UInt8(r)
                data[offset + 1] = UInt8(g)
                data[offset + 2] = UInt8(b)
                // soft edge at the rim
                let edge = max(0, min((1.0 - dist) / 0.03, 1))
                data[offset + 3] = UInt8(255 * edge)
            }
        }

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: size * 4, bitsPerPixel: 32)!
        if let bitmap = rep.bitmapData {
            data.withUnsafeBytes { raw in
                memcpy(bitmap, raw.baseAddress!, data.count)
            }
        }
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.addRepresentation(rep)
        return image
    }
}
