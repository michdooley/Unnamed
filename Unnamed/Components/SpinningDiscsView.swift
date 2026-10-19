import SwiftUI

/// Slowly spinning CDs drawn by `CDShader.metal`. Their rainbow sheen follows
/// the mouse; with no mouse over them, the light drifts on its own.
struct SpinningDiscsView: View {
    enum Arrangement {
        /// Discs scattered around the edges, leaving the middle clear for text.
        case scattered
        /// One disc in the middle (the launch screen).
        case single
    }

    var arrangement: Arrangement = .scattered
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
                let lightPoint = light.position(at: now, in: size)
                Rectangle()
                    .fill(Self.backdrop)
                    .colorEffect(ShaderLibrary.cdField(
                        .float2(Float(size.width), Float(size.height)),
                        .float2(Float(lightPoint.x), Float(lightPoint.y)),
                        .float(Float(light.hoverAmount(at: now))),
                        .floatArray(discs(in: size, time: time))
                    ))
            }
            .onContinuousHover { phase in
                light.update(phase, in: size)
            }
        }
    }

    static let backdrop = LinearGradient(
        colors: [Color(hex: 0x0D0B17), Color(hex: 0x17122A), Color(hex: 0x0B0A12)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private struct Disc {
        var x, y, radius, speed, phase, kind: Double
    }

    /// Positions are fractions of the view; radii are fractions of its shorter side.
    private var layout: [Disc] {
        switch arrangement {
        case .scattered:
            [
                Disc(x: 0.12, y: 0.24, radius: 0.25, speed: 0.20, phase: 0.0, kind: 0),
                Disc(x: 0.88, y: 0.20, radius: 0.18, speed: -0.28, phase: 1.1, kind: 2),
                Disc(x: 0.87, y: 0.83, radius: 0.28, speed: 0.16, phase: 2.3, kind: 1),
                Disc(x: 0.11, y: 0.86, radius: 0.17, speed: -0.24, phase: 3.0, kind: 0),
                Disc(x: 0.57, y: 1.07, radius: 0.16, speed: 0.32, phase: 4.2, kind: 2),
                Disc(x: 0.38, y: -0.07, radius: 0.13, speed: -0.36, phase: 5.0, kind: 1),
            ]
        case .single:
            [Disc(x: 0.5, y: 0.44, radius: 0.2, speed: 0.5, phase: 0, kind: 0)]
        }
    }

    private func discs(in size: CGSize, time: TimeInterval) -> [Float] {
        let unit = min(size.width, size.height)
        return layout.enumerated().flatMap { index, disc -> [Float] in
            // A gentle float, out of step for each disc.
            let bob = arrangement == .scattered ? sin(time * 0.45 + Double(index) * 1.7) * 6 : 0
            return [
                Float(disc.x * size.width),
                Float(disc.y * size.height + bob),
                Float(disc.radius * unit),
                Float(disc.phase + time * disc.speed),
                Float(disc.kind),
                0,
            ]
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
