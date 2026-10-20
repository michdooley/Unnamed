import AppKit
import SwiftUI

/// The little waveform beside whatever's playing, with a band of light
/// sweeping across it. The sweep is a Core Animation animation the window
/// server runs by itself, so it costs the app nothing. (SwiftUI's symbol
/// effect redrew the whole window every frame, a quarter of a CPU core for a
/// tiny icon; even AppKit's redraws the symbol every frame.) Holds still in
/// Low Power Mode.
struct NowPlayingIndicator: NSViewRepresentable {
    var animating: Bool
    var pointSize: CGFloat
    var symbol = "waveform"

    func makeNSView(context: Context) -> IndicatorView {
        IndicatorView()
    }

    func updateNSView(_ view: IndicatorView, context: Context) {
        let environment = context.environment
        view.configure(
            symbol: symbol,
            pointSize: pointSize,
            dark: environment.colorScheme == .dark,
            animating: animating && !environment.lowPower && !environment.accessibilityReduceMotion
        )
    }

    final class IndicatorView: NSView {
        /// The symbol's shape, holding the dim glyph and the moving light.
        private let glyph = CALayer()
        private let shape = CALayer()
        private let dim = CALayer()
        private let light = CAGradientLayer()
        private var configured: (symbol: String, pointSize: CGFloat, dark: Bool)?
        private var animating = false
        private var glyphSize: CGSize = .zero

        init() {
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            shape.contentsGravity = .resizeAspect
            glyph.mask = shape
            glyph.addSublayer(dim)
            glyph.addSublayer(light)
            light.startPoint = CGPoint(x: 0, y: 0.5)
            light.endPoint = CGPoint(x: 1, y: 0.5)
            light.locations = [0, 0.3, 0.7, 1]
            light.isHidden = true
            layer?.addSublayer(glyph)
            setContentHuggingPriority(.required, for: .horizontal)
            setContentHuggingPriority(.required, for: .vertical)
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityLabel("Playing")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var intrinsicContentSize: NSSize { glyphSize }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            placeLayers()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            shape.contentsScale = window?.backingScaleFactor ?? 2
        }

        func configure(symbol: String, pointSize: CGFloat, dark: Bool, animating: Bool) {
            if configured?.symbol != symbol || configured?.pointSize != pointSize || configured?.dark != dark {
                configured = (symbol, pointSize, dark)
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
                glyphSize = image?.size ?? .zero
                var ink = CGColor.black
                NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    ink = NSColor.labelColor.cgColor
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                shape.contents = image
                shape.contentsScale = window?.backingScaleFactor ?? 2
                dim.backgroundColor = ink
                let clear = ink.copy(alpha: 0) ?? ink
                light.colors = [clear, ink, ink, clear]
                CATransaction.commit()
                invalidateIntrinsicContentSize()
                placeLayers()
            }
            guard animating != self.animating else { return }
            self.animating = animating
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Playing: a dim waveform with the light running along it.
            dim.opacity = animating ? 0.28 : 1
            light.isHidden = !animating
            CATransaction.commit()
            if animating { startSweep() } else { light.removeAnimation(forKey: "sweep") }
        }

        private func placeLayers() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glyph.frame = CGRect(x: (bounds.width - glyphSize.width) / 2, y: (bounds.height - glyphSize.height) / 2,
                                 width: glyphSize.width, height: glyphSize.height)
            shape.frame = glyph.bounds
            dim.frame = glyph.bounds
            light.bounds = CGRect(x: 0, y: 0, width: glyphSize.width * 0.9, height: glyphSize.height)
            light.position = CGPoint(x: -glyphSize.width, y: glyphSize.height / 2)
            CATransaction.commit()
            if animating { startSweep() }
        }

        private func startSweep() {
            let width = glyphSize.width
            guard width > 0 else { return }
            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.fromValue = -width * 0.45
            sweep.toValue = width * 1.45
            sweep.duration = 1.1
            sweep.repeatCount = .infinity
            light.add(sweep, forKey: "sweep")
        }
    }
}
