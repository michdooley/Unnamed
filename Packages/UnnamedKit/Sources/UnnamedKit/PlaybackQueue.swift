import Foundation

public enum RepeatMode: String, Sendable, CaseIterable {
    case off, all, one

    public var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// The play order, separate from the audio engine so the rules for shuffle,
/// repeat and "Add to queue" can be tested on their own.
public struct PlaybackQueue: Sendable, Equatable {
    /// The tracks in their natural order (e.g. a collection's order).
    public private(set) var baseOrder: [UUID] = []
    /// The order tracks will actually play in (shuffled when shuffle is on).
    public private(set) var order: [UUID] = []
    /// Position in `order` of the most recent track played from it.
    public private(set) var index: Int?
    /// Tracks added with "Add to queue"; they play next, before `order` continues.
    public private(set) var upNext: [UUID] = []
    public private(set) var current: UUID?
    public var repeatMode: RepeatMode = .off
    public private(set) var shuffle = false

    public init() {}

    /// Replaces the queue, starting at `start` (or the first track; a random
    /// one when shuffling). `inOrder` plays it as given even with shuffle on
    /// (a moodboard's journey has its own order).
    public mutating func load(_ trackIDs: [UUID], startAt start: UUID? = nil, inOrder: Bool = false) {
        baseOrder = trackIDs
        upNext = []
        if shuffle, !inOrder {
            var rest = trackIDs.shuffled()
            if let start, let i = rest.firstIndex(of: start) {
                rest.remove(at: i)
                rest.insert(start, at: 0)
            }
            order = rest
            index = order.isEmpty ? nil : 0
        } else {
            order = trackIDs
            index = order.isEmpty ? nil : (start.flatMap { order.firstIndex(of: $0) } ?? 0)
        }
        current = index.map { order[$0] }
    }

    public mutating func setShuffle(_ enabled: Bool) {
        guard enabled != shuffle else { return }
        shuffle = enabled
        if enabled {
            var rest = baseOrder.shuffled()
            if let current, let i = rest.firstIndex(of: current) {
                rest.remove(at: i)
                rest.insert(current, at: 0)
                order = rest
                index = 0
            } else {
                order = rest
                index = nil
            }
        } else {
            order = baseOrder
            index = current.flatMap { order.firstIndex(of: $0) }
        }
    }

    /// Moves to the next track. `automatic` is true when the previous track
    /// finished on its own (repeat-one only applies then). Returns nil at the end.
    public mutating func advance(automatic: Bool) -> UUID? {
        if automatic, repeatMode == .one, let current {
            return current
        }
        if !upNext.isEmpty {
            current = upNext.removeFirst()
            return current
        }
        let nextIndex = (index ?? -1) + 1
        if nextIndex < order.count {
            index = nextIndex
        } else if repeatMode != .off, !order.isEmpty {
            if shuffle {
                var reshuffled = baseOrder.shuffled()
                // Avoid playing the same track twice in a row across the wrap.
                if reshuffled.count > 1, reshuffled.first == current {
                    reshuffled.swapAt(0, reshuffled.count - 1)
                }
                order = reshuffled
            }
            index = 0
        } else {
            return nil
        }
        current = index.map { order[$0] }
        return current
    }

    /// Moves to the previous track. Returns nil when already at the start.
    public mutating func goBack() -> UUID? {
        guard let i = index, !order.isEmpty else { return nil }
        if current != order[i] {
            // We were playing an "up next" track; go back to the queue position.
            current = order[i]
            return current
        }
        if i > 0 {
            index = i - 1
        } else if repeatMode != .off {
            index = order.count - 1
        } else {
            return nil
        }
        current = index.map { order[$0] }
        return current
    }

    public mutating func enqueue(_ trackID: UUID) {
        upNext.append(trackID)
    }

    /// Plays a specific track from the current order (e.g. clicking a row).
    public mutating func jump(to trackID: UUID) -> Bool {
        guard let i = order.firstIndex(of: trackID) else { return false }
        index = i
        current = trackID
        return true
    }

    /// Drops tracks that no longer exist.
    public mutating func remove(_ trackID: UUID) {
        baseOrder.removeAll { $0 == trackID }
        upNext.removeAll { $0 == trackID }
        if let i = order.firstIndex(of: trackID) {
            order.remove(at: i)
            if let position = index, i <= position {
                // Step back so the next advance lands on whatever slid into place.
                index = position > 0 ? position - 1 : nil
            }
            if order.isEmpty { index = nil }
        }
    }

    public mutating func clear() {
        self = PlaybackQueue()
    }
}
