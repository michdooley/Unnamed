import Foundation

/// The folder structure of a library. See `docs/LIBRARY_FORMAT.md`.
///
/// ```
/// <Library>/
///   library.json
///   Collections/<uuid>/collection.json, artwork-*.jpg
///   Tracks/<uuid>/track.json, <audio file>, artwork-*.jpg,
///                 waveform.json, notes.md, Comments/<uuid>.json
/// ```
public struct LibraryLayout: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    var manifestFile: URL { root.appending(path: "library.json", directoryHint: .notDirectory) }
    var readmeFile: URL { root.appending(path: "README.txt", directoryHint: .notDirectory) }
    var collectionsDir: URL { root.appending(path: "Collections", directoryHint: .isDirectory) }
    var tracksDir: URL { root.appending(path: "Tracks", directoryHint: .isDirectory) }

    func collectionDir(_ id: UUID) -> URL {
        collectionsDir.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func collectionFile(_ id: UUID) -> URL {
        collectionDir(id).appending(path: "collection.json", directoryHint: .notDirectory)
    }

    func trackDir(_ id: UUID) -> URL {
        tracksDir.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func trackFile(_ id: UUID) -> URL {
        trackDir(id).appending(path: "track.json", directoryHint: .notDirectory)
    }

    func notesFile(_ id: UUID) -> URL {
        trackDir(id).appending(path: "notes.md", directoryHint: .notDirectory)
    }

    func waveformFile(_ id: UUID) -> URL {
        trackDir(id).appending(path: "waveform.json", directoryHint: .notDirectory)
    }

    func commentsDir(_ trackID: UUID) -> URL {
        trackDir(trackID).appending(path: "Comments", directoryHint: .isDirectory)
    }

    func commentFile(trackID: UUID, commentID: UUID) -> URL {
        commentsDir(trackID).appending(path: "\(commentID.uuidString).json", directoryHint: .notDirectory)
    }

    public func audioURL(for track: Track) -> URL? {
        track.audioFileName.map { trackDir(track.id).appending(path: $0, directoryHint: .notDirectory) }
    }

    public func artworkURL(for track: Track) -> URL? {
        track.artworkFileName.map { trackDir(track.id).appending(path: $0, directoryHint: .notDirectory) }
    }

    public func artworkURL(for collection: TrackCollection) -> URL? {
        collection.artworkFileName.map { collectionDir(collection.id).appending(path: $0, directoryHint: .notDirectory) }
    }
}

enum LibraryJSON {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Makes a string safe to use as a file name on every platform iCloud syncs to.
func sanitizedFileName(_ name: String, fallback: String = "Untitled") -> String {
    let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
    var cleaned = name.components(separatedBy: illegal).joined(separator: "-")
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    while cleaned.hasPrefix(".") { cleaned.removeFirst() }
    if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)) }
    return cleaned.isEmpty ? fallback : cleaned
}
