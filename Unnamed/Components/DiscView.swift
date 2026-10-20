import AppKit
import QuartzCore
import SwiftUI
import UnnamedKit

/// A record/CD showing the track's artwork. Spins while the track plays,
/// easing up to speed when playback starts and coasting to a stop when it
/// pauses, with a light CD sheen that stays put as the disc turns under it.
/// With `scratch`, it can be grabbed and turned by hand, DJ style.
///
/// The disc is drawn once into a picture that Core Animation turns, so a
/// spinning disc costs the app next to nothing. (Turned by SwiftUI, frame by
/// frame, it kept the whole window busy: about a third of a CPU core.)
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
    /// A soft shadow under the disc. (SwiftUI's own can't see into it.)
    var shadow: DiscShadow?

    @State private var turntable = Turntable()
    @State private var face: CGImage?
    @State private var gloss: CGImage?
    @State private var held = false
    @State private var handAngle: Double?
    @State private var handLocation: CGPoint?
    @State private var frameSize: CGSize = .zero
    /// Resets itself if the drag is cancelled, so a held disc can't get stuck.
    @GestureState private var touching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lowPower) private var lowPower
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let side = DiscArt.drawingSide(for: min(frameSize.width, frameSize.height))
        let art = DiscArt.Request(url: artworkURL, seed: seed, side: side, scale: displayScale, dark: colorScheme == .dark)
        DiscLayers(
            turntable: turntable,
            face: face,
            gloss: sheen > 0 ? gloss : nil,
            shadow: shadow,
            speed: spinning && !reduceMotion && !lowPower ? speed : 0
        )
        .aspectRatio(1, contentMode: .fit)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { frameSize = $0 }
        .contentShape(Circle())
        .gesture(grab, including: scratch == nil ? .subviews : .all)
        .onHover { inside in if inside { scratch?.prepare() } }
        .pointerStyle(scratch == nil ? nil : held ? .grabActive : .grabIdle)
        .onChange(of: touching) { _, isTouching in
            if !isTouching { letGo() }
        }
        .task(id: art) {
            guard art.side > 0 else { return }
            // What's at hand first (the artwork if it's decoded, else its
            // gradient), then again once the artwork has loaded.
            let decoded = ArtworkCache.shared.cachedImage(for: art.url, pixelSize: DiscArt.artworkPixels)
            face = DiscArt.face(art, artwork: decoded)
            guard decoded == nil, let url = art.url,
                  let loaded = await ArtworkCache.shared.waitForImage(for: url, pixelSize: DiscArt.artworkPixels),
                  !Task.isCancelled else { return }
            face = DiscArt.face(art, artwork: loaded)
        }
        .task(id: DiscSheen.Key(pixels: Int((side * displayScale).rounded()), strength: sheen)) {
            guard side > 0, sheen > 0 else { return }
            let image = await DiscSheen.image(DiscSheen.Key(pixels: Int((side * displayScale).rounded()), strength: sheen))
            if !Task.isCancelled { gloss = image }
        }
    }

    /// Turning the disc by hand: the change in the pointer's angle around the
    /// spindle turns the record (and the music) by the same amount.
    private var grab: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                let center = CGPoint(x: frameSize.width / 2, y: frameSize.height / 2)
                let spindle = min(frameSize.width, frameSize.height) * 0.08
                func angle(of point: CGPoint) -> Double? {
                    let dx = point.x - center.x, dy = point.y - center.y
                    // Too close to the spindle to tell which way it's turning.
                    guard hypot(dx, dy) > spindle else { return nil }
                    return atan2(dy, dx) * 180 / .pi
                }
                if !held {
                    held = true
                    turntable.grab()
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
                    turntable.turn(by: turn)
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
        turntable.release()
        scratch?.end()
    }
}

/// A shadow under a disc, in SwiftUI's terms (y down).
struct DiscShadow: Equatable {
    var opacity: Double
    var radius: CGFloat
    var y: CGFloat = 0
}

/// What the disc's gestures hold on to: its layer view, once there is one.
@MainActor
final class Turntable {
    fileprivate weak var view: DiscLayerView?

    func grab() { view?.grab() }
    func turn(by degrees: Double) { view?.turn(by: degrees) }
    func release() { view?.release() }
}

private struct DiscLayers: NSViewRepresentable {
    let turntable: Turntable
    let face: CGImage?
    let gloss: CGImage?
    let shadow: DiscShadow?
    /// Degrees per second, 0 to come to a stop.
    let speed: Double

    func makeNSView(context: Context) -> DiscLayerView {
        DiscLayerView()
    }

    func updateNSView(_ view: DiscLayerView, context: Context) {
        turntable.view = view
        view.show(face: face, gloss: gloss)
        view.discShadow = shadow
        view.setSpeed(speed)
    }
}

/// The disc's face, turned by Core Animation, with the sheen held still over
/// it. While it spins at a steady speed the turning is a repeating animation
/// the window server runs by itself; only speeding up, coasting down and
/// being turned by hand take frames from the app.
private final class DiscLayerView: NSView {
    private let rotor = CALayer()
    private let gloss = CALayer()
    private let physics = SpinState()
    /// Where it's heading: degrees per second.
    private var speed = 0.0
    private var held = false
    /// Set while the repeating animation is doing the turning.
    private var steady: (begin: CFTimeInterval, angle: Double, speed: Double)?
    private var link: CADisplayLink?
    private var faceImage: CGImage?
    private var glossImage: CGImage?

    var discShadow: DiscShadow? {
        didSet { if discShadow != oldValue { layoutLayers() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer hosting: these layers are ours, AppKit leaves them alone.
        layer = CALayer()
        wantsLayer = true
        rotor.contentsGravity = .resize
        gloss.contentsGravity = .resize
        // Screen blend, as the shader did: brightens without washing out.
        gloss.compositingFilter = "screenBlendMode"
        layer?.addSublayer(rotor)
        layer?.addSublayer(gloss)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The hand is SwiftUI's to handle.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        if window != nil, needsFrames { startFrames() }
    }

    func show(face: CGImage?, gloss image: CGImage?) {
        if face !== faceImage {
            // A new face cross-fades in (Core Animation's default for contents).
            faceImage = face
            rotor.contents = face
        }
        if image !== glossImage {
            glossImage = image
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gloss.contents = image
            CATransaction.commit()
        }
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = self.bounds
        // Bounds and position rather than frame, which a turned layer doesn't have.
        rotor.bounds = CGRect(origin: .zero, size: bounds.size)
        rotor.position = CGPoint(x: bounds.midX, y: bounds.midY)
        gloss.frame = bounds
        if let shadow = discShadow, let layer, bounds.width > 0 {
            let side = min(bounds.width, bounds.height)
            let disc = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            layer.shadowPath = CGPath(ellipseIn: disc.insetBy(dx: 0.5, dy: 0.5), transform: nil)
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = Float(shadow.opacity)
            layer.shadowRadius = shadow.radius
            layer.shadowOffset = CGSize(width: 0, height: -shadow.y)   // the layer's y points up
        } else {
            layer?.shadowOpacity = 0
            layer?.shadowPath = nil
        }
        CATransaction.commit()
    }

    // MARK: Turning

    func setSpeed(_ newSpeed: Double) {
        guard newSpeed != speed else { return }
        unsettle(at: CACurrentMediaTime())
        speed = newSpeed
        startFrames()
    }

    func grab() {
        unsettle(at: CACurrentMediaTime())
        held = true
        physics.grab()
        startFrames()
    }

    func turn(by degrees: Double) {
        physics.turn(by: degrees)
        show(angle: physics.angle)
    }

    func release() {
        held = false
        physics.release()
        startFrames()
    }

    private var needsFrames: Bool {
        steady == nil && (held || speed != 0 || physics.velocity != 0)
    }

    private func startFrames() {
        guard link == nil, window != nil, needsFrames else { return }
        let link = displayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopFrames() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let angle = physics.angle(at: now, targetSpeed: speed)
        show(angle: angle)
        guard !held else { return }
        if speed != 0 {
            // Up to speed: the window server takes it from here.
            if abs(physics.velocity - speed) <= max(0.1, abs(speed) * 0.004) { settle(at: angle, time: now) }
        } else if abs(physics.velocity) < 0.3 {
            physics.halt()
            stopFrames()
        }
    }

    private func show(angle: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Clockwise on screen (the layer's y points up).
        rotor.transform = CATransform3DMakeRotation(-angle * .pi / 180, 0, 0, 1)
        CATransaction.commit()
    }

    /// Hands a steady spin over to a repeating animation.
    private func settle(at angle: Double, time: CFTimeInterval) {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        let from = -angle * .pi / 180
        spin.fromValue = from
        spin.toValue = from - 2 * .pi * (speed > 0 ? 1 : -1)
        spin.duration = 360 / abs(speed)
        spin.repeatCount = .infinity
        spin.beginTime = rotor.convertTime(time, from: nil)
        rotor.add(spin, forKey: "spin")
        steady = (time, angle, speed)
        stopFrames()
    }

    /// Takes the turning back from the animation, exactly where it had got to.
    private func unsettle(at time: CFTimeInterval) {
        guard let steady else { return }
        self.steady = nil
        let angle = (steady.angle + steady.speed * (time - steady.begin)).truncatingRemainder(dividingBy: 360)
        rotor.removeAnimation(forKey: "spin")
        show(angle: angle)
        physics.resume(angle: angle, velocity: steady.speed, at: time)
    }
}

/// Integrates the disc's angle, easing its speed toward a target, so it spins
/// up quickly and coasts down a little more slowly, like a real platter.
final class SpinState {
    private(set) var angle: Double = 0
    private(set) var velocity: Double = 0
    private var last: CFTimeInterval?
    private var held = false

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

    /// Picks up from where something else left the disc.
    func resume(angle: Double, velocity: Double, at time: CFTimeInterval) {
        self.angle = angle
        self.velocity = velocity
        last = time
    }

    func angle(at time: CFTimeInterval, targetSpeed: Double) -> Double {
        // Clamp the step, so resuming after a long pause doesn't jump.
        let step = last.map { min(0.1, max(0, time - $0)) } ?? 0
        last = time
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

/// Disc faces drawn into pictures. The same few discs show in several places
/// at once, so they're cached.
@MainActor
enum DiscArt {
    struct Request: Hashable {
        var url: URL?
        var seed: UUID
        var side: CGFloat
        var scale: CGFloat
        /// The spindle hole shows the window's background, light or dark.
        var dark: Bool
    }

    static let artworkPixels = 400

    /// The size a disc is drawn at: the next of a few steps up from its own,
    /// so a disc being zoomed (on a moodboard) isn't drawn again every frame.
    static func drawingSide(for side: CGFloat) -> CGFloat {
        guard side >= 1 else { return 0 }
        let steps: [CGFloat] = [16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512]
        return steps.first { $0 >= side } ?? (side / 128).rounded(.up) * 128
    }

    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 64 << 20   // bytes
        return cache
    }()

    static func face(_ request: Request, artwork: NSImage?) -> CGImage? {
        let key = "\(request.url?.path ?? "-")|\(request.seed)|\(request.side)|\(request.scale)|\(request.dark)|\(artwork != nil)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var hole = Color.gray
        NSAppearance(named: request.dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            hole = Color(nsColor: NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor)
        }
        let renderer = ImageRenderer(content: DiscFace(artwork: artwork, seed: request.seed, size: request.side, hole: hole))
        renderer.scale = request.scale
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

/// The face of a disc: its artwork with grooves, a hub and a hole.
private struct DiscFace: View {
    let artwork: NSImage?
    let seed: UUID
    let size: CGFloat
    let hole: Color

    var body: some View {
        ZStack {
            GradientArtwork(seed: seed)
                .overlay {
                    if let artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(Circle())
            // Faint grooves so it reads as a disc (the sheen is drawn over it).
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
                .fill(hole)
                .frame(width: size * 0.07, height: size * 0.07)
        }
        .frame(width: size, height: size)
    }
}

/// The CD's rainbow sheen: the light of `cdSheen` in CDShader.metal, worked
/// out once into a picture that sits still over the turning disc.
enum DiscSheen {
    nonisolated struct Key: Hashable, Sendable {
        var pixels: Int
        var strength: Double
    }

    @MainActor private static var images: [Key: CGImage] = [:]
    @MainActor private static var pending: [Key: Task<CGImage?, Never>] = [:]

    @MainActor
    static func image(_ key: Key) async -> CGImage? {
        guard key.pixels > 0 else { return nil }
        if let image = images[key] { return image }
        let task = pending[key] ?? Task.detached(priority: .userInitiated) { render(key) }
        pending[key] = task
        let image = await task.value
        pending[key] = nil
        images[key] = image
        return image
    }

    /// Premultiplied RGBA. The colour is what the shader added; the alpha is
    /// its brightest channel, so even blended normally it looks about right.
    nonisolated static func render(_ key: Key) -> CGImage? {
        let n = key.pixels
        let strength = Float(key.strength)
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let size = Float(n)
        let radius = size / 2
        let lightX = size * 1.8, lightY = -size * 0.8
        for row in 0..<n {
            for column in 0..<n {
                // y down, as in the shader.
                let x = Float(column) + 0.5, y = Float(row) + 0.5
                let px = x - radius, py = y - radius
                let r = (px * px + py * py).squareRoot()
                let rn = r / radius
                guard rn > 0.24, rn < 0.99 else { continue }
                let radialX = px / max(r, 1e-4), radialY = py / max(r, 1e-4)
                let tangentX = -radialY, tangentY = radialX

                var lx = lightX - x, ly = lightY - y, lz = radius * 1.1
                let ll = (lx * lx + ly * ly + lz * lz).squareRoot()
                lx /= ll; ly /= ll; lz /= ll
                var hx = lx, hy = ly, hz = lz + 1
                let hl = (hx * hx + hy * hy + hz * hz).squareRoot()
                hx /= hl; hy /= hl; hz /= hl

                let u = abs(hx * radialX + hy * radialY)
                var red: Float = 0, green: Float = 0, blue: Float = 0
                for order in 1...3 {
                    let wavelength = 1600 * u / Float(order)
                    let visible = smoothstep(380, 430, wavelength) * (1 - smoothstep(660, 720, wavelength))
                    guard visible > 0 else { continue }
                    let (sr, sg, sb) = spectral(wavelength)
                    let weight = visible / Float(order)
                    red += sr * weight
                    green += sg * weight
                    blue += sb * weight
                }
                let alongGrooves = hx * tangentX + hy * tangentY
                let band = exp(-alongGrooves * alongGrooves * 22)
                let data = smoothstep(0.24, 0.32, rn) * (1 - smoothstep(0.93, 0.99, rn))
                let glint = pow(min(1, max(0, hz)), 50) * 0.35
                let scale = data * strength
                let addR = saturate((red * band + glint) * scale)
                let addG = saturate((green * band + glint) * scale)
                let addB = saturate((blue * band + glint) * scale)
                let alpha = max(addR, addG, addB)
                guard alpha > 0 else { continue }
                let index = (row * n + column) * 4
                pixels[index] = UInt8((addR * 255).rounded())
                pixels[index + 1] = UInt8((addG * 255).rounded())
                pixels[index + 2] = UInt8((addB * 255).rounded())
                pixels[index + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private nonisolated static func saturate(_ x: Float) -> Float { min(1, max(0, x)) }

    private nonisolated static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = saturate((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    /// Alan Zucconi's six-bump approximation of the visible spectrum.
    private nonisolated static func spectral(_ wavelength: Float) -> (Float, Float, Float) {
        let x = saturate((wavelength - 400) / 300)
        func bump(_ c: Float, _ x0: Float, _ y0: Float) -> Float {
            let v = c * (x - x0)
            return saturate(1 - v * v - y0)
        }
        return (
            bump(3.54585104, 0.69549072, 0.02312639) + bump(3.90307140, 0.11748627, 0.84897130),
            bump(2.93225262, 0.49228336, 0.15225084) + bump(3.21182957, 0.86755042, 0.88445281),
            bump(2.41593945, 0.27699880, 0.52607955) + bump(3.96587128, 0.66077860, 0.73949448)
        )
    }
}
