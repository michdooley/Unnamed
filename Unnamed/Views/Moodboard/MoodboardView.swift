import SwiftUI
import UnnamedKit

/// A collection's moodboard: an infinite dot-grid canvas where the songs are
/// glass threads (their waveforms riding along them) laid out among
/// pictures, videos, text and drawings. Play Journey and the view travels
/// along the threads as the music plays.
struct MoodboardView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(\.liquidGlass) private var glass
    let store: LibraryStore
    let collectionID: UUID

    @State private var model: BoardModel
    @State private var events = BoardEventMonitor()
    @State private var safe = EdgeInsets()

    init(store: LibraryStore, collectionID: UUID) {
        self.store = store
        self.collectionID = collectionID
        _model = State(initialValue: BoardModel(collectionID: collectionID, store: store, player: AppModel.shared.player))
    }

    var body: some View {
        let dark = model.isDark
        ZStack(alignment: .topLeading) {
            // Everything that moves with the camera and the music lives in the
            // stage, so a frame only updates the stage, not the tray and toolbar.
            BoardStage(model: model, store: store, collectionID: collectionID, glass: glass)
            interactionLayer
            if let id = model.editingText {
                BoardTextEditor(model: model, id: id)
            }
            chrome(dark: dark)
        }
        .coordinateSpace(.named(BoardSpace.name))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            model.size = size
            model.open()
        }
        .background {
            WindowFrameReader { frame, window in
                events.frameInWindow = frame
                events.window = window
                model.window = window
            }
        }
        .background {
            FrameDriver(active: model.needsFrames, fast: model.cameraMoving) { model.step($0) }
        }
        .clipped()
        .ignoresSafeArea()
        .background {
            Color.clear.onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets in
                safe = insets
                // The sidebar, window toolbar and player float over the board's
                // edges; scrolling over them is theirs.
                events.passThrough = insets
                // What the tray, the toolbar and the player cover.
                model.insets = EdgeInsets(top: insets.top + 64, leading: insets.leading + 262, bottom: insets.bottom + 16, trailing: insets.trailing + 24)
            }
        }
        .onAppear {
            events.model = model
            events.start()
            BoardModel.current = model
        }
        .onDisappear {
            events.stop()
            model.finishEditing()
            model.saveCamera()
            if BoardModel.current === model { BoardModel.current = nil }
        }
    }

    private var interactionLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { model.pointerChanged(start: $0.startLocation, location: $0.location) }
                    .onEnded { model.pointerEnded(start: $0.startLocation, location: $0.location) }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    model.hoverPoint = location
                    model.hover(at: location)
                case .ended:
                    model.hover(at: nil)
                }
            }
            .pointerStyle(pointer)
            .contextMenu { BoardContextMenu(model: model) }
            .dropDestination(for: URL.self) { urls, location in
                model.addMedia(urls, at: model.camera.board(location, in: model.size))
                return true
            }
    }

    private var pointer: PointerStyle? {
        switch model.tool {
        case .draw: return .rectSelection
        case .text: return .horizontalText
        case .select:
            switch model.hover {
            case .knot?, .thread?: return .grabIdle
            case .resize?: return .frameResize(position: .bottomTrailing)
            case .play?: return .link
            default: return nil
            }
        }
    }

    // MARK: - Chrome

    private func chrome(dark: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            BoardTray(model: model)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BoardSpace.name)) } action: { frame in
                    model.trayFrame = frame
                    events.scrollsOnTheirOwn = [frame]
                }
                .padding(.top, safe.top + 12)
                .padding(.bottom, safe.bottom + 12)
                .padding(.leading, safe.leading + 14)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .transition(.move(edge: .leading).combined(with: .opacity))

            VStack(spacing: 10) {
                BoardToolbar(model: model)
                if model.addingMedia > 0 {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.addingMedia == 1 ? "Compressing…" : "Compressing \(model.addingMedia)…")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .glassOr(glass, in: Capsule(), classic: dark ? Color(white: 0.12).opacity(0.9) : Color.white.opacity(0.92))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, safe.top + 12)
            .padding(.leading, safe.leading + 246)
            .padding(.trailing, safe.trailing + 12)
            .frame(maxWidth: .infinity, alignment: .top)

            if model.items.isEmpty {
                BoardWelcome(model: model)
                    .padding(.leading, safe.leading + 246)
                    .padding(.top, safe.top)
                    .padding(.bottom, safe.bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }

            if let drag = model.trayDrag, let track = store.tracks[drag.trackID] {
                TrayDragGhost(track: track)
                    .position(drag.location)
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .animation(.spring(duration: 0.35), value: model.addingMedia)
        .animation(.spring(duration: 0.45), value: model.items.isEmpty)
    }
}

/// The board's moving parts: backdrop, pictures, ink, threads, cards and
/// selection, drawn for the current camera and moment in the music.
private struct BoardStage: View {
    @Environment(PlayerController.self) private var player
    let model: BoardModel
    let store: LibraryStore
    let collectionID: UUID
    let glass: Bool

    /// Layers switched off for profiling (debug: -boardOff glass,cards).
    static let disabled: Set<String> = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-boardOff"), index + 1 < arguments.count {
            return Set(arguments[index + 1].split(separator: ",").map(String.init))
        }
        #endif
        return []
    }()

    var body: some View {
        let bead = model.bead()
        let threads = model.renderThreads(bead: bead)
        let width = model.threadScreenWidth
        let dark = model.isDark
        let off = Self.disabled
        ZStack(alignment: .topLeading) {
            if !off.contains("backdrop") { BoardBackdrop(camera: model.camera, background: model.background) }
            ConnectorLayer(model: model)
            if !off.contains("media") { mediaLayer(bead: bead, dark: dark) }
            InkLayer(model: model)
            if glass, !off.contains("glass") {
                ThreadGlassLayer(threads: threads, cards: glassCards, width: width, beadSize: model.beadScreenSize, dark: dark)
            }
            if !off.contains("art") {
                ThreadArtLayer(threads: threads, cards: cardFrames, width: width, beadSize: model.beadScreenSize, background: BoardColor.color(model.background),
                               dark: dark, glass: glass, zoom: model.camera.zoom)
            }
            if !off.contains("cards") { cardsLayer(bead: bead, dark: dark) }
            SelectionLayer(model: model)
        }
        // Glass takes its look from the board's colour, not the system appearance.
        .environment(\.colorScheme, dark ? .dark : .light)
        .allowsHitTesting(false)
    }


    private func mediaLayer(bead: BoardBead?, dark: Bool) -> some View {
        let visible = model.visibleRect
        let size = model.size
        let zoom = model.camera.zoom
        let media = model.items.filter { [.image, .video, .text].contains($0.kind) && model.rect($0).intersects(visible) }
        return ZStack(alignment: .topLeading) {
            ForEach(media) { item in
                let box = model.camera.screen(model.rect(item), in: size)
                Group {
                    switch item.kind {
                    case .image:
                        BoardImage(item: item, collectionID: collectionID, store: store, screenSize: box.size, dark: dark)
                    case .video:
                        BoardVideo(item: item, collectionID: collectionID, store: store, screenSize: box.size,
                                   playing: box.intersects(CGRect(origin: .zero, size: size)), dark: dark)
                    case .text:
                        if model.editingText != item.id {
                            BoardText(item: item, zoom: zoom, dark: dark) { measured in
                                model.textSizes[item.id] = CGSize(width: measured.width / zoom, height: measured.height / zoom)
                            }
                        }
                    case .track, .drawing:
                        EmptyView()
                    }
                }
                .opacity(model.emphasis(of: item, bead: bead))
                .offset(x: box.minX, y: box.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Where the title cards are on screen (threads pass under them).
    private var cardFrames: [CGRect] {
        guard model.camera.zoom > 0.32 else { return [] }
        let visible = model.visibleRect
        return model.items.compactMap { item in
            guard item.kind == .track else { return nil }
            let card = model.cardRect(item)
            return card.intersects(visible) ? model.camera.screen(card, in: model.size) : nil
        }
    }

    /// The cards' glass, drawn with the threads'.
    private var glassCards: [GlassCard] {
        let camera = model.camera
        guard camera.zoom > 0.32 else { return [] }
        let size = model.size
        let visible = model.visibleRect
        let toScreen = CGAffineTransform(translationX: -camera.center.x, y: -camera.center.y)
            .concatenating(CGAffineTransform(scaleX: camera.zoom, y: camera.zoom))
            .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
        return model.items.compactMap { item in
            guard item.kind == .track, let trackID = item.trackID, model.cardRect(item).intersects(visible) else { return nil }
            let current = player.currentTrackID == trackID
            return GlassCard(id: item.id, outline: model.cardOutline(item).applying(toScreen),
                             tint: current ? model.tint(for: trackID)?.color : nil)
        }
    }

    private func cardsLayer(bead: BoardBead?, dark: Bool) -> some View {
        let visible = model.visibleRect
        let size = model.size
        let numbers = Dictionary((store.collections[collectionID]?.trackIDs ?? []).enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        let cards = model.items.filter { $0.kind == .track && model.cardRect($0).intersects(visible) }
        let revealed = 1 - pow(1 - model.reveal, 2)
        return ZStack(alignment: .topLeading) {
            ForEach(cards) { item in
                if let trackID = item.trackID, let track = store.tracks[trackID] {
                    let box = model.camera.screen(model.cardRect(item), in: size)
                    ThreadCard(
                        item: item,
                        track: track,
                        number: numbers[trackID],
                        scale: model.camera.zoom,
                        isCurrent: player.currentTrackID == trackID,
                        isPlaying: player.isPlaying,
                        hoveringDisc: model.hover == .play(item.id),
                        tint: model.tint(for: trackID)?.color,
                        dark: dark
                    )
                    .opacity(model.emphasis(of: item, bead: bead) * min(revealed, model.unspool(item.id)))
                    .position(x: box.midX, y: box.midY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

}

/// Right-click: what's offered depends on what's under the pointer.
private struct BoardContextMenu: View {
    let model: BoardModel

    var body: some View {
        let point = model.hoverPoint.map { model.camera.board($0, in: model.size) } ?? model.usableCenter
        switch model.hover {
        case .thread(let id, let fraction, _, _)?, .wave(let id, let fraction)?:
            Button("Play from Here") { model.play(id, from: fraction) }
            songItems(id)
        case .card(let id)?, .play(let id)?, .knot(let id, _)?:
            Button("Play") { model.play(id, from: 0) }
            songItems(id)
        case .item(let id)?, .resize(let id)?:
            if model.item(id)?.kind == .text {
                Button("Edit Text") {
                    model.selection = [id]
                    model.beginEditing(id, isNew: false)
                }
            }
            Button("Bring to Front") { model.bringToFront([id]) }
            Button("Send to Back") { model.sendToBack([id]) }
            Button("Duplicate") {
                model.selection = [id]
                model.duplicateSelection()
            }
            Divider()
            Button("Remove from Moodboard", role: .destructive) {
                model.selection = [id]
                model.deleteSelection()
            }
        case nil:
            Button("Add Text Here") { model.addText(at: point) }
            Button("Add Pictures or Videos…") { model.chooseMedia() }
            Button("Paste") { _ = model.paste() }
            Divider()
            Button("Fit Everything") { model.fit() }
            Menu("Background") {
                ForEach(Array(zip(["Night", "Ink", "Paper", "Sand", "Sage", "Dusk", "Ocean"], BoardColor.presets)), id: \.1) { name, hex in
                    Button(name) { model.setBackground(hex) }
                }
            }
        }
    }

    @ViewBuilder
    private func songItems(_ id: UUID) -> some View {
        Button("Straighten Thread") { model.straighten(id) }
        Divider()
        Button("Remove from Moodboard", role: .destructive) {
            model.selection = [id]
            model.deleteSelection()
        }
    }
}
