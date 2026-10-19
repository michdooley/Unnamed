import Foundation

/// Folders: a tree for organising collections and loose tracks.
///
/// Every item stores its own parent, so moves only rewrite the item that
/// moved. Because two devices can make conflicting moves while offline, the
/// queries treat a missing parent, or a parent that would form a loop, as
/// "top level" rather than trusting the stored value blindly.
extension LibraryStore {
    // MARK: - Queries

    /// A folder's parent, or nil if it's top level. Ignores parents that no
    /// longer exist or that would form a loop.
    public func parentFolder(of folderID: UUID) -> UUID? {
        guard let parent = folders[folderID]?.parentID, folders[parent] != nil else { return nil }
        var seen: Set<UUID> = []
        var cursor: UUID? = parent
        while let id = cursor {
            if id == folderID { return nil }
            if !seen.insert(id).inserted { break }
            cursor = folders[id]?.parentID
        }
        return parent
    }

    /// The folder a collection is in, if it still exists.
    public func folder(ofCollection collectionID: UUID) -> UUID? {
        collections[collectionID]?.folderID.flatMap { folders[$0] != nil ? $0 : nil }
    }

    /// The folder a track sits in directly, if it still exists.
    public func folder(ofTrack trackID: UUID) -> UUID? {
        tracks[trackID]?.folderID.flatMap { folders[$0] != nil ? $0 : nil }
    }

    /// Folders directly inside `parent` (top-level folders when nil), A–Z.
    public func subfolders(of parent: UUID?) -> [LibraryFolder] {
        folders.values
            .filter { parentFolder(of: $0.id) == parent }
            .sorted { Self.titleOrder($0.title, $0.id, $1.title, $1.id) }
    }

    /// Collections directly inside a folder (top-level collections when nil), A–Z.
    public func collections(inFolder folderID: UUID?) -> [TrackCollection] {
        collections.values
            .filter { folder(ofCollection: $0.id) == folderID }
            .sorted { Self.titleOrder($0.title, $0.id, $1.title, $1.id) }
    }

    /// Tracks placed directly in a folder, newest first.
    public func looseTracks(inFolder folderID: UUID) -> [Track] {
        tracksNewestFirst.filter { folder(ofTrack: $0.id) == folderID }
    }

    /// The folders from the top level down to `folderID`, inclusive.
    public func folderPath(to folderID: UUID) -> [LibraryFolder] {
        var path: [LibraryFolder] = []
        var cursor: UUID? = folderID
        while let id = cursor, let folder = folders[id], path.count < folders.count {
            path.insert(folder, at: 0)
            cursor = parentFolder(of: id)
        }
        return path
    }

    /// Whether `folderID` is `ancestorID` or somewhere inside it.
    public func isFolder(_ folderID: UUID, within ancestorID: UUID) -> Bool {
        folderPath(to: folderID).contains { $0.id == ancestorID }
    }

    /// How many things a folder holds directly.
    public func contentCount(ofFolder folderID: UUID) -> (folders: Int, collections: Int, tracks: Int) {
        (subfolders(of: folderID).count, collections(inFolder: folderID).count, looseTracks(inFolder: folderID).count)
    }

    // MARK: - Changes

    @discardableResult
    public func createFolder(title: String, in parentID: UUID? = nil) -> LibraryFolder {
        let folder = LibraryFolder(
            title: Self.cleanTitle(title, fallback: "Untitled Folder"),
            parentID: parentID.flatMap { folders[$0] != nil ? $0 : nil }
        )
        folders[folder.id] = folder
        save(folder)
        return folder
    }

    public func renameFolder(_ id: UUID, to title: String) {
        updateFolder(id) { $0.title = Self.cleanTitle(title, fallback: $0.title) }
    }

    /// Moves a folder into another (or to the top level when nil). Refuses to
    /// move a folder into itself or one of its own subfolders.
    @discardableResult
    public func moveFolder(_ id: UUID, into parentID: UUID?) -> Bool {
        guard folders[id] != nil else { return false }
        if let parentID {
            guard folders[parentID] != nil, !isFolder(parentID, within: id) else { return false }
            // Conflicting moves on two devices can leave a loop (A in B, B in
            // A), which the queries show as top level. Moving into it breaks
            // the loop at the link that leads back here.
            var cursor: UUID? = parentID
            var seen: Set<UUID> = []
            while let current = cursor, seen.insert(current).inserted {
                let next = folders[current]?.parentID
                if next == id {
                    updateFolder(current) { $0.parentID = nil }
                    break
                }
                cursor = next
            }
        }
        updateFolder(id) { $0.parentID = parentID }
        return true
    }

    public func moveCollection(_ id: UUID, toFolder folderID: UUID?) {
        guard folderID.map({ folders[$0] != nil }) ?? true else { return }
        updateCollection(id) { $0.folderID = folderID }
    }

    /// Places a track directly in a folder (or takes it out when nil). This is
    /// independent of which collections the track is in.
    public func moveTrack(_ id: UUID, toFolder folderID: UUID?) {
        guard folderID.map({ folders[$0] != nil }) ?? true else { return }
        updateTrack(id) { $0.folderID = folderID }
    }

    /// Deletes a folder but nothing in it: its contents move up to its parent.
    public func deleteFolder(_ id: UUID) {
        guard folders[id] != nil else { return }
        let parent = parentFolder(of: id)
        for child in folders.values where child.parentID == id {
            updateFolder(child.id) { $0.parentID = parent }
        }
        for collection in collections.values where collection.folderID == id {
            updateCollection(collection.id) { $0.folderID = parent }
        }
        for track in tracks.values where track.folderID == id {
            updateTrack(track.id) { $0.folderID = parent }
        }
        folders[id] = nil
        let dir = layout.folderDir(id)
        enqueue { disk in try await disk.trash(dir) }
    }

    private func updateFolder(_ id: UUID, _ change: (inout LibraryFolder) -> Void) {
        guard var folder = folders[id] else { return }
        let before = folder
        change(&folder)
        guard folder != before else { return }
        folder.updatedAt = .libraryNow
        folders[id] = folder
        save(folder)
    }

    private func save(_ folder: LibraryFolder) {
        let url = layout.folderFile(folder.id)
        enqueue { disk in try await disk.writeJSON(folder, to: url) }
    }
}
