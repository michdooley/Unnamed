import ImageIO
import SwiftUI

/// A colour picked from a piece of artwork, for the controls that belong to
/// it (the play button, the playhead): the most vivid colour that's actually
/// there, kept in a range that reads on glass.
struct ArtworkTint: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// Whether a white symbol reads on it (otherwise use a dark one).
    var prefersLightContent: Bool { 0.299 * red + 0.587 * green + 0.114 * blue < 0.62 }

    static func make(url: URL?, seed: UUID) async -> ArtworkTint {
        if let url, let tint = await Task.detached(priority: .utility, operation: { fromImage(at: url) }).value {
            return tint
        }
        // No art: the generated gradient's colours.
        let (start, end) = GradientArtwork.paletteHex(for: seed)
        let a = rgb(start), b = rgb(end)
        return balanced(red: (a.0 + b.0) / 2, green: (a.1 + b.1) / 2, blue: (a.2 + b.2) / 2)
    }

    nonisolated private static func rgb(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    nonisolated private static func fromImage(at url: URL) -> ArtworkTint? {
        let side = 32
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: side,
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        // Weight each pixel by how vivid it is, so a small splash of colour
        // beats a large grey background, with a plain average as a fallback.
        var vivid = (r: 0.0, g: 0.0, b: 0.0, weight: 0.0)
        var plain = (r: 0.0, g: 0.0, b: 0.0)
        for i in 0..<(side * side) {
            let r = Double(pixels[i * 4]) / 255, g = Double(pixels[i * 4 + 1]) / 255, b = Double(pixels[i * 4 + 2]) / 255
            plain.r += r; plain.g += g; plain.b += b
            let high = max(r, g, b), low = min(r, g, b)
            let saturation = high > 0 ? (high - low) / high : 0
            let weight = pow(saturation, 2) * (high < 0.15 ? 0 : 1)
            vivid.r += r * weight; vivid.g += g * weight; vivid.b += b * weight; vivid.weight += weight
        }
        let count = Double(side * side)
        if vivid.weight > count * 0.02 {
            return balanced(red: vivid.r / vivid.weight, green: vivid.g / vivid.weight, blue: vivid.b / vivid.weight)
        }
        return balanced(red: plain.r / count, green: plain.g / count, blue: plain.b / count)
    }

    /// Keeps the colour vivid but not neon, and neither too dark nor washed out.
    nonisolated private static func balanced(red: Double, green: Double, blue: Double) -> ArtworkTint {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let color = NSColor(
            hue: hue,
            saturation: saturation < 0.12 ? saturation : min(0.82, saturation * 1.15),
            brightness: min(0.88, max(0.42, brightness)),
            alpha: 1
        ).usingColorSpace(.sRGB) ?? .gray
        return ArtworkTint(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }
}
