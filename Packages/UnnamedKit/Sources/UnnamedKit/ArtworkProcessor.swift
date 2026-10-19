import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales imported artwork to a sensible size and re-encodes it as JPEG,
/// so a 40 MB photo doesn't get synced to every device.
public enum ArtworkProcessor {
    public static let maxPixelSize = 1400

    public static func jpegData(fromImageAt url: URL, maxPixelSize: Int = maxPixelSize) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try jpegData(from: source, maxPixelSize: maxPixelSize)
    }

    public static func jpegData(fromImageData data: Data, maxPixelSize: Int = maxPixelSize) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try jpegData(from: source, maxPixelSize: maxPixelSize)
    }

    /// Loads a downsampled CGImage, used by the UI for thumbnails.
    public static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(maxPixelSize))
    }

    private static func thumbnailOptions(_ maxPixelSize: Int) -> CFDictionary {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
    }

    private static func jpegData(from source: CGImageSource, maxPixelSize: Int) throws -> Data {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(maxPixelSize)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return output as Data
    }
}
