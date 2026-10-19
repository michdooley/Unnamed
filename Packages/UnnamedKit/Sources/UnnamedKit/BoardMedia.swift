import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks pictures and videos before they go on a board (and into iCloud):
/// images become HEIC (JPEG where HEIC can't be written) no larger than
/// 2048 px, videos become HEVC no larger than 1080p.
public enum BoardMedia {
    public static let maxImagePixels = 2048

    public struct EncodedImage: Sendable {
        public var data: Data
        /// "heic" or "jpg".
        public var fileExtension: String
        public var pixelSize: CGSize
    }

    public static func isImage(_ url: URL) -> Bool {
        (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) ?? false
    }

    public static func isVideo(_ url: URL) -> Bool {
        (UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie)) ?? false
    }

    public static func encodeImage(at url: URL) throws -> EncodedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CocoaError(.fileReadCorruptFile) }
        return try encodeImage(source)
    }

    public static func encodeImage(data: Data) throws -> EncodedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CocoaError(.fileReadCorruptFile) }
        return try encodeImage(source)
    }

    private static func encodeImage(_ source: CGImageSource) throws -> EncodedImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let size = CGSize(width: image.width, height: image.height)
        if let data = encode(image, as: .heic, quality: 0.72) {
            return EncodedImage(data: data, fileExtension: "heic", pixelSize: size)
        }
        if let data = encode(image, as: .jpeg, quality: 0.82) {
            return EncodedImage(data: data, fileExtension: "jpg", pixelSize: size)
        }
        throw CocoaError(.fileWriteUnknown)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return data as Data
    }

    /// Re-encodes a video as HEVC (H.264 where HEVC isn't available), at most
    /// 1080p (720p as a last resort), into `destination` (a .mov). Returns the
    /// size it displays at.
    public static func encodeVideo(at url: URL, to destination: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        try? FileManager.default.removeItem(at: destination)
        var exported = false
        for preset in [AVAssetExportPresetHEVC1920x1080, AVAssetExportPreset1920x1080, AVAssetExportPreset1280x720] {
            guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: .mov),
                  let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.shouldOptimizeForNetworkUse = true
            do {
                try await session.export(to: destination, as: .mov)
                exported = true
                break
            } catch {
                try? FileManager.default.removeItem(at: destination)
            }
        }
        guard exported else { throw CocoaError(.fileWriteUnknown) }
        return try await displaySize(of: AVURLAsset(url: destination))
    }

    /// A video's size as shown (its track size, turned by its transform).
    public static func displaySize(of asset: AVAsset) async throws -> CGSize {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return CGSize(width: 16, height: 9) }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let turned = natural.applying(transform)
        return CGSize(width: abs(turned.width), height: abs(turned.height))
    }
}
