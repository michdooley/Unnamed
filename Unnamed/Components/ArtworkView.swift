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
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: url) {
                loaded = nil
                guard let url else { return }
                // The image may still be syncing down from iCloud; retry briefly.
                for attempt in 0..<6 {
                    if let image = await ArtworkCache.shared.image(for: url, pixelSize: pixelSize) {
                        loaded = image
                        return
                    }
                    try? await Task.sleep(for: .seconds(Double(attempt + 1) * 2))
                    if Task.isCancelled { return }
                }
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
        // FNV-1a over all 16 bytes.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        withUnsafeBytes(of: seed.uuid) { bytes in
            for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        }
        return palettes[Int(hash % UInt64(palettes.count))]
    }

    static let palettes: [(Color, Color)] = [
        (Color(hex: 0x6F7FD6), Color(hex: 0x7EC3E6)),
        (Color(hex: 0xF8B4D9), Color(hex: 0xE46FE0)),
        (Color(hex: 0xFF2FC8), Color(hex: 0x6A2BE6)),
        (Color(hex: 0xFFB199), Color(hex: 0xFF4E6A)),
        (Color(hex: 0x5EE7B0), Color(hex: 0x2BB5D8)),
        (Color(hex: 0xFAD961), Color(hex: 0xF7731C)),
        (Color(hex: 0xA18CD1), Color(hex: 0xFBC2EB)),
        (Color(hex: 0x30CFD0), Color(hex: 0x3A2A8C)),
        (Color(hex: 0xF093FB), Color(hex: 0xF5576C)),
        (Color(hex: 0x4FACFE), Color(hex: 0x6D5CF6)),
        (Color(hex: 0xC471F5), Color(hex: 0xFA71CD)),
        (Color(hex: 0xFDCB82), Color(hex: 0xF37676)),
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
