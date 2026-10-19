import Foundation

/// Archiving: a middle ground between keeping something in view and deleting
/// it. Archived items are hidden from the library's lists but nothing moves,
/// so restoring puts them back exactly where they were (same folder, same
/// collections, same position).
extension LibraryStore {
    public func setArchived(_ archived: Bool, track id: UUID) {
        updateTrack(id) { $0.archivedAt = archived ? ($0.archivedAt ?? .libraryNow) : nil }
    }

    public func setArchived(_ archived: Bool, collection id: UUID) {
        updateCollection(id) { $0.archivedAt = archived ? ($0.archivedAt ?? .libraryNow) : nil }
    }

    /// Archiving a folder hides everything inside it too.
    public func setArchived(_ archived: Bool, folder id: UUID) {
        updateFolderArchive(id, archived)
    }

    // MARK: - Queries

    /// Whether a folder, or a folder it's inside, is archived.
    public func isArchived(folder id: UUID) -> Bool {
        folderPath(to: id).contains { $0.archivedAt != nil }
    }

    /// Whether a collection is archived, or sits in an archived folder.
    public func isArchived(collection id: UUID) -> Bool {
        guard let collection = collections[id] else { return false }
        if collection.archivedAt != nil { return true }
        return folder(ofCollection: id).map { isArchived(folder: $0) } ?? false
    }

    /// Whether a track is out of sight: archived itself, or every collection
    /// it's in is archived.
    public func isHidden(track id: UUID) -> Bool {
        guard let track = tracks[id] else { return true }
        if track.archivedAt != nil { return true }
        let memberships = collections(containing: id)
        return !memberships.isEmpty && memberships.allSatisfy { isArchived(collection: $0.id) }
    }

    /// Whether taking a track out of a collection still leaves it somewhere
    /// you can see it (or, for a collection in the archive, somewhere at all).
    public func canRemove(track id: UUID, from collectionID: UUID) -> Bool {
        let others = collections(containing: id).filter { $0.id != collectionID }
        if others.contains(where: { !isArchived(collection: $0.id) }) { return true }
        return isArchived(collection: collectionID) && !others.isEmpty
    }

    /// Tracks that aren't archived or tucked away in archived collections, newest first.
    public var activeTracksNewestFirst: [Track] {
        tracksNewestFirst.filter { !isHidden(track: $0.id) }
    }

    /// Archived folders, outermost only (ones inside them come along), newest first.
    public var archivedFolders: [LibraryFolder] {
        folders.values
            .filter { $0.archivedAt != nil && !(parentFolder(of: $0.id).map { isArchived(folder: $0) } ?? false) }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    /// Archived collections that aren't inside an archived folder, newest first.
    public var archivedCollections: [TrackCollection] {
        collections.values
            .filter { $0.archivedAt != nil && !(folder(ofCollection: $0.id).map { isArchived(folder: $0) } ?? false) }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    /// Tracks archived on their own, newest first.
    public var archivedTracks: [Track] {
        tracks.values
            .filter { $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    /// How many things are archived (counting a folder's contents as one).
    public var archivedCount: Int {
        archivedFolders.count + archivedCollections.count + archivedTracks.count
    }
}
