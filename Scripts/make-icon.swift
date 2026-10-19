// Renders the app icon to a 1024×1024 PNG.
// Usage: swift Scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let full = CGRect(x: 0, y: 0, width: size, height: size)

// Full-bleed background; macOS applies the rounded mask.
let background = CGGradient(colorsSpace: space, colors: [color(0x241A4F), color(0x6A2BE6), color(0xFF4FA3)] as CFArray,
                            locations: [0, 0.55, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0), options: [])

// Soft glow behind the disc.
let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
let center = CGPoint(x: CGFloat(size) * 0.5, y: CGFloat(size) * 0.5)
ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(size) * 0.48, options: [])

// The disc.
let discRadius = CGFloat(size) * 0.34
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: color(0x000000, 0.35))
ctx.setFillColor(color(0x15121F))
ctx.fillEllipse(in: CGRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2, height: discRadius * 2))
ctx.restoreGState()

// Grooves.
ctx.setLineWidth(3)
for i in 0..<9 {
    let r = discRadius * (0.52 + CGFloat(i) * 0.052)
    ctx.setStrokeColor(color(0xFFFFFF, 0.05 + (i % 2 == 0 ? 0.03 : 0)))
    ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
}

// Sheen.
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2, height: discRadius * 2))
ctx.clip()
let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0), color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray,
                       locations: [0.3, 0.5, 0.7])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: center.x - discRadius, y: center.y + discRadius),
                       end: CGPoint(x: center.x + discRadius, y: center.y - discRadius), options: [])
ctx.restoreGState()

// Label.
let labelRadius = discRadius * 0.42
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - labelRadius, y: center.y - labelRadius, width: labelRadius * 2, height: labelRadius * 2))
ctx.clip()
let label = CGGradient(colorsSpace: space, colors: [color(0xFFD60A), color(0xFF4FA3)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(label, start: CGPoint(x: center.x - labelRadius, y: center.y + labelRadius),
                       end: CGPoint(x: center.x + labelRadius, y: center.y - labelRadius), options: [])
ctx.restoreGState()

// Waveform bars across the label.
let bars: [CGFloat] = [0.25, 0.5, 0.8, 0.45, 1.0, 0.6, 0.85, 0.35, 0.55]
let barWidth = labelRadius * 0.1
let gap = labelRadius * 0.06
let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
ctx.setFillColor(color(0x15121F, 0.85))
for (i, level) in bars.enumerated() {
    let h = labelRadius * 1.1 * level
    let x = center.x - totalWidth / 2 + CGFloat(i) * (barWidth + gap)
    let rect = CGRect(x: x, y: center.y - h / 2, width: barWidth, height: h)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
}
ctx.fillPath()

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
_ = full
