import AVFoundation
import AppKit
import ImageIO
import SwiftUI
import UnnamedKit

/// A song's title card at the head of its thread: its disc (click to play)
/// and title, on glass.
struct ThreadCard: View {
    let item: BoardItem
    let track: Track
    let number: Int?
    let scale: CGFloat
    let isCurrent: Bool
    let isPlaying: Bool
    let hoveringDisc: Bool
    let tint: Color?
    let dark: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        if scale > 0.32 {
            card
        } else {
            // Zoomed far out, just the disc.
            let art = model.artwork(forTrack: track.id, in: nil)
            DiscView(artworkURL: art.url, seed: art.seed, spinning: isCurrent && isPlaying, speed: 40)
                .frame(width: max(10, 36 * scale), height: max(10, 36 * scale))
                .padding(.leading, 9 * scale)
                .frame(width: BoardModel.cardSize.width * scale, height: BoardModel.cardSize.height * scale, alignment: .leading)
                .shadow(color: .black.opacity(0.4), radius: 3)
        }
    }

    private var card: some View {
        let art = model.artwork(forTrack: track.id, in: nil)
        let size = BoardModel.cardSize
        return HStack(spacing: 10 * scale) {
            DiscView(artworkURL: art.url, seed: art.seed, spinning: isCurrent && isPlaying, speed: 40)
                .frame(width: 36 * scale, height: 36 * scale)
                .overlay {
                    if hoveringDisc || (isCurrent && !isPlaying) {
                        Image(systemName: isCurrent && isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13 * scale, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3 * scale)
                    }
                }
            VStack(alignment: .leading, spacing: 1 * scale) {
                Text(track.title)
                    .font(.system(size: 15 * scale, weight: .semibold))
                    .lineLimit(1)
                Text([number.map { String(format: "%02d", $0) }, Format.clock(track.duration)].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 11 * scale, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 9 * scale)
        .padding(.trailing, 16 * scale)
        .frame(width: size.width * scale, height: size.height * scale, alignment: .leading)
        .background {
            // With Liquid Glass the card's glass is drawn with the threads'
            // (it turns with the thread, and glass can't be turned as a view).
            if !glass {
                Capsule()
                    .fill(dark ? Color(white: 0.13).opacity(0.92) : Color.white.opacity(0.92))
                    .overlay(Capsule().strokeBorder((dark ? Color.white : .black).opacity(0.1), lineWidth: 1))
                    .overlay {
                        if isCurrent, let tint {
                            Capsule().fill(tint.opacity(0.22))
                        }
                    }
                    .shadow(color: .black.opacity(dark ? 0.35 : 0.12), radius: 10 * scale, y: 4 * scale)
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// A picture on the board, decoded at a size that suits the zoom.
struct BoardImage: View {
    let item: BoardItem
    let collectionID: UUID
    let store: LibraryStore
    let screenSize: CGSize
    let dark: Bool
    @State private var image: NSImage?
    @State private var loadedBucket = 0

    var body: some View {
        let bucket = Self.bucket(for: screenSize)
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill((dark ? Color.white : .black).opacity(0.06))
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .clipShape(RoundedRectangle(cornerRadius: max(2, min(10, screenSize.width / 40)), style: .continuous))
        .shadow(color: .black.opacity(dark ? 0.4 : 0.15), radius: 12, y: 6)
        .task(id: "\(item.file ?? "")#\(bucket)") {
            guard bucket > loadedBucket || image == nil else { return }
            guard let url = await store.readyBoardMedia(item, in: collectionID) else { return }
            let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: bucket,
                ] as CFDictionary)
            }.value
            if let decoded {
                image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                loadedBucket = bucket
            }
        }
    }

    /// Pixel sizes in steps, so zooming doesn't decode on every frame.
    static func bucket(for size: CGSize) -> Int {
        let needed = Int(max(size.width, size.height) * 2)
        var bucket = 256
        while bucket < needed, bucket < 2048 { bucket *= 2 }
        return bucket
    }
}

/// A video on the board: muted, looping, playing while it's in view.
struct BoardVideo: View {
    let item: BoardItem
    let collectionID: UUID
    let store: LibraryStore
    let screenSize: CGSize
    let playing: Bool
    let dark: Bool
    @State private var url: URL?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.8))
            if let url {
                LoopingVideo(url: url, playing: playing)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .clipShape(RoundedRectangle(cornerRadius: max(2, min(10, screenSize.width / 40)), style: .continuous))
        .shadow(color: .black.opacity(dark ? 0.4 : 0.15), radius: 12, y: 6)
        .task(id: item.file) {
            url = await store.readyBoardMedia(item, in: collectionID)
        }
    }
}

struct LoopingVideo: NSViewRepresentable {
    let url: URL
    let playing: Bool

    final class PlayerView: NSView {
        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private(set) var url: URL?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer
            player.isMuted = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func load(_ url: URL) {
            guard url != self.url else { return }
            self.url = url
            player.removeAllItems()
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }
    }

    func makeNSView(context: Context) -> PlayerView { PlayerView() }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.load(url)
        if playing { view.player.play() } else { view.player.pause() }
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.player.pause()
    }
}

/// Text on the board.
struct BoardText: View {
    let item: BoardItem
    let zoom: CGFloat
    let dark: Bool
    var onMeasure: (CGSize) -> Void

    var body: some View {
        Text(item.text?.isEmpty == false ? item.text! : " ")
            .font(Self.font(item, zoom: zoom))
            .foregroundStyle(item.color.map(BoardColor.color) ?? (dark ? Color.white : Color.black))
            .frame(width: (item.width ?? 360) * zoom, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onMeasure($0) }
    }

    static func font(_ item: BoardItem, zoom: CGFloat) -> Font {
        .system(size: max(1, (item.fontSize ?? 32) * zoom), weight: .semibold, design: .rounded)
    }
}

/// Editing a text item in place.
struct BoardTextEditor: View {
    let model: BoardModel
    let id: UUID
    @FocusState private var focused: Bool

    var body: some View {
        if let item = model.item(id) {
            let origin = model.camera.screen(item.position.cgPoint, in: model.size)
            TextField("Text", text: Binding(get: { model.item(id)?.text ?? "" }, set: { model.setText($0, for: id) }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(BoardText.font(item, zoom: model.camera.zoom))
                .foregroundStyle(item.color.map(BoardColor.color) ?? (model.isDark ? Color.white : Color.black))
                .frame(width: (item.width ?? 360) * model.camera.zoom, alignment: .leading)
                .focused($focused)
                .onSubmit { finish() }
                .onExitCommand { finish() }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
                .offset(x: origin.x - 4, y: origin.y - 4)
                .onAppear { focused = true }
        }
    }

    /// Lets go of the keyboard before the field goes away; a field removed
    /// while focused makes the next click on the board go missing.
    private func finish() {
        focused = false
        Task { @MainActor in model.finishEditing() }
    }
}
