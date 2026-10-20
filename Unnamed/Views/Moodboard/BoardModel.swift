import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UnnamedKit

/// What's under the pointer on a board.
enum BoardHit: Equatable {
    /// A song's title card.
    case card(UUID)
    /// The disc on a title card, which plays the song.
    case play(UUID)
    /// The song's waveform, and how far along it (0...1).
    case wave(UUID, fraction: Double)
    case knot(UUID, Int)
    /// Somewhere along a thread: how far along (0...1), where a new knot would
    /// go, and the board point on the curve.
    case thread(UUID, fraction: Double, insertIndex: Int, point: CGPoint)
    /// A picture, video, text or drawing.
    case item(UUID)
    /// The resize handle of the selected picture, video or text.
    case resize(UUID)

    var itemID: UUID {
        switch self {
        case .card(let id), .play(let id), .wave(let id, _), .knot(let id, _), .thread(let id, _, _, _), .item(let id), .resize(let id): id
        }
    }
}

/// The playhead as it travels along a thread.
struct BoardBead {
    var item: BoardItem
    var fraction: Double
    var point: CGPoint
    var tangent: CGVector
}

/// A moodboard being looked at and edited: the camera, the tool, the
/// selection, edits in flight, undo, and following the music.
@MainActor
@Observable
final class BoardModel {
    enum Tool: Equatable {
        case select, draw, text
    }

    struct TrayDrag: Equatable {
        var trackID: UUID
        /// In board-view coordinates.
        var location: CGPoint
    }

    /// A camera move, with a gentle pull back in the middle of long trips.
    struct Flight {
        var from: BoardCamera
        var to: BoardCamera
        var start: CFTimeInterval?
        var duration: Double
        var dip: Double

        func camera(at t: Double) -> BoardCamera {
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let zoom = exp(log(from.zoom) + (log(to.zoom) - log(from.zoom)) * eased) * (1 - dip * sin(.pi * t))
            return BoardCamera(
                center: CGPoint(x: from.center.x + (to.center.x - from.center.x) * eased,
                                y: from.center.y + (to.center.y - from.center.y) * eased),
                zoom: zoom
            )
        }
    }

    let collectionID: UUID
    let store: LibraryStore
    let player: PlayerController

    var camera = BoardCamera() {
        didSet {
            liveCamera = camera
            let percent = Int((camera.zoom * 100).rounded())
            if percent != zoomPercent { zoomPercent = percent }
        }
    }
    /// The zoom as shown in the toolbar (changes far less often than the camera).
    var zoomPercent = 100
    var size: CGSize = .zero
    /// The parts of the view under the window's toolbar, the sidebar and the player.
    var insets = EdgeInsets()
    var tool: Tool = .select
    var selection: Set<UUID> = []
    /// Edits in progress (during a drag), drawn instead of the saved items.
    var draft: [UUID: BoardItem] = [:]
    /// The pen stroke being drawn, in board coordinates.
    var stroke: [CGPoint]?
    var marquee: CGRect?
    var hover: BoardHit?
    var editingText: UUID?
    var penColor = BoardColor.inks[1]
    /// The camera rides along with the music.
    var following = false
    var flight: Flight?
    var trayDrag: TrayDrag?
    /// The song tray's frame, in board-view coordinates.
    var trayFrame: CGRect = .zero
    /// Threads unspool when the board opens (0...1).
    var reveal: Double = 0
    /// Pictures and videos still being compressed.
    var addingMedia = 0
    /// The time of the current frame; drives redraws while things move.
    var frameTime: CFTimeInterval = 0
    /// Artwork colours of the songs on the board.
    var tints: [UUID: ArtworkTint] = [:]
    var canUndo = false
    var canRedo = false

    /// Sizes of text items as laid out, in board units (for hit testing).
    @ObservationIgnored var textSizes: [UUID: CGSize] = [:]
    /// Where the pointer last was over the board (view coordinates).
    @ObservationIgnored var hoverPoint: CGPoint?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var paths: [UUID: (knots: [BoardPoint], path: ThreadPath)] = [:]
    private var unspooling: [UUID: CFTimeInterval] = [:]
    @ObservationIgnored private var tintRequests: Set<UUID> = []
    @ObservationIgnored private var gesture: Gesture?
    @ObservationIgnored private var gestureStart: CGPoint = .zero
    /// Where along a song's waveform the press was (to play from there on a double-click).
    @ObservationIgnored private var pressFraction: Double?
    @ObservationIgnored private var lastClick: (time: TimeInterval, point: CGPoint)?
    @ObservationIgnored private var undoStack: [Change] = []
    @ObservationIgnored private var redoStack: [Change] = []
    /// The text item being edited as it was before (`.some(nil)`: a new one).
    @ObservationIgnored private var editingOriginal: BoardItem??
    @ObservationIgnored private var textSave: Task<Void, Never>?
    @ObservationIgnored private var lastBackgroundCheckpoint: Date?
    @ObservationIgnored private var lastFrame: CFTimeInterval?
    /// Where a moving camera really is. `camera`, which everything is drawn
    /// with, only catches up once the difference would show.
    @ObservationIgnored private var liveCamera = BoardCamera()
    /// The playhead as last drawn (its song and place on screen).
    @ObservationIgnored private var drawnBead: (id: UUID, point: CGPoint)?
    /// The playhead as the frame loop last worked it out, and when.
    @ObservationIgnored private var framedBead: (bead: BoardBead?, at: CFTimeInterval)?
    @ObservationIgnored private var followZoom: CGFloat = 1
    @ObservationIgnored private var cameraSave: Task<Void, Never>?
    @ObservationIgnored private var opened = false

    init(collectionID: UUID, store: LibraryStore, player: PlayerController) {
        self.collectionID = collectionID
        self.store = store
        self.player = player
        #if DEBUG
        Self.latest = self
        #endif
    }

    /// The board on screen, if any (so quitting can save text being typed).
    static weak var current: BoardModel?

    #if DEBUG
    /// The board most recently opened (for scripted screenshots).
    @ObservationIgnored nonisolated(unsafe) static weak var latest: BoardModel?
    #endif

    // MARK: - Geometry (board units)

    /// A thin glass thread.
    static let threadWidth: CGFloat = 6
    /// The level waveform at the head of a thread, standing just above it.
    static let waveLift: CGFloat = 10
    static let waveHeight: CGFloat = 34
    static let cardSize = CGSize(width: 260, height: 54)
    /// The glass bead that travels along a thread as it plays.
    static let beadSize: CGFloat = 26

    var board: Moodboard { store.board(for: collectionID) }
    var background: String { board.settings.background }
    var isDark: Bool { BoardColor.isDark(background) }

    /// Everything to draw, back to front: the saved items, with edits in flight
    /// on top. Songs no longer in the collection are left out.
    var items: [BoardItem] {
        var all = board.items
        for (id, item) in draft { all[id] = item }
        let songs = Set(store.collections[collectionID]?.trackIDs ?? [])
        return all.values
            .filter { $0.kind != .track || ($0.trackID.map { songs.contains($0) && store.tracks[$0] != nil } ?? false) }
            .sorted { a, b in
                if a.z != b.z { return a.z < b.z }
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id.uuidString < b.id.uuidString
            }
    }

    func item(_ id: UUID) -> BoardItem? {
        draft[id] ?? board.items[id]
    }

    /// Where a song is on the board (with edits in flight).
    func placement(of trackID: UUID) -> BoardItem? {
        if let edited = draft.values.first(where: { $0.trackID == trackID }) { return edited }
        return board.placement(of: trackID)
    }

    /// The collection's songs in order, and where each one is on the board.
    var songs: [(track: Track, item: BoardItem?)] {
        store.tracks(in: collectionID).map { ($0, placement(of: $0.id)) }
    }

    /// The journey: the songs on the board, in the collection's order.
    var journey: [BoardItem] {
        (store.collections[collectionID]?.trackIDs ?? []).compactMap { placement(of: $0) }
    }

    func path(_ item: BoardItem) -> ThreadPath {
        let knots = item.threadKnots
        if let cached = paths[item.id], cached.knots == knots { return cached.path }
        let path = ThreadPath(knots: knots.map(\.cgPoint))
        paths[item.id] = (knots, path)
        return path
    }

    // A song's header (its title card, and under it the waveform) stays
    // level at the head of its thread, which runs on underneath and then
    // wherever it's pulled.

    /// The waveform, standing on the start of the thread.
    func waveRect(_ item: BoardItem) -> CGRect {
        CGRect(x: item.position.x, y: item.position.y - Self.waveLift - Self.waveHeight,
               width: Self.cardSize.width - 14, height: Self.waveHeight)
    }

    /// The title card, above the waveform.
    func cardRect(_ item: BoardItem) -> CGRect {
        CGRect(x: item.position.x - 8, y: item.position.y - Self.waveLift - Self.waveHeight - 8 - Self.cardSize.height,
               width: Self.cardSize.width, height: Self.cardSize.height)
    }

    /// The title card's outline, as a path on the board.
    func cardOutline(_ item: BoardItem, inset: CGFloat = 0) -> Path {
        let box = cardRect(item).insetBy(dx: inset, dy: inset)
        return Path(roundedRect: box, cornerRadius: box.height / 2)
    }

    func discCenter(_ item: BoardItem) -> CGPoint {
        let card = cardRect(item)
        return CGPoint(x: card.minX + 9 + 18, y: card.midY)
    }

    /// An item's extent on the board.
    func rect(_ item: BoardItem) -> CGRect {
        switch item.kind {
        case .track:
            return path(item).bounds.insetBy(dx: -Self.beadSize, dy: -Self.beadSize).union(cardRect(item)).union(waveRect(item))
        case .image, .video:
            return CGRect(x: item.position.x, y: item.position.y, width: item.width ?? 300, height: item.height ?? 200)
        case .text:
            let measured = textSizes[item.id]
            let width = item.width ?? 360
            return CGRect(x: item.position.x, y: item.position.y, width: width,
                          height: measured.map { Double($0.height) } ?? (item.fontSize ?? 32) * 1.3)
        case .drawing:
            let points = (item.points ?? []).map { CGPoint(x: item.position.x + $0.x, y: item.position.y + $0.y) }
            guard let first = points.first else { return CGRect(x: item.position.x, y: item.position.y, width: 1, height: 1) }
            var box = CGRect(origin: first, size: .zero)
            for p in points { box = box.union(CGRect(origin: p, size: .zero)) }
            let pad = (item.lineWidth ?? 4) / 2 + 2
            return box.insetBy(dx: -pad, dy: -pad)
        }
    }

    /// Everything on the board.
    var contentBounds: CGRect {
        items.reduce(CGRect.null) { $0.union(rect($1)) }
    }

    /// The board area in view, a little generous.
    var visibleRect: CGRect {
        let a = camera.board(.zero, in: size), b = camera.board(CGPoint(x: size.width, y: size.height), in: size)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).insetBy(dx: -200 / camera.zoom, dy: -200 / camera.zoom)
    }

    /// The middle of the part of the view that isn't covered, on the board.
    var usableCenter: CGPoint {
        let x = insets.leading + (size.width - insets.leading - insets.trailing) / 2
        let y = insets.top + (size.height - insets.top - insets.bottom) / 2
        return camera.board(CGPoint(x: x, y: y), in: size)
    }

    private func drawingDistance(_ item: BoardItem, _ p: CGPoint) -> Double {
        let points = (item.points ?? []).map { CGPoint(x: item.position.x + $0.x, y: item.position.y + $0.y) }
        guard points.count > 1 else {
            return points.first.map { Double(hypot(p.x - $0.x, p.y - $0.y)) } ?? .infinity
        }
        var best = Double.infinity
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let l2 = dx * dx + dy * dy
            let t = l2 > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2)) : 0
            best = min(best, Double(hypot(p.x - (a.x + dx * t), p.y - (a.y + dy * t))))
        }
        return best
    }

    // MARK: - Hit testing

    func hit(at screen: CGPoint) -> BoardHit? {
        let p = camera.board(screen, in: size)
        let slack = 6 / camera.zoom
        let frontToBack = items.reversed()
        // The resize handle of a single selected picture, video or text.
        if selection.count == 1, let id = selection.first, let item = item(id), [.image, .video, .text].contains(item.kind) {
            let box = rect(item)
            let corner = camera.screen(CGPoint(x: box.maxX, y: box.maxY), in: size)
            if hypot(screen.x - corner.x, screen.y - corner.y) < 12 { return .resize(id) }
        }
        // Knots, on threads that are selected or under the pointer.
        for item in frontToBack where item.kind == .track && (selection.contains(item.id) || hover?.itemID == item.id) {
            for (index, knot) in item.threadKnots.enumerated() {
                let s = camera.screen(knot.cgPoint, in: size)
                if hypot(screen.x - s.x, screen.y - s.y) < 10 { return .knot(item.id, index) }
            }
        }
        for item in frontToBack where item.kind == .track {
            if cardRect(item).contains(p) {
                let disc = discCenter(item)
                return hypot(p.x - disc.x, p.y - disc.y) < 21 ? .play(item.id) : .card(item.id)
            }
            let wave = waveRect(item)
            if wave.contains(p) {
                return .wave(item.id, fraction: Double((p.x - wave.minX) / wave.width))
            }
        }
        // Threads are thin, so they're easy to grab within a few points.
        for item in frontToBack where item.kind == .track {
            let path = self.path(item)
            let reach = Self.threadWidth / 2 + 9 / camera.zoom
            guard path.bounds.insetBy(dx: -reach, dy: -reach).contains(p) else { continue }
            let near = path.nearest(to: p)
            if near.distance < reach {
                return .thread(item.id, fraction: near.fraction, insertIndex: near.insertIndex,
                               point: path.sample(atFraction: near.fraction).point)
            }
        }
        for item in frontToBack where item.kind != .track {
            if item.kind == .drawing {
                if drawingDistance(item, p) < Double((item.lineWidth ?? 4) / 2 + slack + 2) { return .item(item.id) }
            } else if rect(item).contains(p) {
                return .item(item.id)
            }
        }
        return nil
    }

    func hover(at screen: CGPoint?) {
        guard let screen, trayDrag == nil else {
            if hover != nil { hover = nil }
            return
        }
        let found = hit(at: screen)
        if found != hover { hover = found }
    }

    // MARK: - Pointer

    private enum Gesture {
        case move(ids: [UUID], originals: [UUID: BoardItem])
        case knot(UUID, Int, BoardItem)
        case pressThread(UUID, fraction: Double, insertIndex: Int, point: CGPoint, original: BoardItem)
        case resize(UUID, BoardItem)
        case marquee(additive: Bool, base: Set<UUID>)
        case draw
        case play(UUID)
        case placeText
    }

    func pointerChanged(start: CGPoint, location: CGPoint) {
        if gesture == nil { begin(at: start) }
        drag(to: location)
    }

    func pointerEnded(start: CGPoint, location: CGPoint) {
        if gesture == nil { begin(at: start) }
        end(at: location, moved: hypot(location.x - start.x, location.y - start.y) > 3)
        gesture = nil
    }

    private func begin(at screen: CGPoint) {
        gestureStart = screen
        pressFraction = nil
        if editingText != nil { finishEditing() }
        // Clicking the board takes the keyboard back (from the search field, say),
        // so its shortcuts work.
        releaseTextFocus()
        let shift = NSEvent.modifierFlags.contains(.shift)
        let p = camera.board(screen, in: size)
        switch tool {
        case .draw:
            stroke = [p]
            gesture = .draw
            return
        case .text:
            gesture = .placeText
            return
        case .select:
            break
        }
        switch hit(at: screen) {
        case .resize(let id)?:
            gesture = item(id).map { .resize(id, $0) }
        case .knot(let id, let index)?:
            selection = [id]
            gesture = item(id).map { .knot(id, index, $0) }
        case .thread(let id, let fraction, let insertIndex, let point)?:
            if !selection.contains(id) { selection = shift ? selection.union([id]) : [id] }
            gesture = item(id).map { .pressThread(id, fraction: fraction, insertIndex: insertIndex, point: point, original: $0) }
        case .play(let id)?:
            gesture = .play(id)
        case .wave(let id, let fraction)?:
            pressFraction = fraction
            beginMove(id, shift: shift)
        case .card(let id)?, .item(let id)?:
            beginMove(id, shift: shift)
        case nil:
            gesture = .marquee(additive: shift, base: shift ? selection : [])
            if !shift { selection = [] }
        }
    }

    private func beginMove(_ id: UUID, shift: Bool) {
            if shift {
                if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            } else if !selection.contains(id) {
                selection = [id]
            }
            let ids = selection.contains(id) ? Array(selection) : [id]
            var originals: [UUID: BoardItem] = [:]
            for id in ids { originals[id] = item(id) }
            gesture = .move(ids: ids, originals: originals)
    }

    private func drag(to screen: CGPoint) {
        let p = camera.board(screen, in: size), start = camera.board(gestureStart, in: size)
        let delta = BoardPoint(Double(p.x - start.x), Double(p.y - start.y))
        let moved = hypot(screen.x - gestureStart.x, screen.y - gestureStart.y) > 3
        switch gesture {
        case .draw:
            if let last = stroke?.last, hypot(p.x - last.x, p.y - last.y) > 1.5 / camera.zoom { stroke?.append(p) }
        case .move(let ids, let originals):
            guard moved else { return }
            for id in ids {
                guard var item = originals[id] else { continue }
                item.position = item.position + delta
                draft[id] = item
            }
        case .knot(let id, let index, let original):
            guard moved else { return }
            draft[id] = Self.moving(knot: index, of: original, by: delta)
        case .pressThread(let id, _, let insertIndex, let point, let original):
            guard moved else { return }
            // Pulling a thread puts a new knot where it was grabbed.
            var item = original
            var thread = item.thread ?? [.zero, BoardPoint(BoardItem.threadLengthRange.lowerBound, 0)]
            thread.insert(BoardPoint(point) - item.position, at: min(insertIndex, thread.count))
            item.thread = thread
            gesture = .knot(id, insertIndex, item)
            draft[id] = Self.moving(knot: insertIndex, of: item, by: delta)
        case .resize(let id, let original):
            draft[id] = Self.resizing(original, by: delta)
        case .marquee(_, let base):
            guard moved else { return }
            let box = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            marquee = box
            let inside = items.filter { rect($0).intersects(box) }.map(\.id)
            selection = base.union(inside)
        case .play, .placeText, nil:
            break
        }
    }

    private func end(at screen: CGPoint, moved: Bool) {
        let p = camera.board(screen, in: size)
        let double = !moved && isDoubleClick(at: screen)
        defer { if !moved { lastClick = (ProcessInfo.processInfo.systemUptime, screen) } }
        switch gesture {
        case .draw:
            if let points = stroke, points.count > 1 { addDrawing(points) }
            stroke = nil
        case .placeText:
            addText(at: p)
            tool = .select
        case .move(let ids, _):
            if moved {
                commitDraft()
            } else if double, let id = ids.first, ids.count == 1 || selection.count == 1 {
                doubleClicked(id)
            }
        case .knot(let id, let index, _):
            if moved {
                commitDraft()
            } else if double {
                removeKnot(index, of: id)
            }
        case .pressThread(let id, let fraction, _, _, _):
            if double { play(id, from: fraction) }
        case .resize:
            if moved { commitDraft() }
        case .marquee:
            marquee = nil
            if double { addText(at: p) }
        case .play(let id):
            if !moved { play(id, from: 0) }
        case nil:
            break
        }
        // Edits that didn't amount to a change (a click on a handle, a drag
        // back to where it started) must not linger and get saved later.
        if editingText == nil { draft.removeAll() }
    }

    private func isDoubleClick(at screen: CGPoint) -> Bool {
        guard let lastClick else { return false }
        return ProcessInfo.processInfo.systemUptime - lastClick.time < NSEvent.doubleClickInterval
            && hypot(screen.x - lastClick.point.x, screen.y - lastClick.point.y) < 6
    }

    private func doubleClicked(_ id: UUID) {
        guard let item = item(id) else { return }
        switch item.kind {
        case .track: play(id, from: pressFraction ?? 0)   // on the waveform: from there
        case .text: beginEditing(id, isNew: false)
        case .image, .video: fly(to: rect(item), maxZoom: 2.5)
        case .drawing: break
        }
    }

    static func moving(knot index: Int, of item: BoardItem, by delta: BoardPoint) -> BoardItem {
        var item = item
        guard var thread = item.thread, thread.indices.contains(index) else { return item }
        if index == 0 {
            // The start (and its card) moves; the rest of the thread stays put.
            item.position = item.position + delta
            for i in thread.indices.dropFirst() { thread[i] = thread[i] - delta }
        } else {
            thread[index] = thread[index] + delta
        }
        item.thread = thread
        return item
    }

    static func resizing(_ item: BoardItem, by delta: BoardPoint) -> BoardItem {
        var item = item
        switch item.kind {
        case .image, .video:
            let width = item.width ?? 300, height = item.height ?? 200
            let aspect = width / max(height, 1)
            let newWidth = max(60, max(width + delta.x, (height + delta.y) * aspect))
            item.width = newWidth
            item.height = newWidth / aspect
        case .text:
            let width = item.width ?? 360
            let scale = max(0.15, (width + delta.x) / width)
            item.width = width * scale
            item.fontSize = (item.fontSize ?? 32) * scale
        case .track, .drawing:
            break
        }
        return item
    }

    // MARK: - Editing

    /// One undoable change: just the items it touched, before and after
    /// (nil: not on the board), so undoing never disturbs anything else,
    /// like edits that arrived from another device in the meantime.
    private struct Change {
        var before: [UUID: BoardItem?] = [:]
        var after: [UUID: BoardItem?] = [:]
        var background: (before: String, after: String)?
    }

    private func record(_ change: Change) {
        undoStack.append(change)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let change = undoStack.popLast() else { NSSound.beep(); return }
        apply(change.before, background: change.background?.before)
        redoStack.append(change)
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let change = redoStack.popLast() else { NSSound.beep(); return }
        apply(change.after, background: change.background?.after)
        undoStack.append(change)
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    private func apply(_ state: [UUID: BoardItem?], background: String?) {
        editingText = nil
        draft = [:]
        var saves: [BoardItem] = []
        var removals: [UUID] = []
        for (id, item) in state {
            if let item { saves.append(item) } else { removals.append(id) }
        }
        if !removals.isEmpty { store.removeBoardItems(removals, from: collectionID) }
        if !saves.isEmpty { store.saveBoardItems(saves, in: collectionID) }
        if let background { store.setBoardBackground(background, for: collectionID) }
        selection = selection.filter { store.board(for: collectionID).items[$0] != nil }
    }

    /// Saves new or changed items, as one undoable change.
    private func save(_ items: [BoardItem]) {
        guard !items.isEmpty else { return }
        var change = Change()
        for item in items {
            change.before[item.id] = .some(board.items[item.id])
            change.after[item.id] = .some(item)
        }
        store.saveBoardItems(items, in: collectionID)
        record(change)
    }

    /// Items that arrived some other way (pictures finishing compressing):
    /// undoable as having been added.
    private func recordAdded(_ items: [BoardItem]) {
        guard !items.isEmpty else { return }
        var change = Change()
        for item in items {
            change.before[item.id] = .some(nil)
            change.after[item.id] = .some(item)
        }
        record(change)
    }

    private func commitDraft() {
        // Only items still on the board (one may have been deleted, here or on
        // another device, mid-drag).
        let changed = draft.values.filter { board.items[$0.id] != nil && $0 != board.items[$0.id] }
        draft = [:]
        save(Array(changed))
    }

    /// Puts a song on the board with its title card centred on `point`.
    func place(_ trackID: UUID, cardCenteredAt point: CGPoint) {
        if let existing = placement(of: trackID) {
            selection = [existing.id]
            fly(to: rect(existing), maxZoom: 1.2)
            return
        }
        guard let track = store.tracks[trackID] else { return }
        let start = BoardPoint(Double(point.x - Self.cardSize.width / 2 + 8),
                               Double(point.y + Self.cardSize.height / 2 + 8 + Self.waveHeight + Self.waveLift))
        let item = BoardItem.track(trackID, at: start, duration: track.duration, z: board.topZ + 1)
        save([item])
        unspooling[item.id] = CACurrentMediaTime()
        selection = [item.id]
    }

    /// Lays the songs that aren't on the board yet out along a gentle wave.
    func placeAll() {
        let unplaced = songs.filter { $0.item == nil }.map(\.track)
        guard !unplaced.isEmpty else { return }
        let existing = contentBounds
        let origin = existing.isNull ? usableCenter : CGPoint(x: existing.minX, y: existing.maxY + 240)
        var z = board.topZ
        var added: [BoardItem] = []
        for (index, track) in unplaced.enumerated() {
            z += 1
            let x = origin.x + (index.isMultiple(of: 2) ? 0 : 160)
            let y = origin.y + CGFloat(index) * 210
            var item = BoardItem.track(track.id, at: BoardPoint(Double(x), Double(y)), duration: track.duration, z: z)
            if let end = item.thread?.last {
                item.thread = [.zero, BoardPoint(end.x * 0.5, index.isMultiple(of: 2) ? 40 : -40), end]
            }
            added.append(item)
            unspooling[item.id] = CACurrentMediaTime()
        }
        save(added)
        fit()
    }

    func addText(at point: CGPoint) {
        var item = BoardItem(kind: .text, position: BoardPoint(Double(point.x), Double(point.y - 16 / camera.zoom)), z: board.topZ + 1)
        item.text = ""
        item.fontSize = Double(min(240, max(12, 30 / camera.zoom)))
        item.width = Double(min(2400, max(120, 380 / camera.zoom)))
        // Saved straight away (so typing is never lost), but only undoable
        // once there's something in it.
        store.saveBoardItems([item], in: collectionID)
        selection = [item.id]
        beginEditing(item.id, isNew: true)
    }

    /// Starts editing a text item in place.
    func beginEditing(_ id: UUID, isNew: Bool) {
        editingOriginal = isNew ? .some(nil) : .some(board.items[id])
        editingText = id
    }

    func setText(_ text: String, for id: UUID) {
        guard var item = item(id) else { return }
        item.text = text
        draft[id] = item
        // Save as you type (after a pause), like notes.
        textSave?.cancel()
        textSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, let typed = self.draft[id], self.board.items[id] != nil,
                  !(typed.text ?? "").isEmpty else { return }
            self.store.saveBoardItems([typed], in: self.collectionID)
        }
    }

    /// A text field that has been removed keeps the keyboard until told otherwise.
    private func releaseTextFocus() {
        if let window, window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        }
    }

    func finishEditing() {
        guard let id = editingText else { return }
        editingText = nil
        textSave?.cancel()
        releaseTextFocus()
        let original = editingOriginal ?? nil
        editingOriginal = nil
        let final = draft[id] ?? board.items[id]
        draft[id] = nil
        guard let final, board.items[id] != nil else { return }
        if (final.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.removeBoardItems([id], from: collectionID)
            selection.remove(id)
            // Emptying a text that was there before is a removal, and undoable.
            if let original { record(Change(before: [id: original], after: [id: nil])) }
        } else {
            store.saveBoardItems([final], in: collectionID)
            if original?.text != final.text || original == nil {
                record(Change(before: [id: original], after: [id: final]))
            }
        }
    }

    private func addDrawing(_ points: [CGPoint]) {
        guard let first = points.first else { return }
        var item = BoardItem(kind: .drawing, position: BoardPoint(first), z: board.topZ + 1)
        item.points = points.map { BoardPoint(Double($0.x - first.x), Double($0.y - first.y)) }
        item.color = penColor
        item.lineWidth = Double(min(40, max(1.5, 4 / camera.zoom)))
        save([item])
    }

    func deleteSelection() {
        let ids = selection.filter { board.items[$0] != nil }
        selection = []
        for id in ids { draft[id] = nil }
        guard !ids.isEmpty else { return }
        var change = Change()
        for id in ids {
            change.before[id] = .some(board.items[id])
            change.after[id] = .some(nil)
        }
        store.removeBoardItems(Array(ids), from: collectionID)
        record(change)
    }

    func duplicateSelection() {
        var z = board.topZ
        let copies: [BoardItem] = selection.compactMap { item($0) }.filter { $0.kind != .track }.map { original in
            z += 1
            var copy = original
            copy.id = UUID()
            copy.position = original.position + BoardPoint(Double(30 / camera.zoom), Double(30 / camera.zoom))
            copy.z = z
            copy.createdAt = Date()
            return copy
        }
        guard !copies.isEmpty else { return }
        save(copies)
        selection = Set(copies.map(\.id))
    }

    func bringToFront(_ ids: Set<UUID>) {
        var z = board.topZ
        save(ids.compactMap { item($0) }.sorted { $0.z < $1.z }.map { var item = $0; z += 1; item.z = z; return item })
    }

    func sendToBack(_ ids: Set<UUID>) {
        var z = (board.items.values.map(\.z).min() ?? 0) - Double(ids.count)
        save(ids.compactMap { item($0) }.sorted { $0.z < $1.z }.map { var item = $0; z += 1; item.z = z; return item })
    }

    func straighten(_ id: UUID) {
        guard var item = item(id), let trackID = item.trackID, let track = store.tracks[trackID] else { return }
        item.thread = BoardItem.track(trackID, at: item.position, duration: track.duration).thread
        save([item])
    }

    private func removeKnot(_ index: Int, of id: UUID) {
        guard var item = item(id), var thread = item.thread, index > 0, index < thread.count - 1 else { return }
        thread.remove(at: index)
        item.thread = thread
        save([item])
    }

    func nudge(by delta: CGSize) {
        let moved = selection.compactMap { item($0) }.map { var item = $0; item.position = item.position + BoardPoint(Double(delta.width), Double(delta.height)); return item }
        save(moved)
    }

    func setBackground(_ hex: String) {
        let before = background
        guard hex != before else { return }
        store.setBoardBackground(hex, for: collectionID)
        // Dragging around the colour picker is one change, not hundreds.
        if lastBackgroundCheckpoint.map({ Date().timeIntervalSince($0) < 1.5 }) == true,
           var last = undoStack.last, last.background != nil, last.before.isEmpty {
            last.background?.after = hex
            undoStack[undoStack.count - 1] = last
        } else {
            record(Change(background: (before, hex)))
        }
        lastBackgroundCheckpoint = Date()
    }

    // MARK: - Pictures and videos

    func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = true
        panel.message = "Pictures and videos are resized and compressed as they're added."
        panel.prompt = "Add to Moodboard"
        guard panel.runModal() == .OK else { return }
        addMedia(panel.urls, at: usableCenter)
    }

    func addMedia(_ urls: [URL], at point: CGPoint) {
        // Songs dropped on the board join the collection, laid out where they landed.
        let audio = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }
        if !audio.isEmpty {
            let store = store, id = collectionID
            Task {
                let added = await store.importAudio(from: audio, into: id)
                var spot = point
                for trackID in added {
                    place(trackID, cardCenteredAt: spot)
                    spot.y += 210
                }
            }
        }
        let media = urls.filter { BoardMedia.isImage($0) || BoardMedia.isVideo($0) }
        guard !media.isEmpty else { return }
        addingMedia += media.count
        Task {
            let added = await store.addBoardMedia(from: media, to: collectionID, centeredAt: BoardPoint(point))
            addingMedia -= media.count
            recordAdded(added)
            if !added.isEmpty { selection = Set(added.map(\.id)) }
        }
    }

    /// ⌘V: pictures or videos from the clipboard.
    func paste() -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { BoardMedia.isImage($0) || BoardMedia.isVideo($0) }) {
            addMedia(urls, at: usableCenter)
            return true
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            addingMedia += 1
            let center = usableCenter
            Task {
                let added = await store.addBoardImage(data: data, to: collectionID, centeredAt: BoardPoint(center))
                addingMedia -= 1
                if let added {
                    recordAdded([added])
                    selection = [added.id]
                }
            }
            return true
        }
        return false
    }

    // MARK: - Camera

    func pan(by delta: CGSize) {
        stopFollowing()
        camera.pan(by: delta)
        scheduleCameraSave()
    }

    func zoom(by factor: CGFloat, around anchor: CGPoint) {
        stopFollowing()
        camera.zoom(by: factor, around: anchor, in: size)
        scheduleCameraSave()
    }

    func zoomStep(_ factor: CGFloat) {
        let anchor = CGPoint(x: insets.leading + (size.width - insets.leading - insets.trailing) / 2,
                             y: insets.top + (size.height - insets.top - insets.bottom) / 2)
        stopFollowing()
        var target = camera
        target.zoom(by: factor, around: anchor, in: size)
        fly(to: target, duration: 0.3)
    }

    /// Shows everything on the board.
    func fit() {
        stopFollowing()
        let bounds = contentBounds
        guard !bounds.isNull else {
            fly(to: BoardCamera(), duration: 0.6)
            return
        }
        fly(to: bounds, maxZoom: 1)
    }

    func fly(to rect: CGRect, maxZoom: CGFloat) {
        fly(to: BoardCamera.fitting(rect.insetBy(dx: -60, dy: -60), in: size, insets: insets, maxZoom: maxZoom))
    }

    func fly(to target: BoardCamera, duration: Double? = nil, dip: Bool = false) {
        let camera = liveCamera
        let distance = hypot(target.center.x - camera.center.x, target.center.y - camera.center.y) * camera.zoom
        let screen = max(size.width, 400)
        flight = Flight(
            from: camera,
            to: target,
            start: nil,
            duration: duration ?? min(2.2, max(0.55, 0.5 + Double(distance / screen) * 0.6)),
            dip: dip ? min(0.45, Double(distance / (distance + screen)) * 0.8) : 0
        )
        scheduleCameraSave()
    }

    private func scheduleCameraSave() {
        cameraSave?.cancel()
        cameraSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveCamera()
        }
    }

    private var cameraKey: String { "moodboard.camera.\(collectionID.uuidString)" }

    func saveCamera() {
        let settled = flight?.to ?? camera
        if let data = try? JSONEncoder().encode(settled) { UserDefaults.standard.set(data, forKey: cameraKey) }
    }

    /// First layout: pull back from close up onto the board, and unspool the threads.
    func open() {
        guard !opened, size.width > 0 else { return }
        opened = true
        let saved = UserDefaults.standard.data(forKey: cameraKey).flatMap { try? JSONDecoder().decode(BoardCamera.self, from: $0) }
        let bounds = contentBounds
        let target = saved ?? (bounds.isNull ? BoardCamera() : BoardCamera.fitting(bounds.insetBy(dx: -60, dy: -60), in: size, insets: insets, maxZoom: 1))
        camera = BoardCamera(center: target.center, zoom: target.zoom * 1.7)
        flight = Flight(from: camera, to: target, start: nil, duration: 1.0, dip: 0)
        reveal = 0
        let store = store, id = collectionID
        Task { await store.tidyBoardMedia(of: id) }
    }

    // MARK: - Following the music

    /// The playhead to draw. While the music plays, the frame loop works it
    /// out (and decides when it has moved enough to be drawn again), so
    /// drawing it doesn't tie the board to every tick of the player's clock.
    func shownBead() -> BoardBead? {
        if player.isPlaying, let framed = framedBead, CACurrentMediaTime() - framed.at < 0.1 { return framed.bead }
        return bead()
    }

    /// The playhead on the board, if the song playing is on it.
    func bead() -> BoardBead? {
        guard let trackID = player.currentTrackID, let item = placement(of: trackID), player.duration > 0 else { return nil }
        let fraction = min(1, max(0, player.exactTime / player.duration))
        let sample = path(item).sample(atFraction: fraction)
        return BoardBead(item: item, fraction: fraction, point: sample.point, tangent: sample.tangent)
    }

    var isJourneyPlaying: Bool {
        player.isPlaying && player.currentTrackID.map { placement(of: $0) != nil } == true
    }

    /// Plays the journey from the first song on the board (or pauses/resumes it).
    func playJourney() {
        if let current = player.currentTrackID, player.contextCollectionID == collectionID, placement(of: current) != nil {
            if player.isPlaying {
                player.pause()
            } else {
                player.resume()
                startFollowing()
            }
            return
        }
        let order = journeyTrackIDs
        guard let first = order.first else { return }
        player.play(trackIDs: order, startingAt: first, context: collectionID, inOrder: true)
        startFollowing()
    }

    /// The songs on the board that can play, in the journey's order.
    private var journeyTrackIDs: [UUID] {
        journey.compactMap(\.trackID).filter { store.tracks[$0].map { $0.archivedAt == nil } ?? false }
    }

    /// Plays a song on the board, from a point along its thread.
    func play(_ itemID: UUID, from fraction: Double) {
        guard let item = item(itemID), let trackID = item.trackID, let track = store.tracks[trackID] else { return }
        let order = journeyTrackIDs.contains(trackID) ? journeyTrackIDs : [trackID]
        if fraction > 0.002 {
            player.play(trackID: trackID, at: fraction * track.duration, in: order, context: collectionID, inOrder: true)
        } else if player.currentTrackID == trackID {
            player.togglePlayPause()
        } else {
            player.play(trackIDs: order, startingAt: trackID, context: collectionID, inOrder: true)
        }
        if player.isPlaying || fraction > 0.002 { startFollowing() }
    }

    func startFollowing() {
        following = true
        followZoom = min(1.3, max(0.55, flight?.to.zoom ?? camera.zoom))
    }

    func stopFollowing() {
        following = false
        flight = nil
    }

    /// The camera is on the move (or things are unspooling), so frames should be smooth.
    var cameraMoving: Bool {
        flight != nil || (following && player.isPlaying) || reveal < 1 || !unspooling.isEmpty
    }

    var needsFrames: Bool {
        reveal < 1 || flight != nil || !unspooling.isEmpty
            || (player.isPlaying && player.currentTrackID.map { placement(of: $0) != nil } == true)
    }

    /// Unspooling progress of a newly placed thread (1 when done).
    func unspool(_ id: UUID) -> Double {
        guard let start = unspooling[id] else { return 1 }
        return min(1, max(0, (frameTime - start) / 0.9))
    }

    func step(_ now: CFTimeInterval) {
        let dt = lastFrame.map { min(0.1, max(0, now - $0)) } ?? 1 / 60
        lastFrame = now
        // Threads unspooling change every frame.
        var redraw = reveal < 1 || !unspooling.isEmpty
        if reveal < 1 { reveal = min(1, reveal + dt / 1.3) }
        for (id, start) in unspooling where now - start > 1 { unspooling[id] = nil }

        let current = bead()
        framedBead = (current, CACurrentMediaTime())
        var next = liveCamera
        if var flight {
            if flight.start == nil {
                flight.start = now
                self.flight = flight
            }
            let t = min(1, (now - (flight.start ?? now)) / flight.duration)
            next = flight.camera(at: t)
            if t >= 1 {
                self.flight = nil
                redraw = true
            }
        } else if following, let current {
            follow(current, dt: dt, camera: &next)
        }
        liveCamera = next

        // Each redraw costs the whole board, so a frame is only drawn when
        // something would visibly move: the view, or the playhead on screen,
        // by about a pixel. At the music's pace that's often a fraction of
        // the display's frames.
        let hair: CGFloat = player.lowPower ? 1.5 : 0.5
        let bead = current.map { (id: $0.item.id, point: next.screen($0.point, in: size)) }
        if camera.shift(to: next, in: size) >= hair {
            redraw = true
        }
        if let bead, let drawnBead {
            if bead.id != drawnBead.id || hypot(bead.point.x - drawnBead.point.x, bead.point.y - drawnBead.point.y) >= hair {
                redraw = true
            }
        } else if (bead == nil) != (drawnBead == nil) {
            redraw = true
        }
        if redraw {
            camera = next
            drawnBead = bead
            frameTime = now
        }
    }

    private func follow(_ bead: BoardBead, dt: Double, camera: inout BoardCamera) {
        // Look a little ahead, and keep the playhead in the middle of the uncovered area.
        let lead = 80 / camera.zoom
        let ahead = CGPoint(x: bead.point.x + bead.tangent.dx * lead, y: bead.point.y + bead.tangent.dy * lead)
        let offset = CGPoint(x: (insets.leading - insets.trailing) / 2, y: (insets.top - insets.bottom) / 2)
        let goal = CGPoint(x: ahead.x - offset.x / camera.zoom, y: ahead.y - offset.y / camera.zoom)
        let distance = hypot(goal.x - camera.center.x, goal.y - camera.center.y) * camera.zoom
        if distance > max(size.width, size.height) * 0.6 {
            // A new song somewhere else on the board: travel there.
            let goalZoom = followZoom
            fly(to: BoardCamera(center: CGPoint(x: ahead.x - offset.x / goalZoom, y: ahead.y - offset.y / goalZoom), zoom: goalZoom), dip: true)
        } else {
            let k = 1 - exp(-dt * 3)
            camera.center.x += (goal.x - camera.center.x) * k
            camera.center.y += (goal.y - camera.center.y) * k
            camera.zoom += (followZoom - camera.zoom) * (1 - exp(-dt * 1.2))
        }
    }

    /// How present an item is while the journey plays: things near the
    /// playhead are clear, things far away fade back.
    func emphasis(of item: BoardItem, bead: BoardBead?) -> Double {
        guard following, player.isPlaying, let bead else { return 1 }
        if item.id == bead.item.id { return 1 }
        let box = item.kind == .track ? cardRect(item).union(path(item).bounds) : rect(item)
        let dx = max(box.minX - bead.point.x, 0, bead.point.x - box.maxX)
        let dy = max(box.minY - bead.point.y, 0, bead.point.y - box.maxY)
        return 1 - 0.62 * smoothstep(380, 1250, Double(hypot(dx, dy)))
    }

    func tint(for trackID: UUID) -> ArtworkTint? {
        if let tint = tints[trackID] { return tint }
        if !tintRequests.contains(trackID) {
            tintRequests.insert(trackID)
            let model = AppModel.shared
            let art = model.artwork(forTrack: trackID, in: collectionID)
            Task {
                tints[trackID] = await ArtworkTint.make(url: art.url, seed: art.seed)
            }
        }
        return nil
    }

    // MARK: - Tray

    func trayDragChanged(_ trackID: UUID, location: CGPoint) {
        trayDrag = TrayDrag(trackID: trackID, location: location)
    }

    func trayDragEnded(_ trackID: UUID, location: CGPoint) {
        trayDrag = nil
        guard !trayFrame.insetBy(dx: -8, dy: -8).contains(location) else { return }
        place(trackID, cardCenteredAt: camera.board(location, in: size))
    }

    // MARK: - Keys

    /// Board shortcuts. Returns whether the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        guard editingText == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 51, 117:
            guard modifiers.isEmpty, !selection.isEmpty else { return false }
            deleteSelection()
            return true
        case 53:
            if tool != .select { tool = .select; return true }
            if !selection.isEmpty { selection = []; return true }
            if following { stopFollowing(); return true }
            return false
        case 36, 76:
            if modifiers.isEmpty, selection.count == 1, let id = selection.first, item(id)?.kind == .text {
                beginEditing(id, isNew: false)
                return true
            }
            return false
        case 123, 124, 125, 126:
            guard !selection.isEmpty, modifiers.subtracting(.shift).isEmpty else { return false }
            let step: CGFloat = (modifiers.contains(.shift) ? 10 : 1) / camera.zoom
            let delta: CGSize = switch event.keyCode {
            case 123: CGSize(width: -step, height: 0)
            case 124: CGSize(width: step, height: 0)
            case 125: CGSize(width: 0, height: step)
            default: CGSize(width: 0, height: -step)
            }
            nudge(by: delta)
            return true
        default:
            break
        }
        if modifiers == .command {
            switch key {
            case "z": undo(); return true
            case "a": selection = Set(items.map(\.id)); return true
            case "0": fit(); return true
            case "=", "+": zoomStep(1.25); return true
            case "-": zoomStep(0.8); return true
            case "v": return paste()
            case "d": duplicateSelection(); return true
            default: return false
            }
        }
        if modifiers == [.command, .shift], key == "z" {
            redo()
            return true
        }
        if modifiers.isEmpty {
            switch key {
            case "v": tool = .select; return true
            case "d", "p": tool = .draw; return true
            case "t": tool = .text; return true
            case "f": fit(); return true
            default: return false
            }
        }
        return false
    }
}
