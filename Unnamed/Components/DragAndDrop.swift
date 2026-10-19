import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UnnamedKit

extension UTType {
    /// A track dragged within the app. Declared in Info.plist.
    nonisolated static let unnamedTrack = UTType(exportedAs: "com.michaeldooley.unnamed.track-reference")
}

/// What was dropped: tracks dragged from inside the app, or files from Finder.
struct DropPayload {
    var trackIDs: [UUID] = []
    var fileURLs: [URL] = []

    static let acceptedTypes: [UTType] = [.unnamedTrack, .fileURL]

    /// Reads a drop. Tracks win over files, because dragging a track inside
    /// the app also offers its audio file (so it can be dropped in Finder).
    static func load(from providers: [NSItemProvider], expandingFolders: Bool = true) async -> DropPayload {
        var payload = DropPayload()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.unnamedTrack.identifier) {
                if let id = await loadTrackID(provider) { payload.trackIDs.append(id) }
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
    nonisolated private static func loadTrackID(_ provider: NSItemProvider) async -> UUID? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.unnamedTrack.identifier) { data, _ in
                continuation.resume(returning: data.flatMap { UUID(uuidString: String(decoding: $0, as: UTF8.self)) })
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
        provider.registerDataRepresentation(forTypeIdentifier: UTType.unnamedTrack.identifier, visibility: .ownProcess) { completion in
            completion(Data(trackID.uuidString.utf8), nil)
            return nil
        }
        return provider
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
