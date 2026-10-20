import AppKit
import SwiftUI
import UnnamedKit

/// Cover art, or a gradient picked from the item's ID when there isn't any.
struct ArtworkView: View {
    let url: URL?
    let seed: UUID
    var cornerRadius: CGFloat = 8
    /// Pixel size to decode at; keep small for thumbnails.
    var pixelSize: Int = 600

    @State private var loaded: NSImage?

    var body: some View {
        let image = loaded ?? ArtworkCache.shared.cachedImage(for: url, pixelSize: pixelSize)
        GradientArtwork(seed: seed)
            .overlay {
                if let image {
                    // Filling a non-square image spills past the frame. Clipping
                    // hides that, but the spill would still catch the mouse
                    // (e.g. over the record next to a cover), so it doesn't take hits.
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: url) {
                loaded = nil
                guard let url else { return }
                let image = await ArtworkCache.shared.waitForImage(for: url, pixelSize: pixelSize)
                // A newer artwork may have taken this one's place meanwhile.
                guard !Task.isCancelled else { return }
                loaded = image
            }
    }
}

/// The resolved artwork for a track: its own, else its collection's.
struct TrackArtworkView: View {
    @Environment(AppModel.self) private var model
    let trackID: UUID
    var collectionID: UUID?
    var cornerRadius: CGFloat = 8
    var pixelSize: Int = 600

    var body: some View {
        let artwork = model.artwork(forTrack: trackID, in: collectionID)
        ArtworkView(url: artwork.url, seed: artwork.seed, cornerRadius: cornerRadius, pixelSize: pixelSize)
    }
}

/// Decoded artwork keyed by file URL. Artwork files get a new name whenever
/// they change, so entries never go stale.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 400
    }

    func cachedImage(for url: URL?, pixelSize: Int) -> NSImage? {
        guard let url else { return nil }
        return cache.object(forKey: key(url, pixelSize))
    }

    func image(for url: URL, pixelSize: Int) async -> NSImage? {
        let key = key(url, pixelSize)
        if let hit = cache.object(forKey: key) { return hit }
        let cgImage = await Task.detached(priority: .utility) {
            ArtworkProcessor.thumbnail(at: url, maxPixelSize: pixelSize)
        }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key)
        return image
    }

    /// Like `image(for:pixelSize:)`, but gives a file that may still be
    /// syncing down from iCloud a little while to arrive.
    func waitForImage(for url: URL, pixelSize: Int) async -> NSImage? {
        for attempt in 0..<6 {
            if let image = await image(for: url, pixelSize: pixelSize) { return image }
            try? await Task.sleep(for: .seconds(Double(attempt + 1) * 2))
            if Task.isCancelled { return nil }
        }
        return nil
    }

    private func key(_ url: URL, _ pixelSize: Int) -> NSString {
        "\(url.path)#\(pixelSize)" as NSString
    }
}

/// A soft two-colour gradient chosen deterministically from an ID.
struct GradientArtwork: View {
    let seed: UUID

    var body: some View {
        let palette = Self.palette(for: seed)
        LinearGradient(colors: [palette.0, palette.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func palette(for seed: UUID) -> (Color, Color) {
        let (start, end) = paletteHex(for: seed)
        return (Color(hex: start), Color(hex: end))
    }

    static func paletteHex(for seed: UUID) -> (UInt32, UInt32) {
        // FNV-1a over all 16 bytes.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        withUnsafeBytes(of: seed.uuid) { bytes in
            for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        }
        return palettes[Int(hash % UInt64(palettes.count))]
    }

    static let palettes: [(UInt32, UInt32)] = [
        (0x6F7FD6, 0x7EC3E6),
        (0xF8B4D9, 0xE46FE0),
        (0xFF2FC8, 0x6A2BE6),
        (0xFFB199, 0xFF4E6A),
        (0x5EE7B0, 0x2BB5D8),
        (0xFAD961, 0xF7731C),
        (0xA18CD1, 0xFBC2EB),
        (0x30CFD0, 0x3A2A8C),
        (0xF093FB, 0xF5576C),
        (0x4FACFE, 0x6D5CF6),
        (0xC471F5, 0xFA71CD),
        (0xFDCB82, 0xF37676),
    ]
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
