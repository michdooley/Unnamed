import AppKit
import QuartzCore
import SwiftUI
import UnnamedKit

/// Where the board's view is looking: the board point at the middle of the
/// view, and how far in it's zoomed.
struct BoardCamera: Equatable, Codable {
    var center = CGPoint.zero
    var zoom: CGFloat = 1

    static let zoomRange: ClosedRange<CGFloat> = 0.08...4

    func screen(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - center.x) * zoom + size.width / 2, y: (point.y - center.y) * zoom + size.height / 2)
    }

    func screen(_ rect: CGRect, in size: CGSize) -> CGRect {
        let origin = screen(rect.origin, in: size)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * zoom, height: rect.height * zoom)
    }

    func board(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - size.width / 2) / zoom + center.x, y: (point.y - size.height / 2) / zoom + center.y)
    }

    /// About how far (in points) anything on screen moves going from this
    /// camera to `other`: the pan, plus the zoom's pull at the view's corners.
    func shift(to other: BoardCamera, in size: CGSize) -> CGFloat {
        let pan = hypot(other.center.x - center.x, other.center.y - center.y) * other.zoom
        let zoom = abs(other.zoom - self.zoom) / max(self.zoom, 0.01) * hypot(size.width, size.height) / 2
        return pan + zoom
    }

    /// Moves the view by a distance on screen (the board follows the fingers).
    mutating func pan(by delta: CGSize) {
        center.x -= delta.width / zoom
        center.y -= delta.height / zoom
    }

    /// Zooms keeping the board point under `anchor` (a screen point) in place.
    mutating func zoom(by factor: CGFloat, around anchor: CGPoint, in size: CGSize) {
        let fixed = board(anchor, in: size)
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
        center = CGPoint(x: fixed.x - (anchor.x - size.width / 2) / zoom, y: fixed.y - (anchor.y - size.height / 2) / zoom)
    }

    /// A camera showing `rect` inside the part of the view not covered by `insets`.
    static func fitting(_ rect: CGRect, in size: CGSize, insets: EdgeInsets, maxZoom: CGFloat = 1.2) -> BoardCamera {
        let usable = CGSize(width: max(80, size.width - insets.leading - insets.trailing),
                            height: max(80, size.height - insets.top - insets.bottom))
        let zoom = min(maxZoom, max(zoomRange.lowerBound, min(usable.width / max(rect.width, 1), usable.height / max(rect.height, 1))))
        // The middle of the usable area, as an offset from the middle of the view.
        let offset = CGPoint(x: insets.leading + usable.width / 2 - size.width / 2, y: insets.top + usable.height / 2 - size.height / 2)
        return BoardCamera(center: CGPoint(x: rect.midX - offset.x / zoom, y: rect.midY - offset.y / zoom), zoom: zoom)
    }
}

/// "#RRGGBB" helpers for board colours.
enum BoardColor {
    static func components(_ hex: String) -> (red: Double, green: Double, blue: Double) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0x808080
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func color(_ hex: String) -> Color {
        let c = components(hex)
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }

    static func isDark(_ hex: String) -> Bool {
        let c = components(hex)
        return 0.299 * c.red + 0.587 * c.green + 0.114 * c.blue < 0.55
    }

    static func hex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(ns.redComponent), byte(ns.greenComponent), byte(ns.blueComponent))
    }

    /// Backgrounds to pick from: night, ink, paper, sand, sage, dusk, ocean.
    static let presets = ["#15121F", "#0B0B0D", "#F4F1EA", "#E9DCC7", "#C9D4C0", "#3A2340", "#0F2A36"]
    /// Pen colours.
    static let inks = ["#FFFFFF", "#FFD60A", "#FF6FA8", "#5EE7FF", "#7CF29A", "#111111"]
}

func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

/// Calls `onFrame` on every display refresh while `active`.
struct FrameDriver: NSViewRepresentable {
    var active: Bool
    var pace: Pace = .smooth
    var onFrame: (CFTimeInterval) -> Void

    enum Pace {
        /// 60 fps, while the camera moves.
        case smooth
        /// 30 fps is plenty otherwise.
        case steady
        /// 15 fps, in Low Power Mode.
        case gentle

        var range: CAFrameRateRange {
            switch self {
            case .smooth: CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            case .steady: CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            case .gentle: CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
            }
        }
    }

    final class DriverView: NSView {
        var onFrame: ((CFTimeInterval) -> Void)?
        var wantsFrames = false { didSet { update() } }
        var pace = Pace.smooth {
            didSet {
                guard pace != oldValue else { return }
                link?.preferredFrameRateRange = pace.range
            }
        }
        private var link: CADisplayLink?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            link?.invalidate()
            link = nil
            update()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func update() {
            if wantsFrames, window != nil {
                guard link == nil else { return }
                let link = displayLink(target: self, selector: #selector(tick(_:)))
                // Smooth is plenty; no need for 120 Hz.
                link.preferredFrameRateRange = pace.range
                link.add(to: .main, forMode: .common)
                self.link = link
            } else {
                link?.invalidate()
                link = nil
            }
        }

        @objc private func tick(_ link: CADisplayLink) {
            onFrame?(link.targetTimestamp)
        }
    }

    func makeNSView(context: Context) -> DriverView { DriverView() }

    func updateNSView(_ view: DriverView, context: Context) {
        view.onFrame = onFrame
        view.pace = pace
        view.wantsFrames = active
    }

    static func dismantleNSView(_ view: DriverView, coordinator: ()) {
        view.wantsFrames = false
    }
}

/// Reports a view's frame in its window (AppKit coordinates, origin bottom
/// left), so window events can be matched to it.
struct WindowFrameReader: NSViewRepresentable {
    var onChange: (CGRect, NSWindow?) -> Void

    final class ReaderView: NSView {
        var onChange: ((CGRect, NSWindow?) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            report()
        }

        func report() {
            onChange?(convert(bounds, to: nil), window)
        }
    }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.report()
    }
}

/// The board's own handling of window events SwiftUI doesn't offer:
/// scrolling pans (both directions), ⌘-scroll and pinch zoom around the
/// pointer, the middle mouse button drags the board around, and the
/// keyboard shortcuts (delete, undo, tools…).
@MainActor
final class BoardEventMonitor {
    weak var model: BoardModel?
    /// The board's frame in its window (AppKit coordinates).
    var frameInWindow: CGRect = .zero
    weak var window: NSWindow?
    /// Areas (in board coordinates) that scroll on their own, like the song tray.
    var scrollsOnTheirOwn: [CGRect] = []
    /// Edges of the board covered by other things (sidebar, toolbar, player),
    /// whose events are left alone.
    var passThrough = EdgeInsets()

    private var monitor: Any?
    private var middleDrag: CGPoint?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify, .otherMouseDown, .otherMouseDragged, .otherMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The event's location in board coordinates (origin top left), if it's over the board.
    private func location(of event: NSEvent) -> CGPoint? {
        guard let window, event.window === window, frameInWindow.contains(event.locationInWindow) else { return nil }
        let point = CGPoint(x: event.locationInWindow.x - frameInWindow.minX, y: frameInWindow.maxY - event.locationInWindow.y)
        guard point.x >= passThrough.leading, point.x <= frameInWindow.width - passThrough.trailing,
              point.y >= passThrough.top, point.y <= frameInWindow.height - passThrough.bottom else { return nil }
        return point
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let model else { return event }
        switch event.type {
        case .scrollWheel:
            guard let point = location(of: event), !scrollsOnTheirOwn.contains(where: { $0.contains(point) }) else { return event }
            let precise = event.hasPreciseScrollingDeltas
            var dx = event.scrollingDeltaX * (precise ? 1 : 12)
            var dy = event.scrollingDeltaY * (precise ? 1 : 12)
            if event.modifierFlags.contains(.command) {
                let amount = dy != 0 ? dy : dx
                model.zoom(by: exp(amount * (precise ? 0.01 : 0.004)), around: point)
            } else {
                // A mouse wheel with shift scrolls sideways.
                if !precise, event.modifierFlags.contains(.shift), dx == 0 { swap(&dx, &dy) }
                model.pan(by: CGSize(width: dx, height: dy))
            }
            return nil
        case .magnify:
            guard let point = location(of: event) else { return event }
            model.zoom(by: 1 + event.magnification, around: point)
            return nil
        case .otherMouseDown:
            guard event.buttonNumber == 2, let point = location(of: event) else { return event }
            middleDrag = point
            NSCursor.closedHand.push()
            return nil
        case .otherMouseDragged:
            guard let last = middleDrag else { return event }
            let point = CGPoint(x: event.locationInWindow.x - frameInWindow.minX, y: frameInWindow.maxY - event.locationInWindow.y)
            model.pan(by: CGSize(width: point.x - last.x, height: point.y - last.y))
            middleDrag = point
            return nil
        case .otherMouseUp:
            guard middleDrag != nil else { return event }
            middleDrag = nil
            NSCursor.pop()
            return nil
        case .keyDown:
            guard let window, event.window === window, window.attachedSheet == nil,
                  !(window.firstResponder is NSTextView) else { return event }
            return model.handleKey(event) ? nil : event
        default:
            return event
        }
    }
}
