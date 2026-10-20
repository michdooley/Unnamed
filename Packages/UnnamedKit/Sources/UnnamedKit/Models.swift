import Foundation

/// One take of a track's audio. A track keeps every version it's had, so
/// "upload a new version" never loses the old one.
///
/// Each version is its own file (`Tracks/<track>/Versions/<id>.json`), so
/// an edit to the track on one device can never erase a version added on another.
public struct TrackVersion: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// File name of the audio inside the track's folder.
    public var audioFileName: String
    /// Name of the file as it was originally imported.
    public var originalFileName: String?
    /// Duration in seconds (0 until analysed).
    public var duration: TimeInterval
    public var createdAt: Date
    /// Optional label like "rough mix" or "new vocal".
    public var name: String?
    /// What the app heard in this version's audio (see `MusicAnalyzer`),
    /// and when it listened. Nil values with a date mean it couldn't tell.
    public var detectedBPM: Double?
    public var detectedKey: String?
    public var detectedAt: Date?

    public init(
        id: UUID = UUID(),
        audioFileName: String,
        originalFileName: String? = nil,
        duration: TimeInterval = 0,
        createdAt: Date = .libraryNow,
        name: String? = nil
    ) {
        self.id = id
        self.audioFileName = audioFileName
        self.originalFileName = originalFileName
        self.duration = duration
        self.createdAt = createdAt
        self.name = name
    }
}

extension TrackVersion: Codable {
    enum CodingKeys: String, CodingKey {
        case id, audioFile, originalFileName, duration, createdAt, name, detectedBPM, detectedKey, detectedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        audioFileName = try c.decode(String.self, forKey: .audioFile)
        originalFileName = try c.decodeIfPresent(String.self, forKey: .originalFileName)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        name = try c.decodeIfPresent(String.self, forKey: .name)
        detectedBPM = try? c.decodeIfPresent(Double.self, forKey: .detectedBPM)
        detectedKey = try? c.decodeIfPresent(String.self, forKey: .detectedKey)
        detectedAt = try? c.decodeIfPresent(Date.self, forKey: .detectedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(audioFileName, forKey: .audioFile)
        try c.encodeIfPresent(originalFileName, forKey: .originalFileName)
        try c.encode(duration, forKey: .duration)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(detectedBPM, forKey: .detectedBPM)
        try c.encodeIfPresent(detectedKey, forKey: .detectedKey)
        try c.encodeIfPresent(detectedAt, forKey: .detectedAt)
    }
}

extension TrackVersion {
    /// Oldest first; ties (same second, e.g. from two devices) break by ID so
    /// every device numbers versions the same way.
    static func order(_ a: TrackVersion, _ b: TrackVersion) -> Bool {
        a.createdAt == b.createdAt ? a.id.uuidString < b.id.uuidString : a.createdAt < b.createdAt
    }
}

/// A single music idea: its audio versions plus metadata. Every track lives
/// in at least one collection; folders organise collections, not tracks.
///
/// Stored on disk as `Tracks/<id>/track.json`. Notes, comments and waveforms
/// live in sibling files so that edits on two devices rarely touch the same file.
public struct Track: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Every version of the audio, oldest first. Loaded from `Versions/`, not track.json.
    public var versions: [TrackVersion]
    /// The version that plays by default.
    public var currentVersionID: UUID?
    /// File name of the artwork inside the track's folder, if any.
    public var artworkFileName: String?
    /// Who to credit for the artwork, when it came from Unsplash.
    public var artworkCredit: ArtworkCredit?
    public var bpm: Double?
    public var musicalKey: String?
    /// When the track was archived (hidden but kept), if it is.
    public var archivedAt: Date?

    /// Creates a track with a single version whose ID matches the track's.
    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .libraryNow,
        updatedAt: Date = .libraryNow,
        audioFileName: String? = nil,
        originalFileName: String? = nil,
        duration: TimeInterval = 0,
        artworkFileName: String? = nil,
        bpm: Double? = nil,
        musicalKey: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        if let audioFileName {
            versions = [TrackVersion(id: id, audioFileName: audioFileName, originalFileName: originalFileName, duration: duration, createdAt: createdAt)]
            currentVersionID = id
        } else {
            versions = []
            currentVersionID = nil
        }
        self.artworkFileName = artworkFileName
        self.bpm = bpm
        self.musicalKey = musicalKey
    }

    /// The version that plays by default (the newest if the ID is unknown).
    public var currentVersion: TrackVersion? {
        version(nil)
    }

    /// A specific version, or the current one when `id` is nil.
    public func version(_ id: UUID?) -> TrackVersion? {
        let wanted = id ?? currentVersionID
        return versions.first { $0.id == wanted } ?? (id == nil ? versions.last : nil)
    }

    /// 1-based position of a version ("v2").
    public func versionNumber(of id: UUID) -> Int? {
        versions.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// "v2" or "v2 · new vocal".
    public func versionLabel(of id: UUID) -> String {
        guard let number = versionNumber(of: id) else { return "" }
        if let name = version(id)?.name, !name.isEmpty { return "v\(number) · \(name)" }
        return "v\(number)"
    }

    public var audioFileName: String? { currentVersion?.audioFileName }
    public var originalFileName: String? { currentVersion?.originalFileName }
    public var duration: TimeInterval { currentVersion?.duration ?? 0 }
}

extension Track: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, audioFile, originalFileName, duration, artworkFile, bpm, key
        case versions, currentVersion, artworkCredit, archivedAt
    }

    // Lenient decoding: every field is optional on disk so files written by
    // older or newer versions of the app still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        artworkFileName = try c.decodeIfPresent(String.self, forKey: .artworkFile)
        artworkCredit = try? c.decodeIfPresent(ArtworkCredit.self, forKey: .artworkCredit)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm)
        musicalKey = try c.decodeIfPresent(String.self, forKey: .key)

        // Versions normally come from their own files (the scanner fills them
        // in). A track without any is format 1: its single audio file becomes
        // version 1. The scanner gives it the track folder's ID, which every
        // device derives identically.
        let current = try? c.decodeIfPresent(UUID.self, forKey: .currentVersion)
        var versions = (try? c.decodeIfPresent([TrackVersion].self, forKey: .versions)) ?? []
        if versions.isEmpty, let audioFile = try c.decodeIfPresent(String.self, forKey: .audioFile) {
            // The top-level fields mirror the current version, so if one is
            // named (format 2, version files still syncing) use its ID.
            versions = [TrackVersion(
                id: current ?? id,
                audioFileName: audioFile,
                originalFileName: try c.decodeIfPresent(String.self, forKey: .originalFileName),
                duration: try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0,
                createdAt: createdAt
            )]
        }
        self.versions = versions
        currentVersionID = versions.contains { $0.id == current } ? current : versions.last?.id
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(currentVersionID, forKey: .currentVersion)
        // The current version is mirrored at the top level so format-1 readers
        // still find and play it.
        try c.encodeIfPresent(audioFileName, forKey: .audioFile)
        try c.encodeIfPresent(originalFileName, forKey: .originalFileName)
        try c.encode(duration, forKey: .duration)
        try c.encodeIfPresent(artworkFileName, forKey: .artworkFile)
        try c.encodeIfPresent(artworkCredit, forKey: .artworkCredit)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try c.encodeIfPresent(bpm, forKey: .bpm)
        try c.encodeIfPresent(musicalKey, forKey: .key)
    }
}

/// Identifies one version of one track (version IDs are only unique within a track).
public struct VersionKey: Hashable, Sendable {
    public var track: UUID
    public var version: UUID

    public init(track: UUID, version: UUID) {
        self.track = track
        self.version = version
    }
}

/// A folder for organising collections: it holds other folders and collections.
///
/// Folders form a tree. Each item records its own parent (`folder` in its
/// JSON), so moving things around only rewrites the item that moved. Stored
/// as `Folders/<id>/folder.json`.
public struct LibraryFolder: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var parentID: UUID?
    /// When the folder was archived (hidden with everything in it), if it is.
    public var archivedAt: Date?

    public init(id: UUID = UUID(), title: String, createdAt: Date = .libraryNow, updatedAt: Date = .libraryNow, parentID: UUID? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.parentID = parentID
    }
}

extension LibraryFolder: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, parent, archivedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Folder"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parent)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(parentID, forKey: .parent)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
    }
}

/// An ordered set of tracks — an album, an EP, a mixtape, a folder of sketches.
///
/// A track can appear in any number of collections. Stored on disk as
/// `Collections/<id>/collection.json`.
public struct TrackCollection: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var trackIDs: [UUID]
    public var artworkFileName: String?
    /// Who to credit for the cover, when it came from Unsplash.
    public var artworkCredit: ArtworkCredit?
    public var folderID: UUID?
    /// When the collection was archived (hidden but kept), if it is.
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .libraryNow,
        updatedAt: Date = .libraryNow,
        trackIDs: [UUID] = [],
        artworkFileName: String? = nil,
        folderID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.trackIDs = trackIDs
        self.artworkFileName = artworkFileName
        self.folderID = folderID
    }
}

extension TrackCollection: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, tracks, artworkFile, artworkCredit, folder, archivedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        trackIDs = try c.decodeIfPresent([UUID].self, forKey: .tracks) ?? []
        artworkFileName = try c.decodeIfPresent(String.self, forKey: .artworkFile)
        artworkCredit = try? c.decodeIfPresent(ArtworkCredit.self, forKey: .artworkCredit)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folder)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(trackIDs, forKey: .tracks)
        try c.encodeIfPresent(artworkFileName, forKey: .artworkFile)
        try c.encodeIfPresent(artworkCredit, forKey: .artworkCredit)
        try c.encodeIfPresent(folderID, forKey: .folder)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
    }
}

/// A comment pinned to a moment in a track, SoundCloud style.
///
/// Each comment is its own file (`Tracks/<track>/Comments/<id>.json`) so two
/// devices adding comments at the same time never conflict.
public struct TrackComment: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    /// Position in the track, in seconds.
    public var timestamp: TimeInterval
    public var text: String
    public var createdAt: Date
    public var author: String?
    /// The version the comment was made on. Comments from before versions
    /// existed have none and belong to the first version.
    public var versionID: UUID?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, text, createdAt, author
        case versionID = "version"
    }

    public init(id: UUID = UUID(), timestamp: TimeInterval, text: String, createdAt: Date = .libraryNow, author: String? = nil, versionID: UUID? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.createdAt = createdAt
        self.author = author
        self.versionID = versionID
    }
}

/// Where a track's audio file lives relative to iCloud.
public enum CloudStatus: Hashable, Sendable {
    /// The library is not in iCloud Drive; the file is simply on disk.
    case local
    /// In iCloud and fully downloaded.
    case downloaded
    /// In iCloud but only a placeholder is on this device.
    case notDownloaded
    case downloading
    case uploading
    /// The file is referenced but doesn't exist (yet). Usually still syncing.
    case missing

    public var isPlayableWithoutDownload: Bool {
        switch self {
        case .local, .downloaded, .uploading: true
        case .notDownloaded, .downloading, .missing: false
        }
    }
}

/// The marker file at the root of every library folder.
struct LibraryManifest: Codable, Sendable {
    var format: String = "unnamed-library"
    var version: Int = 2
    var createdAt: Date = .libraryNow
}

/// On-disk representation of a track's waveform overview.
struct WaveformFile: Codable, Sendable {
    var version: Int = 1
    var peaks: [UInt8]
}

extension Date {
    /// Now, truncated to whole seconds. Library files store ISO-8601 dates
    /// without fractions, so this keeps in-memory values identical to what a
    /// reload reads back.
    public static var libraryNow: Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }
}
