import Foundation

/// The folder structure of a library. See `docs/LIBRARY_FORMAT.md`.
///
/// ```
/// <Library>/
///   library.json
///   Folders/<uuid>/folder.json
///   Collections/<uuid>/collection.json, artwork-*.jpg
///   Tracks/<uuid>/track.json, <audio files>, artwork-*.jpg, notes.md,
///                 Versions/<uuid>.json, Waveforms/<version>.json, Comments/<uuid>.json
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
    var foldersDir: URL { root.appending(path: "Folders", directoryHint: .isDirectory) }

    func folderDir(_ id: UUID) -> URL {
        foldersDir.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func folderFile(_ id: UUID) -> URL {
        folderDir(id).appending(path: "folder.json", directoryHint: .notDirectory)
    }

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

    /// Format 1's single waveform; still read as the first version's.
    func legacyWaveformFile(_ id: UUID) -> URL {
        trackDir(id).appending(path: "waveform.json", directoryHint: .notDirectory)
    }

    func versionsDir(_ trackID: UUID) -> URL {
        trackDir(trackID).appending(path: "Versions", directoryHint: .isDirectory)
    }

    func versionFile(trackID: UUID, versionID: UUID) -> URL {
        versionsDir(trackID).appending(path: "\(versionID.uuidString).json", directoryHint: .notDirectory)
    }

    func waveformsDir(_ trackID: UUID) -> URL {
        trackDir(trackID).appending(path: "Waveforms", directoryHint: .isDirectory)
    }

    func waveformFile(trackID: UUID, versionID: UUID) -> URL {
        waveformsDir(trackID).appending(path: "\(versionID.uuidString).json", directoryHint: .notDirectory)
    }

    func commentsDir(_ trackID: UUID) -> URL {
        trackDir(trackID).appending(path: "Comments", directoryHint: .isDirectory)
    }

    func commentFile(trackID: UUID, commentID: UUID) -> URL {
        commentsDir(trackID).appending(path: "\(commentID.uuidString).json", directoryHint: .notDirectory)
    }

    /// The audio of a version (the current one when `versionID` is nil).
    public func audioURL(for track: Track, version versionID: UUID? = nil) -> URL? {
        track.version(versionID).map { trackDir(track.id).appending(path: $0.audioFileName, directoryHint: .notDirectory) }
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
