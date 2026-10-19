import Foundation

// A collection's moodboard: an infinite canvas where its songs are laid out as
// threads (a song's time runs along its thread), next to images, videos, text
// and drawings. Stored as one small JSON file per item in the collection's
// Moodboard folder, so edits on two devices rarely touch the same file.
// See docs/LIBRARY_FORMAT.md.

/// A point on a board, in board units (a point at 100% zoom). Coded as `[x, y]`.
public struct BoardPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = BoardPoint(0, 0)

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        // Two decimals is plenty, and keeps the files small and diffable.
        try container.encode((x * 100).rounded() / 100)
        try container.encode((y * 100).rounded() / 100)
    }

    public static func + (a: BoardPoint, b: BoardPoint) -> BoardPoint { BoardPoint(a.x + b.x, a.y + b.y) }
    public static func - (a: BoardPoint, b: BoardPoint) -> BoardPoint { BoardPoint(a.x - b.x, a.y - b.y) }
}

/// One thing on a board.
public struct BoardItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A song, drawn as a thread with its waveform along it.
        case track
        case image
        case video
        case text
        /// A freehand pen stroke.
        case drawing
    }

    public var id: UUID
    public var kind: Kind
    /// Tracks: where the thread starts. Everything else: the top-left corner.
    public var position: BoardPoint
    /// Stacking order (higher is in front).
    public var z: Double
    /// Images, videos: size. Text: wrapping width (height follows the text).
    public var width: Double?
    public var height: Double?
    /// Tracks: which song.
    public var trackID: UUID?
    /// Tracks: the thread's knots, relative to `position`; the first is (0, 0).
    public var thread: [BoardPoint]?
    /// Images, videos: the file in the board's Media folder.
    public var file: String?
    public var text: String?
    public var fontSize: Double?
    /// Text, drawings: "#RRGGBB" (text without one contrasts with the background).
    public var color: String?
    /// Drawings: the stroke, relative to `position`.
    public var points: [BoardPoint]?
    public var lineWidth: Double?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), kind: Kind, position: BoardPoint, z: Double = 0, createdAt: Date = .libraryNow) {
        self.id = id
        self.kind = kind
        self.position = position
        self.z = z
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    /// Board units of thread per second of music, and the limits, so a short
    /// sketch and a long jam are both comfortable to pull around.
    public static let threadUnitsPerSecond = 5.0
    public static let threadLengthRange = 280.0...1400.0

    /// A song with a straight thread running right from `position`.
    public static func track(_ trackID: UUID, at position: BoardPoint, duration: TimeInterval, z: Double = 0) -> BoardItem {
        var item = BoardItem(kind: .track, position: position, z: z)
        item.trackID = trackID
        let length = min(threadLengthRange.upperBound, max(threadLengthRange.lowerBound, duration * threadUnitsPerSecond))
        item.thread = [.zero, BoardPoint(length, 0)]
        return item
    }

    /// The thread's knots on the board.
    public var threadKnots: [BoardPoint] {
        (thread ?? [.zero, BoardPoint(Self.threadLengthRange.lowerBound, 0)]).map { position + $0 }
    }
}

extension BoardItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, type, x, y, z, width, height, track, thread, file, text, fontSize, color, points, lineWidth, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .type)
        position = BoardPoint(try c.decode(Double.self, forKey: .x), try c.decode(Double.self, forKey: .y))
        z = try c.decodeIfPresent(Double.self, forKey: .z) ?? 0
        width = try c.decodeIfPresent(Double.self, forKey: .width)
        height = try c.decodeIfPresent(Double.self, forKey: .height)
        trackID = try c.decodeIfPresent(UUID.self, forKey: .track)
        thread = try c.decodeIfPresent([BoardPoint].self, forKey: .thread)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        points = try c.decodeIfPresent([BoardPoint].self, forKey: .points)
        lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .type)
        try c.encode((position.x * 100).rounded() / 100, forKey: .x)
        try c.encode((position.y * 100).rounded() / 100, forKey: .y)
        try c.encode(z, forKey: .z)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(trackID, forKey: .track)
        try c.encodeIfPresent(thread, forKey: .thread)
        try c.encodeIfPresent(file, forKey: .file)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(fontSize, forKey: .fontSize)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(points, forKey: .points)
        try c.encodeIfPresent(lineWidth, forKey: .lineWidth)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Board-wide settings (`board.json`).
public struct BoardSettings: Hashable, Sendable, Codable {
    /// "#RRGGBB".
    public var background: String
    public var updatedAt: Date

    public init(background: String = Moodboard.defaultBackground, updatedAt: Date = .distantPast) {
        self.background = background
        self.updatedAt = updatedAt
    }
}

public struct Moodboard: Hashable, Sendable {
    public var settings: BoardSettings
    public var items: [UUID: BoardItem]

    public init(settings: BoardSettings = BoardSettings(), items: [UUID: BoardItem] = [:]) {
        self.settings = settings
        self.items = items
    }

    /// A deep night violet, like the welcome screen.
    public static let defaultBackground = "#15121F"

    /// Back to front.
    public var orderedItems: [BoardItem] {
        items.values.sorted { a, b in
            if a.z != b.z { return a.z < b.z }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Where a song is on the board, if it's been placed.
    public func placement(of trackID: UUID) -> BoardItem? {
        items.values.first { $0.kind == .track && $0.trackID == trackID }
    }

    public var topZ: Double { items.values.map(\.z).max() ?? 0 }
}
