import Foundation

/// A single music idea: one audio file plus its metadata.
///
/// Stored on disk as `Tracks/<id>/track.json`. Notes, comments and the
/// waveform live in sibling files so that edits on two devices rarely
/// touch the same file.
public struct Track: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// File name of the audio inside the track's folder.
    public var audioFileName: String?
    /// Name of the file as it was originally imported.
    public var originalFileName: String?
    /// Duration in seconds (0 until analysed).
    public var duration: TimeInterval
    /// File name of the artwork inside the track's folder, if any.
    public var artworkFileName: String?
    public var bpm: Double?
    public var musicalKey: String?

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
        self.audioFileName = audioFileName
        self.originalFileName = originalFileName
        self.duration = duration
        self.artworkFileName = artworkFileName
        self.bpm = bpm
        self.musicalKey = musicalKey
    }
}

extension Track: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, audioFile, originalFileName, duration, artworkFile, bpm, key
    }

    // Lenient decoding: every field is optional on disk so files written by
    // older or newer versions of the app still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFile)
        originalFileName = try c.decodeIfPresent(String.self, forKey: .originalFileName)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        artworkFileName = try c.decodeIfPresent(String.self, forKey: .artworkFile)
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm)
        musicalKey = try c.decodeIfPresent(String.self, forKey: .key)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(audioFileName, forKey: .audioFile)
        try c.encodeIfPresent(originalFileName, forKey: .originalFileName)
        try c.encode(duration, forKey: .duration)
        try c.encodeIfPresent(artworkFileName, forKey: .artworkFile)
        try c.encodeIfPresent(bpm, forKey: .bpm)
        try c.encodeIfPresent(musicalKey, forKey: .key)
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

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .libraryNow,
        updatedAt: Date = .libraryNow,
        trackIDs: [UUID] = [],
        artworkFileName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.trackIDs = trackIDs
        self.artworkFileName = artworkFileName
    }
}

extension TrackCollection: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, tracks, artworkFile
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        trackIDs = try c.decodeIfPresent([UUID].self, forKey: .tracks) ?? []
        artworkFileName = try c.decodeIfPresent(String.self, forKey: .artworkFile)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(trackIDs, forKey: .tracks)
        try c.encodeIfPresent(artworkFileName, forKey: .artworkFile)
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

    public init(id: UUID = UUID(), timestamp: TimeInterval, text: String, createdAt: Date = .libraryNow, author: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.createdAt = createdAt
        self.author = author
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
    var version: Int = 1
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
