import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UnnamedKit

extension UTType {
    /// A track, collection or folder dragged within the app. Declared in Info.plist.
    nonisolated static let unnamedItem = UTType(exportedAs: "com.michaeldooley.unnamed.item-reference")
}

/// Something in the library that can be dragged around inside the app.
enum LibraryItemRef: Hashable, Sendable {
    case track(UUID)
    case collection(UUID)
    case folder(UUID)

    /// "track:<uuid>" etc.
    nonisolated var encoded: String {
        switch self {
        case .track(let id): "track:\(id.uuidString)"
        case .collection(let id): "collection:\(id.uuidString)"
        case .folder(let id): "folder:\(id.uuidString)"
        }
    }

    nonisolated init?(encoded: String) {
        let parts = encoded.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "track": self = .track(id)
        case "collection": self = .collection(id)
        case "folder": self = .folder(id)
        default: return nil
        }
    }
}

/// What was dropped: items dragged from inside the app, or files from Finder.
struct DropPayload {
    var items: [LibraryItemRef] = []
    var fileURLs: [URL] = []

    var trackIDs: [UUID] {
        items.compactMap { if case .track(let id) = $0 { id } else { nil } }
    }

    static let acceptedTypes: [UTType] = [.unnamedItem, .fileURL]

    /// Reads a drop. In-app items win over files, because dragging a track
    /// also offers its audio file (so it can be dropped in Finder).
    static func load(from providers: [NSItemProvider], expandingFolders: Bool = true) async -> DropPayload {
        var payload = DropPayload()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.unnamedItem.identifier) {
                if let item = await loadItem(provider) { payload.items.append(item) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await loadFileURL(provider) { payload.fileURLs.append(url) }
            }
        }
        if expandingFolders {
            payload.fileURLs = expandFolders(payload.fileURLs).filter(AudioAnalyzer.isAudioFile)
        }
        return payload
    }

    /// Reads an image dropped onto cover art: an image file or raw image data.
    static func loadArtwork(from providers: [NSItemProvider]) async -> LibraryStore.ArtworkSource? {
        guard let provider = providers.first else { return nil }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadFileURL(provider),
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            return .file(url)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return await loadImageData(provider).map { .data($0) }
        }
        return nil
    }

    nonisolated private static func loadImageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    // NSItemProvider calls back on background queues, so these loaders are
    // nonisolated (app code is main-actor by default).
    nonisolated private static func loadItem(_ provider: NSItemProvider) async -> LibraryItemRef? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.unnamedItem.identifier) { data, _ in
                continuation.resume(returning: data.flatMap { LibraryItemRef(encoded: String(decoding: $0, as: UTF8.self)) })
            }
        }
    }

    nonisolated private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    /// Replaces dropped folders with the audio files inside them.
    static func expandFolders(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [url] }
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let files = (enumerator?.allObjects as? [URL] ?? []).filter(AudioAnalyzer.isAudioFile)
            return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }
}

extension NSItemProvider {
    /// Drag source for a track: our own type for in-app moves, plus the audio
    /// file so it can be dropped into Finder or a DAW.
    nonisolated static func forTrack(_ trackID: UUID, audioURL: URL?, title: String) -> NSItemProvider {
        let provider = audioURL.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        provider.suggestedName = title
        provider.register(.track(trackID))
        return provider
    }

    /// Drag source for a collection or folder (in-app only).
    nonisolated static func forItem(_ item: LibraryItemRef, title: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = title
        provider.register(item)
        return provider
    }

    nonisolated private func register(_ item: LibraryItemRef) {
        let data = Data(item.encoded.utf8)
        registerDataRepresentation(forTypeIdentifier: UTType.unnamedItem.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
    }
}

/// A drop target highlight used across views.
struct DropHighlight: ViewModifier {
    var isTargeted: Bool
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content.overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func dropHighlight(_ isTargeted: Bool, cornerRadius: CGFloat = 12) -> some View {
        modifier(DropHighlight(isTargeted: isTargeted, cornerRadius: cornerRadius))
    }
}
