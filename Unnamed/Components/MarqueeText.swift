import AppKit
import SwiftUI

/// Single-line text that slowly scrolls back and forth when it doesn't fit.
/// The scrolling is a Core Animation animation of a picture of the text, run
/// by the window server, so a long title costs nothing while it scrolls.
/// (Moved by SwiftUI, it redrew the window 30 times a second, for as long as
/// the title was showing.) In Low Power Mode a long title stays put.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    /// The text's colour while it scrolls (otherwise it's the usual foreground style).
    var color: Color = .primary
    /// Points per second.
    var speed: Double = 28
    var pause: Double = 1.8

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var picture: TextPicture?
    @Environment(\.self) private var environment
    @Environment(\.lowPower) private var lowPower
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let overflow = max(0, textWidth - boxWidth)
        let request = TextPicture.Request(text: text, font: font, color: color.resolve(in: environment), scale: environment.displayScale)
        // Takes the room it's offered; the text inside may run past it.
        Color.clear
            .overlay(alignment: .leading) {
                ZStack(alignment: .leading) {
                    // Measures the text, and shows it when it fits.
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                        .opacity(overflow > 0 && picture?.request == request ? 0 : 1)
                    if overflow > 0, let picture, picture.request == request {
                        MarqueeStrip(picture: picture, overflow: overflow, speed: speed, pause: pause, moving: !lowPower && !reduceMotion)
                            .frame(width: boxWidth)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .clipped()
        .task(id: overflow > 0 ? request : nil) {
            guard overflow > 0, picture?.request != request else { return }
            picture = TextPicture(request)
        }
    }
}

/// A line of text drawn into a picture.
private struct TextPicture {
    struct Request: Hashable {
        var text: String
        var font: Font
        var color: Color.Resolved
        var scale: CGFloat
    }

    let request: Request
    let image: CGImage
    /// In points.
    let size: CGSize

    @MainActor
    init?(_ request: Request) {
        let renderer = ImageRenderer(content: Text(request.text)
            .font(request.font)
            .foregroundStyle(Color(request.color))
            .lineLimit(1)
            .fixedSize())
        renderer.scale = request.scale
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        self.request = request
        self.image = image
        size = CGSize(width: CGFloat(image.width) / request.scale, height: CGFloat(image.height) / request.scale)
    }
}

/// The picture of the text, sliding to and fro with pauses at either end,
/// faded at the edges.
private struct MarqueeStrip: NSViewRepresentable {
    let picture: TextPicture
    let overflow: CGFloat
    let speed: Double
    let pause: Double
    let moving: Bool

    func makeNSView(context: Context) -> StripView {
        StripView()
    }

    func updateNSView(_ view: StripView, context: Context) {
        view.show(picture.image, size: picture.size, overflow: overflow, speed: speed, pause: pause, moving: moving)
    }

    final class StripView: NSView {
        private let strip = CALayer()
        private let fade = CAGradientLayer()
        private var shown: (image: CGImage, overflow: CGFloat, moving: Bool)?
        private var timing: (speed: Double, pause: Double) = (28, 1.8)

        init() {
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            layer?.masksToBounds = true
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            fade.colors = [CGColor.clear, CGColor.black, CGColor.black, CGColor.clear]
            fade.locations = [0, 0.06, 0.94, 1]
            layer?.mask = fade
            strip.anchorPoint = CGPoint(x: 0, y: 0.5)
            strip.contentsGravity = .resize
            layer?.addSublayer(strip)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            place()
        }

        func show(_ image: CGImage, size: CGSize, overflow: CGFloat, speed: Double, pause: Double, moving: Bool) {
            timing = (speed, pause)
            guard shown?.image !== image || shown?.overflow != overflow || shown?.moving != moving else { return }
            let restart = shown?.image !== image || shown?.moving != moving
            shown = (image, overflow, moving)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            strip.contents = image
            strip.bounds = CGRect(origin: .zero, size: size)
            CATransaction.commit()
            place()
            if restart || strip.animation(forKey: "marquee") == nil { slide() }
        }

        private func place() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fade.frame = bounds
            strip.position = CGPoint(x: 0, y: bounds.midY)
            CATransaction.commit()
        }

        /// Rests at the start, slides to the end, rests, slides back, forever.
        private func slide() {
            strip.removeAnimation(forKey: "marquee")
            guard let shown, shown.moving, shown.overflow > 0, timing.speed > 0 else { return }
            let travel = Double(shown.overflow) / timing.speed
            let cycle = 2 * (timing.pause + travel)
            let slide = CAKeyframeAnimation(keyPath: "position.x")
            slide.values = [0, 0, -shown.overflow, -shown.overflow, 0]
            slide.keyTimes = [0, timing.pause / cycle, (timing.pause + travel) / cycle, (2 * timing.pause + travel) / cycle, 1].map { NSNumber(value: $0) }
            slide.duration = cycle
            slide.repeatCount = .infinity
            strip.add(slide, forKey: "marquee")
        }
    }
}
