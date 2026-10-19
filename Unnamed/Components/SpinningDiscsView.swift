import SwiftUI

/// One disc for `CDShader.metal`: centre and radius in points, rotation in
/// radians, kind 0 silver / 1 gold / 2 blue.
struct ShaderDisc {
    var center: CGPoint
    var radius: CGFloat
    var rotation: Double
    var kind: Double = 0

    var floats: [Float] {
        [Float(center.x), Float(center.y), Float(radius), Float(rotation), Float(kind), 0]
    }
}

extension View {
    /// Draws CDs over this view's pixels (which may be transparent).
    func cdShader(size: CGSize, light: CGPoint, hover: Double, discs: [ShaderDisc]) -> some View {
        colorEffect(ShaderLibrary.cdField(
            .float2(Float(size.width), Float(size.height)),
            .float2(Float(light.x), Float(light.y)),
            .float(Float(hover)),
            .floatArray(discs.flatMap(\.floats))
        ))
    }
}

/// Slowly spinning CDs scattered over the dark backdrop (the welcome screen).
/// Their rainbow sheen follows the mouse; without it, the light drifts.
struct SpinningDiscsView: View {
    /// Shifts the clock; only used to render stills at different moments.
    var timeOffset: TimeInterval = 0

    @State private var light = LightTracker()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
                let now = context.date.addingTimeInterval(timeOffset)
                let time = reduceMotion ? 0 : now.timeIntervalSince(light.start)
                Rectangle()
                    .fill(Self.backdrop)
                    .cdShader(
                        size: size,
                        light: light.position(at: now, in: size),
                        hover: light.hoverAmount(at: now),
                        discs: discs(in: size, time: time)
                    )
            }
            .onContinuousHover { phase in
                light.update(phase, in: size)
            }
        }
    }

    /// The dark navy gradient behind the discs (also the app icon's background).
    static let backdrop = LinearGradient(
        colors: [Color(hex: 0x0D0B17), Color(hex: 0x17122A), Color(hex: 0x0B0A12)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Positions are fractions of the view; radii are fractions of its shorter side.
    private static let layout: [(x: Double, y: Double, radius: Double, speed: Double, phase: Double, kind: Double)] = [
        (0.12, 0.24, 0.25, 0.20, 0.0, 0),
        (0.88, 0.20, 0.18, -0.28, 1.1, 2),
        (0.87, 0.83, 0.28, 0.16, 2.3, 1),
        (0.11, 0.86, 0.17, -0.24, 3.0, 0),
        (0.57, 1.07, 0.16, 0.32, 4.2, 2),
        (0.38, -0.07, 0.13, -0.36, 5.0, 1),
    ]

    private func discs(in size: CGSize, time: TimeInterval) -> [ShaderDisc] {
        let unit = min(size.width, size.height)
        return Self.layout.enumerated().map { index, disc in
            // A gentle float, out of step for each disc.
            let bob = sin(time * 0.45 + Double(index) * 1.7) * 6
            return ShaderDisc(
                center: CGPoint(x: disc.x * size.width, y: disc.y * size.height + bob),
                radius: disc.radius * unit,
                rotation: disc.phase + time * disc.speed,
                kind: disc.kind
            )
        }
    }
}

/// A single CD on a transparent background, centred in its frame.
struct ShaderDiscView: View {
    /// The disc's radius as a fraction of the frame's shorter side.
    var radius: CGFloat = 0.42
    var kind: Double = 0
    /// Radians per second; 0 holds still.
    var speed: Double = 0.5
    var rotation: Double = 0
    /// A fixed light, in unit coordinates of the frame. When nil the light
    /// follows the mouse, drifting on its own when the mouse is elsewhere.
    var fixedLight: UnitPoint?

    @State private var light = LightTracker()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let still = reduceMotion || (speed == 0 && fixedLight != nil)
            TimelineView(.animation(minimumInterval: 1 / 60, paused: still)) { context in
                let now = context.date
                let time = reduceMotion ? 0 : now.timeIntervalSince(light.start)
                let lightPoint = fixedLight.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                    ?? light.position(at: now, in: size)
                // A nearly clear fill, so the shader runs on every pixel.
                Rectangle()
                    .fill(Color.white.opacity(0.0001))
                    .cdShader(
                        size: size,
                        light: lightPoint,
                        hover: fixedLight == nil ? light.hoverAmount(at: now) : 0,
                        discs: [ShaderDisc(
                            center: CGPoint(x: size.width / 2, y: size.height / 2),
                            radius: min(size.width, size.height) * radius,
                            rotation: rotation + time * speed,
                            kind: kind
                        )]
                    )
            }
            .onContinuousHover { phase in
                light.update(phase, in: size)
            }
        }
    }
}

/// Where the light is: chasing the mouse while it's over the view, otherwise
/// drifting in a slow loop. Changes ease out exponentially, so the sheen glides.
final class LightTracker {
    let start = Date()
    private var hovering = false
    private var mouse = CGPoint.zero
    /// Gap between the light and its target when the target last changed.
    private var lag = CGPoint.zero
    private var lagStart = Date()
    private var hoverFrom = 0.0
    private var hoverTo = 0.0
    private var hoverStart = Date()

    func position(at date: Date, in size: CGSize) -> CGPoint {
        let target = target(at: date, in: size)
        let decay = exp(-date.timeIntervalSince(lagStart) * 5)
        return CGPoint(x: target.x + lag.x * decay, y: target.y + lag.y * decay)
    }

    func hoverAmount(at date: Date) -> Double {
        let progress = 1 - exp(-date.timeIntervalSince(hoverStart) * 4)
        return hoverFrom + (hoverTo - hoverFrom) * progress
    }

    func update(_ phase: HoverPhase, in size: CGSize) {
        let now = Date()
        let current = position(at: now, in: size)
        switch phase {
        case .active(let point):
            if !hovering { setHover(1, at: now) }
            hovering = true
            mouse = point
        case .ended:
            if hovering { setHover(0, at: now) }
            hovering = false
        }
        let target = target(at: now, in: size)
        lag = CGPoint(x: current.x - target.x, y: current.y - target.y)
        lagStart = now
    }

    private func target(at date: Date, in size: CGSize) -> CGPoint {
        if hovering { return mouse }
        let t = date.timeIntervalSince(start) * 0.22
        return CGPoint(x: size.width * (0.5 + 0.4 * cos(t)), y: size.height * (0.45 + 0.32 * sin(t * 1.3)))
    }

    private func setHover(_ value: Double, at date: Date) {
        hoverFrom = hoverAmount(at: date)
        hoverTo = value
        hoverStart = date
    }
}
