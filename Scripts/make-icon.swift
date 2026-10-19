// Renders the app icon from the real CD shader (Unnamed/Components/CDShader.metal).
// Run via Scripts/make-icon.sh, which compiles the shader first.
//
//   swift Scripts/make-icon.swift <shader.metallib> <output.png> [lightX lightY rotation]
//
// The light is in unit coordinates of the icon (0,0 top-left; far outside the
// icon gives the broad mint band of the welcome screen), and rotation is
// in radians. The disc and backdrop match the welcome screen.
import AppKit
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: make-icon.swift <shader.metallib> <output.png> [lightX lightY rotation]")
    exit(1)
}
let library = ShaderLibrary(url: URL(fileURLWithPath: arguments[1]))
let output = URL(fileURLWithPath: arguments[2])
let numbers = arguments.dropFirst(3).compactMap(Double.init)
let light = numbers.count >= 2 ? CGPoint(x: numbers[0], y: numbers[1]) : CGPoint(x: 1.8, y: -0.8)
let rotation = numbers.count >= 3 ? numbers[2] : 0.4

/// The disc spans 75% of the icon.
let size: CGFloat = 1024
let radius = size * 0.375

func color(_ hex: UInt32) -> Color {
    Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
}

struct Icon: View {
    var body: some View {
        Rectangle()
            // The welcome screen's backdrop (SpinningDiscsView.backdrop).
            .fill(LinearGradient(
                colors: [color(0x0D0B17), color(0x17122A), color(0x0B0A12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .colorEffect(library.cdField(
                .float2(Float(size), Float(size)),
                .float2(Float(light.x * size), Float(light.y * size)),
                .float(0.35),
                .floatArray([Float(size / 2), Float(size / 2), Float(radius), Float(rotation), 0, 0])
            ))
            .frame(width: size, height: size)
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        print("couldn't render the icon")
        exit(1)
    }
    try! png.write(to: output)
    print("Wrote \(output.path)")
}
