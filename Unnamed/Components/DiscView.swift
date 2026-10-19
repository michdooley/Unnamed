import SwiftUI
import UnnamedKit

/// A record/CD showing the track's artwork. Spins while the track plays,
/// easing up to speed when playback starts and coasting to a stop when it
/// pauses, with a light CD sheen that stays put as the disc turns under it.
/// With `scratch`, it can be grabbed and turned by hand, DJ style.
struct DiscView: View {
    let artworkURL: URL?
    let seed: UUID
    var spinning = false
    /// Degrees per second at full speed.
    var speed: Double = 40
    /// How strong the CD sheen is (0 turns it off).
    var sheen: Double = 0.35
    var scratch: DiscScratch?
    /// Only an edge of the disc shows (the record behind a cover): pulling
    /// across that edge turns it too, right being forwards.
    var grabbedByEdge = false

    @State private var spin = SpinState()
    /// Keeps frames coming while the disc coasts to a stop.
    @State private var coasting = false
    @State private var held = false
    @State private var handAngle: Double?
    @State private var handLocation: CGPoint?
    @State private var frameSize: CGSize = .zero
    /// Resets itself if the drag is cancelled, so a held disc can't get stuck.
    @GestureState private var touching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moving = held || (!reduceMotion && (spinning || coasting))
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !moving)) { context in
            let angle = spin.angle(at: context.date, targetSpeed: spinning && !reduceMotion ? speed : 0)
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                disc
                    .rotationEffect(.degrees(angle))
                    .frame(width: size, height: size)
                    // Applied after the rotation, so the rainbow band holds still.
                    .colorEffect(ShaderLibrary.cdSheen(
                        .float2(Float(size), Float(size)),
                        .float2(Float(size * 1.8), Float(-size * 0.8)),
                        .float(Float(sheen))
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { frameSize = $0 }
        .contentShape(Circle())
        .gesture(grab, including: scratch == nil ? .subviews : .all)
        .onHover { inside in if inside { scratch?.prepare() } }
        .pointerStyle(scratch == nil ? nil : held ? .grabActive : .grabIdle)
        .onChange(of: touching) { _, isTouching in
            if !isTouching { letGo() }
        }
        // Restarted whenever playback starts or stops, so an earlier pause
        // can't cut a later coast short.
        .task(id: spinning) {
            guard !spinning, spin.isMoving else { return }
            coasting = true
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            coasting = false
            spin.halt()
        }
    }

    /// Turning the disc by hand: the change in the pointer's angle around the
    /// spindle turns the record (and the music) by the same amount.
    private var grab: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                let center = CGPoint(x: frameSize.width / 2, y: frameSize.height / 2)
                func angle(of point: CGPoint) -> Double? {
                    let dx = point.x - center.x, dy = point.y - center.y
                    // Too close to the spindle to tell which way it's turning.
                    guard hypot(dx, dy) > min(frameSize.width, frameSize.height) * 0.08 else { return nil }
                    return atan2(dy, dx) * 180 / .pi
                }
                if !held {
                    held = true
                    spin.grab()
                    scratch?.begin()
                    handAngle = angle(of: value.startLocation)
                    handLocation = value.startLocation
                }
                guard let now = angle(of: value.location) else { return }
                if let before = handAngle {
                    var turn = now - before
                    if turn > 180 { turn -= 360 } else if turn < -180 { turn += 360 }
                    if grabbedByEdge, let from = handLocation {
                        // Movement straight out from the spindle doesn't turn a
                        // record, but across a sliver of edge it's the natural
                        // scratch, so count it, outwards on the right being forwards.
                        let rx = value.location.x - center.x, ry = value.location.y - center.y
                        let radius = max(1, hypot(rx, ry))
                        let outward = ((value.location.x - from.x) * rx + (value.location.y - from.y) * ry) / radius
                        turn += outward * (rx >= 0 ? 1 : -1) / radius * 180 / .pi
                    }
                    spin.turn(by: turn)
                    scratch?.turn(turn)
                }
                handAngle = now
                handLocation = value.location
            }
            .onEnded { _ in letGo() }
    }

    private func letGo() {
        guard held else { return }
        held = false
        handAngle = nil
        handLocation = nil
        spin.release()
        scratch?.end()
    }

    private var disc: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                ArtworkView(url: artworkURL, seed: seed, cornerRadius: size / 2, pixelSize: 400)
                // Faint grooves so it reads as a disc (the sheen is the shader's).
                ForEach(1..<5) { ring in
                    Circle()
                        .stroke(.white.opacity(0.07), lineWidth: max(0.5, size / 200))
                        .padding(size * (0.08 + CGFloat(ring) * 0.06))
                }
                Circle()
                    .fill(.white.opacity(0.9))
                    .frame(width: size * 0.2, height: size * 0.2)
                Circle()
                    .stroke(.black.opacity(0.12), lineWidth: max(0.5, size / 160))
                    .frame(width: size * 0.2, height: size * 0.2)
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: size * 0.07, height: size * 0.07)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Integrates the disc's angle, easing its speed toward a target, so it spins
/// up quickly and coasts down a little more slowly, like a real platter.
final class SpinState {
    private var angle: Double = 0
    private var velocity: Double = 0
    private var last: Date?
    private var held = false

    var isMoving: Bool { velocity != 0 }

    /// A hand on the record brakes it to a stop (as quickly as the music does).
    private var braking = 0.0

    func grab() {
        held = true
        braking = abs(velocity) / PlayerController.scratchBrakeTime
    }

    /// The hand turning it takes over from the brake.
    func turn(by degrees: Double) {
        velocity = 0
        braking = 0
        angle = (angle + degrees).truncatingRemainder(dividingBy: 360)
    }

    /// Let go: the motor brings it back up to speed from a standstill.
    func release() {
        held = false
        last = nil
    }

    /// Stops dead (after a coast has run its course).
    func halt() {
        velocity = 0
        last = nil
    }

    func angle(at date: Date, targetSpeed: Double) -> Double {
        // Clamp the step, so resuming after a long pause doesn't jump.
        let step = last.map { min(0.1, max(0, date.timeIntervalSince($0))) } ?? 0
        last = date
        if held {
            velocity = velocity > 0 ? max(0, velocity - braking * step) : min(0, velocity + braking * step)
            angle = (angle + velocity * step).truncatingRemainder(dividingBy: 360)
            return angle
        }
        let easing = targetSpeed > velocity ? 0.35 : 0.6
        velocity += (targetSpeed - velocity) * (1 - exp(-step / easing))
        if abs(velocity) < 0.01, targetSpeed == 0 { velocity = 0 }
        angle = (angle + velocity * step).truncatingRemainder(dividingBy: 360)
        return angle
    }
}

/// What turning a disc by hand does (see `PlayerController` scratching).
struct DiscScratch {
    var prepare: () -> Void
    var begin: () -> Void
    /// Degrees turned since the last call; clockwise is forwards.
    var turn: (Double) -> Void
    var end: () -> Void

    /// Scratches whatever's playing. One turn is 1.8 s, like a 33⅓ record;
    /// a big disc can play more per turn, so a hand movement does about as
    /// much as on a small one.
    static func record(_ player: PlayerController, secondsPerTurn: Double = PlayerController.secondsPerTurn) -> DiscScratch {
        DiscScratch(
            prepare: { player.prepareScratch() },
            begin: { player.beginScratch() },
            turn: { player.scratch(by: $0 / 360 * secondsPerTurn) },
            end: { player.endScratch() }
        )
    }
}
