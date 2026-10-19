import SwiftUI
import UnnamedKit

/// A song's thread and header as drawn this frame, in view coordinates.
struct RenderedThread: Identifiable {
    let id: UUID
    let trackID: UUID
    /// The thread so far (cut short while it unspools).
    var points: [CGPoint]
    /// From the start of the thread to the bead, when the song is playing.
    var played: [CGPoint]?
    var bead: CGPoint?
    var knots: [CGPoint]
    var showsKnots: Bool
    var isSelected: Bool
    var tint: Color
    var opacity: Double
    /// The level waveform at the head of the thread.
    var wave: CGRect
    var bars: [CGFloat]
    var playedFraction: Double?
    var headerOpacity: Double
}

extension BoardModel {
    /// Screen width of a thread: thin, but never a hairline.
    var threadScreenWidth: CGFloat { max(2.5, min(12, Self.threadWidth * camera.zoom)) }

    /// Screen size of the bead.
    var beadScreenSize: CGFloat { max(14, min(34, Self.beadSize * camera.zoom)) }

    /// Every visible thread, ready to draw.
    func renderThreads(bead: BoardBead?) -> [RenderedThread] {
        let visible = visibleRect
        let revealed = 1 - pow(1 - reveal, 3)
        let ink: Color = isDark ? .white : .black
        return items.compactMap { item -> RenderedThread? in
            guard item.kind == .track, let trackID = item.trackID else { return nil }
            let path = self.path(item)
            let wave = waveRect(item)
            guard path.bounds.insetBy(dx: -Self.beadSize, dy: -Self.beadSize).union(wave).union(cardRect(item)).intersects(visible) else { return nil }
            let unspooled = revealed * unspool(item.id)
            let shown = path.prefix(toLength: path.length * unspooled).map { camera.screen($0, in: size) }

            var played: [CGPoint]?
            var beadPoint: CGPoint?
            var playedFraction: Double?
            if let bead, bead.item.id == item.id {
                playedFraction = bead.fraction
                if bead.fraction <= unspooled + 0.0001 {
                    played = path.prefix(toLength: path.length * bead.fraction).map { camera.screen($0, in: size) }
                    beadPoint = camera.screen(bead.point, in: size)
                }
            }

            let count = max(8, Int(wave.width / 4))
            let peaks = store.peaks(for: trackID)
            let levels = peaks.isEmpty ? [UInt8](repeating: 30, count: count) : peaks.resampled(to: count)
            let bars = levels.map { max(1.2, CGFloat($0) / 255 * Self.waveHeight * camera.zoom) }

            let selected = selection.contains(item.id)
            let emphasis = emphasis(of: item, bead: bead)
            return RenderedThread(
                id: item.id,
                trackID: trackID,
                points: shown,
                played: played,
                bead: beadPoint,
                knots: item.threadKnots.map { camera.screen($0.cgPoint, in: size) },
                showsKnots: selected || hover?.itemID == item.id,
                isSelected: selected,
                tint: self.tint(for: trackID)?.color ?? ink,
                opacity: emphasis,
                wave: camera.screen(wave, in: size),
                bars: bars,
                playedFraction: playedFraction,
                headerOpacity: emphasis * min(1, revealed * 1.4) * min(1, unspool(item.id) * 2)
            )
        }
    }
}

/// A smooth curve through a polyline (quadratic segments between midpoints),
/// so threads stay smooth however far you zoom in.
nonisolated func smoothPath(_ points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    guard points.count > 2 else {
        for p in points.dropFirst() { path.addLine(to: p) }
        return path
    }
    for i in 1..<(points.count - 1) {
        let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
        path.addQuadCurve(to: mid, control: points[i])
    }
    path.addLine(to: points[points.count - 1])
    return path
}

/// Threads as one shape (so Liquid Glass can melt crossings together).
struct ThreadsShape: Shape {
    var lines: [[CGPoint]]
    var width: CGFloat

    func path(in rect: CGRect) -> Path {
        var combined = Path()
        for line in lines where line.count > 1 {
            combined.addPath(smoothPath(line).strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)))
        }
        return combined
    }
}

/// The board itself: its colour, a dot grid that thins out as you zoom out,
/// and a few soft motes drifting at a different depth when you pan.
struct BoardBackdrop: View {
    let camera: BoardCamera
    let background: String

    var body: some View {
        let dark = BoardColor.isDark(background)
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(BoardColor.color(background)))

            // Motes, at a third of the board's depth.
            let depth: CGFloat = 0.35
            let tile: CGFloat = 900
            let shift = CGPoint(x: -camera.center.x * camera.zoom * depth, y: -camera.center.y * camera.zoom * depth)
            let moteColor = (dark ? Color.white : Color.black).opacity(dark ? 0.07 : 0.05)
            var motes = Path()
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func random() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 33) / CGFloat(UInt64(1) << 31)
            }
            var anchors: [(CGPoint, CGFloat)] = []
            for _ in 0..<14 { anchors.append((CGPoint(x: random() * tile, y: random() * tile), 1.5 + random() * 3.5)) }
            let startX = (shift.x.truncatingRemainder(dividingBy: tile) - tile)
            let startY = (shift.y.truncatingRemainder(dividingBy: tile) - tile)
            var ty = startY
            while ty < size.height + tile {
                var tx = startX
                while tx < size.width + tile {
                    for (anchor, radius) in anchors {
                        let center = CGPoint(x: tx + anchor.x, y: ty + anchor.y)
                        guard center.x > -10, center.y > -10, center.x < size.width + 10, center.y < size.height + 10 else { continue }
                        motes.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    }
                    tx += tile
                }
                ty += tile
            }
            context.fill(motes, with: .color(moteColor))

            // The dot grid: every 24 units, then every 96, 384… as dots crowd together.
            var step: CGFloat = 24 * camera.zoom
            while step < 13 { step *= 4 }
            let crowding = min(1, max(0, (step - 13) / 14))
            let origin = camera.screen(CGPoint.zero, in: size)
            let firstX = origin.x.truncatingRemainder(dividingBy: step) - step
            let firstY = origin.y.truncatingRemainder(dividingBy: step) - step
            // Tiny squares read as dots at this size, and are far cheaper than circles.
            let radius: CGFloat = 0.95
            var dots = Path()
            var y = firstY
            while y < size.height + step {
                var x = firstX
                while x < size.width + step {
                    dots.addRect(CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += step
                }
                y += step
            }
            let dotOpacity = (dark ? 0.16 : 0.2) * (0.45 + 0.55 * crowding)
            context.fill(dots, with: .color((dark ? Color.white : Color.black).opacity(dotOpacity)))

            // A soft vignette.
            let shade = Gradient(colors: [.clear, .black.opacity(dark ? 0.32 : 0.08)])
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .radialGradient(shade, center: CGPoint(x: size.width / 2, y: size.height / 2),
                                               startRadius: min(size.width, size.height) * 0.35, endRadius: max(size.width, size.height) * 0.8))
        }
        .allowsHitTesting(false)
    }
}

/// The journey between threads: a dashed line from the end of each song to
/// the start of the next, with a chevron showing the way.
struct ConnectorLayer: View {
    let model: BoardModel

    var body: some View {
        let journey = model.journey
        let ink: Color = model.isDark ? .white : .black
        let reveal = 1 - pow(1 - model.reveal, 3)
        Canvas { context, size in
            guard journey.count > 1, reveal > 0.6 else { return }
            for (a, b) in zip(journey, journey.dropFirst()) {
                let from = model.camera.screen(model.path(a).points.last ?? a.position.cgPoint, in: size)
                let to = model.camera.screen(b.position.cgPoint, in: size)
                let length = hypot(to.x - from.x, to.y - from.y)
                guard length > 24 else { continue }
                let normal = CGVector(dx: -(to.y - from.y) / length, dy: (to.x - from.x) / length)
                let bend = min(120, length * 0.16)
                let control = CGPoint(x: (from.x + to.x) / 2 + normal.dx * bend, y: (from.y + to.y) / 2 + normal.dy * bend)
                var line = Path()
                line.move(to: from)
                line.addQuadCurve(to: to, control: control)
                context.stroke(line, with: .color(ink.opacity(0.22 * (reveal - 0.6) / 0.4)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1.5, 7]))
                // A chevron halfway along.
                let mid = CGPoint(x: 0.25 * from.x + 0.5 * control.x + 0.25 * to.x, y: 0.25 * from.y + 0.5 * control.y + 0.25 * to.y)
                let direction = CGVector(dx: to.x - from.x, dy: to.y - from.y)
                let angle = atan2(direction.dy, direction.dx)
                var chevron = Path()
                chevron.move(to: CGPoint(x: -5, y: -5))
                chevron.addLine(to: .zero)
                chevron.addLine(to: CGPoint(x: -5, y: 5))
                context.stroke(chevron.applying(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: mid.x, y: mid.y))),
                               with: .color(ink.opacity(0.35)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Pen strokes, and the one being drawn.
struct InkLayer: View {
    let model: BoardModel

    var body: some View {
        let drawings = model.items.filter { $0.kind == .drawing && model.rect($0).intersects(model.visibleRect) }
        let stroke = model.stroke
        let camera = model.camera
        let bead = model.bead()
        let pen = model.penColor
        let liveWidth = max(1.5, min(40, 4 / camera.zoom))
        let emphasis = drawings.map { model.emphasis(of: $0, bead: bead) }
        Canvas { context, size in
            func smooth(_ points: [CGPoint]) -> Path {
                var path = Path()
                guard let first = points.first else { return path }
                path.move(to: first)
                if points.count < 3 {
                    for p in points.dropFirst() { path.addLine(to: p) }
                    return path
                }
                for i in 1..<(points.count - 1) {
                    let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                    path.addQuadCurve(to: mid, control: points[i])
                }
                path.addLine(to: points[points.count - 1])
                return path
            }
            for (drawing, opacity) in zip(drawings, emphasis) {
                let points = (drawing.points ?? []).map {
                    camera.screen(CGPoint(x: drawing.position.x + $0.x, y: drawing.position.y + $0.y), in: size)
                }
                context.stroke(smooth(points), with: .color(BoardColor.color(drawing.color ?? "#FFFFFF").opacity(opacity)),
                               style: StrokeStyle(lineWidth: max(1, (drawing.lineWidth ?? 4) * camera.zoom), lineCap: .round, lineJoin: .round))
            }
            if let stroke {
                context.stroke(smooth(stroke.map { camera.screen($0, in: size) }), with: .color(BoardColor.color(pen)),
                               style: StrokeStyle(lineWidth: max(1, liveWidth * camera.zoom), lineCap: .round, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A song card's glass, as a shape on screen.
struct GlassCard: Identifiable {
    let id: UUID
    let outline: Path
    let tint: Color?
}

struct OutlineShape: Shape {
    var outline: Path

    func path(in rect: CGRect) -> Path { outline }
}

/// The Liquid Glass parts: thin glass threads, each tinted with its song's
/// colour, the title cards, and the glass beads travelling along the threads
/// that are playing, all in one container so they melt together where they meet.
struct ThreadGlassLayer: View {
    let threads: [RenderedThread]
    let cards: [GlassCard]
    let width: CGFloat
    let beadSize: CGFloat
    let dark: Bool

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: width * 2) {
                ZStack {
                    ForEach(threads) { thread in
                        Color.clear
                            .glassEffect(.regular.tint(thread.tint.opacity(dark ? 0.3 : 0.22)),
                                         in: ThreadsShape(lines: [Self.coarse(thread.points)], width: width))
                    }
                    ForEach(cards) { card in
                        Color.clear
                            .glassEffect(.regular.tint(card.tint?.opacity(0.4)), in: OutlineShape(outline: card.outline))
                    }
                    ForEach(threads.filter { $0.bead != nil }) { thread in
                        if let bead = thread.bead {
                            Color.clear
                                .glassEffect(.regular.tint(thread.tint.opacity(0.45)),
                                             in: OutlineShape(outline: Path(ellipseIn: CGRect(x: bead.x - beadSize / 2, y: bead.y - beadSize / 2,
                                                                                              width: beadSize, height: beadSize))))
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Every other point is plenty for the glass (it's stroked as a smooth curve).
    static func coarse(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 6 else { return points }
        var kept = stride(from: 0, to: points.count, by: 2).map { points[$0] }
        if kept.last != points.last, let last = points.last { kept.append(last) }
        return kept
    }
}

/// What's drawn on and around the threads: the thread itself (without
/// Liquid Glass), a glint along it, the played stretch in the song's colour,
/// knots, the level waveforms, and the bead's shine.
struct ThreadArtLayer: View {
    let threads: [RenderedThread]
    /// Title cards on screen; threads pass under them.
    let cards: [CGRect]
    let width: CGFloat
    let beadSize: CGFloat
    let background: Color
    let dark: Bool
    let glass: Bool
    let zoom: CGFloat

    var body: some View {
        Canvas { context, size in
            let ink: Color = dark ? .white : .black
            let round = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            let pad = max(2, 5 * zoom)

            // Threads pass under the title cards and waveforms: everything drawn
            // along them is kept out of those areas (the glass thread itself
            // is already beneath the cards' glass).
            var outside = Path(CGRect(origin: .zero, size: size))
            for card in cards {
                outside.addRoundedRect(in: card, cornerSize: CGSize(width: card.height / 2, height: card.height / 2))
            }
            for thread in threads where thread.wave.width > 4 {
                outside.addRoundedRect(in: thread.wave.insetBy(dx: -pad, dy: -pad), cornerSize: CGSize(width: pad * 1.6, height: pad * 1.6))
            }
            context.drawLayer { lines in
                lines.clip(to: outside, style: FillStyle(eoFill: true))
                for thread in threads {
                    let opacity = thread.opacity
                    if thread.points.count > 1 {
                        let line = smoothPath(thread.points)
                        if !glass {
                            // A drawn glass thread: soft shadow, tinted body.
                            lines.stroke(line.offsetBy(dx: 0, dy: 1.5), with: .color(.black.opacity(0.25 * opacity)),
                                         style: StrokeStyle(lineWidth: width + 1.5, lineCap: .round, lineJoin: .round))
                            lines.stroke(line, with: .color(ink.opacity(0.22 * opacity)), style: round)
                            lines.stroke(line, with: .color(thread.tint.opacity(0.35 * opacity)),
                                         style: StrokeStyle(lineWidth: width * 0.55, lineCap: .round, lineJoin: .round))
                        }
                        // A glint along the top of the glass.
                        lines.stroke(line.offsetBy(dx: 0, dy: -width * 0.2), with: .color(.white.opacity((glass ? 0.45 : 0.55) * opacity)),
                                     style: StrokeStyle(lineWidth: max(0.7, width * 0.22), lineCap: .round, lineJoin: .round))
                    }
                    // The played stretch fills with the song's colour.
                    if let played = thread.played, played.count > 1 {
                        let fill = smoothPath(played)
                        lines.stroke(fill, with: .color(thread.tint.opacity(0.18)), style: StrokeStyle(lineWidth: width * 2.2, lineCap: .round, lineJoin: .round))
                        lines.stroke(fill, with: .color(thread.tint.opacity(0.95)), style: StrokeStyle(lineWidth: max(1.2, width * 0.55), lineCap: .round, lineJoin: .round))
                    }
                }
            }

            for thread in threads {
                if thread.showsKnots {
                    for (index, knot) in thread.knots.enumerated() {
                        let r: CGFloat = index == 0 ? 6 : 4.5
                        let dot = Path(ellipseIn: CGRect(x: knot.x - r, y: knot.y - r, width: r * 2, height: r * 2))
                        context.fill(dot, with: .color(dark ? Color(white: 0.1) : .white))
                        context.stroke(dot, with: .color(thread.isSelected ? Color.accentColor : ink.opacity(0.6)), lineWidth: 1.8)
                    }
                }

                // The level waveform at the head of the thread, on a soft plate.
                let wave = thread.wave
                if wave.width > 4, !thread.bars.isEmpty {
                    context.fill(Path(roundedRect: wave.insetBy(dx: -pad, dy: -pad), cornerRadius: pad * 1.6),
                                 with: .color(background.opacity(0.78 * thread.headerOpacity)))
                    let step = wave.width / CGFloat(thread.bars.count)
                    let barWidth = max(1, min(step * 0.55, 4))
                    var played = Path()
                    var unplayed = Path()
                    for (i, height) in thread.bars.enumerated() {
                        let x = wave.minX + (CGFloat(i) + 0.5) * step
                        let bar = CGRect(x: x - barWidth / 2, y: wave.maxY - height, width: barWidth, height: height)
                        if let fraction = thread.playedFraction, (Double(i) + 0.5) / Double(thread.bars.count) <= fraction {
                            played.addRoundedRect(in: bar, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
                        } else {
                            unplayed.addRoundedRect(in: bar, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
                        }
                    }
                    let alpha = thread.headerOpacity
                    context.fill(unplayed, with: .color(ink.opacity((thread.isSelected ? 0.66 : 0.5) * alpha)))
                    context.fill(played, with: .color(thread.tint.opacity(0.95 * alpha)))
                }

                // The bead: a glass marble with a coloured core.
                if let bead = thread.bead {
                    let r = beadSize / 2
                    let ball = Path(ellipseIn: CGRect(x: bead.x - r, y: bead.y - r, width: r * 2, height: r * 2))
                    context.fill(Path(ellipseIn: CGRect(x: bead.x - r * 2.2, y: bead.y - r * 2.2, width: r * 4.4, height: r * 4.4)),
                                 with: .radialGradient(Gradient(colors: [thread.tint.opacity(0.4), thread.tint.opacity(0)]),
                                                       center: bead, startRadius: r * 0.8, endRadius: r * 2.2))
                    if !glass {
                        context.fill(ball, with: .radialGradient(Gradient(colors: [.white.opacity(0.5), ink.opacity(0.12)]),
                                                                 center: CGPoint(x: bead.x - r * 0.3, y: bead.y - r * 0.3), startRadius: 0, endRadius: r * 1.2))
                    }
                    let core = r * 0.48
                    context.fill(Path(ellipseIn: CGRect(x: bead.x - core, y: bead.y - core, width: core * 2, height: core * 2)),
                                 with: .radialGradient(Gradient(colors: [thread.tint, thread.tint.opacity(0.6)]),
                                                       center: CGPoint(x: bead.x - core * 0.3, y: bead.y - core * 0.3), startRadius: 0, endRadius: core * 1.3))
                    context.stroke(ball, with: .color(.white.opacity(0.4)), lineWidth: 1)
                    // Shine on the glass.
                    context.fill(Path(ellipseIn: CGRect(x: bead.x - r * 0.6, y: bead.y - r * 0.68, width: r * 0.62, height: r * 0.4)),
                                 with: .color(.white.opacity(0.9)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Selection outlines, the resize handle, and the selection rectangle.
struct SelectionLayer: View {
    let model: BoardModel

    var body: some View {
        let camera = model.camera
        let selected = model.selection.compactMap { model.item($0) }
        let marquee = model.marquee
        let single = selected.count == 1 ? selected.first : nil
        Canvas { context, size in
            let accent = Color.accentColor
            let toScreen = CGAffineTransform(translationX: -camera.center.x, y: -camera.center.y)
                .concatenating(CGAffineTransform(scaleX: camera.zoom, y: camera.zoom))
                .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
            for item in selected {
                if item.kind == .track {
                    context.stroke(model.cardOutline(item, inset: -3 / camera.zoom).applying(toScreen), with: .color(accent), lineWidth: 1.8)
                } else {
                    let box = camera.screen(model.rect(item), in: size)
                    context.stroke(Path(roundedRect: box.insetBy(dx: -3, dy: -3), cornerRadius: 9), with: .color(accent), lineWidth: 1.8)
                }
            }
            if let single, [.image, .video, .text].contains(single.kind) {
                let box = camera.screen(model.rect(single), in: size)
                let handle = Path(ellipseIn: CGRect(x: box.maxX - 6, y: box.maxY - 6, width: 12, height: 12))
                context.fill(handle, with: .color(.white))
                context.stroke(handle, with: .color(accent), lineWidth: 2)
            }
            if let marquee {
                let box = camera.screen(marquee, in: size)
                context.fill(Path(box), with: .color(accent.opacity(0.08)))
                context.stroke(Path(box), with: .color(accent.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .allowsHitTesting(false)
    }
}
