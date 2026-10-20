import Foundation

/// Everything read from a library folder in one pass.
struct LibrarySnapshot: Sendable, Equatable {
    var tracks: [UUID: Track] = [:]
    var collections: [UUID: TrackCollection] = [:]
    var folders: [UUID: LibraryFolder] = [:]
    var notes: [UUID: String] = [:]
    var comments: [UUID: [TrackComment]] = [:]
    var peaks: [VersionKey: [UInt8]] = [:]
    var cloudStatus: [UUID: CloudStatus] = [:]
    var boards: [UUID: Moodboard] = [:]
}

/// Owns all file I/O for a library. Being an actor serialises reads and
/// writes, so a scan never observes a half-applied change made by this app.
///
/// Writes go through `NSFileCoordinator`, which is how iCloud Drive expects
/// apps to touch synced files. Scans use plain reads (every write is atomic)
/// and cache decoded files by modification date so rescans are cheap.
actor LibraryDisk {
    let layout: LibraryLayout

    private struct CacheEntry {
        var modified: Date
        var size: Int
        var value: any Sendable
    }

    private var cache: [URL: CacheEntry] = [:]
    /// What becomes of the losing side of a sync conflict (the Trash, so it can be recovered).
    private let discard: @Sendable (URL) throws -> Void

    init(layout: LibraryLayout, discard: @escaping @Sendable (URL) throws -> Void = LibraryDisk.moveToTrash) {
        self.layout = layout
        self.discard = discard
    }

    // MARK: - Setup

    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.collectionsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.tracksDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.foldersDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: layout.manifestFile.path) {
            try writeJSON(LibraryManifest(), to: layout.manifestFile)
        }
        if !fm.fileExists(atPath: layout.readmeFile.path) {
            try writeText(Self.readme, to: layout.readmeFile)
        }
    }

    // MARK: - Scanning

    func scan() -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()
        var seen = Set<URL>()
        settleConflictCopies(in: layout.root, of: [layout.manifestFile.lastPathComponent])

        for dir in Self.subdirectories(of: layout.collectionsDir) {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let file = layout.collectionFile(id)
            settleConflictCopies(in: dir, of: [file.lastPathComponent])
            seen.insert(file)
            // The folder name is the source of truth for the ID, so a folder
            // duplicated in Finder becomes a separate collection.
            guard var collection = cachedJSON(TrackCollection.self, at: file) else { continue }
            collection.id = id
            snapshot.collections[id] = collection
            if let board = scanBoard(of: id, seen: &seen) {
                snapshot.boards[id] = board
            }
        }

        for dir in Self.subdirectories(of: layout.foldersDir) {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let file = layout.folderFile(id)
            settleConflictCopies(in: dir, of: [file.lastPathComponent])
            seen.insert(file)
            guard var folder = cachedJSON(LibraryFolder.self, at: file) else { continue }
            folder.id = id
            snapshot.folders[id] = folder
        }

        for dir in Self.subdirectories(of: layout.tracksDir) {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let file = layout.trackFile(id)
            settleConflictCopies(in: dir, of: [file, layout.notesFile(id), layout.legacyWaveformFile(id)].map(\.lastPathComponent))
            for entities in [layout.versionsDir(id), layout.commentsDir(id), layout.waveformsDir(id)] {
                settleConflictCopies(amongEntitiesIn: entities)
            }
            seen.insert(file)
            guard var track = cachedJSON(Track.self, at: file) else { continue }
            let declaredID = track.id
            track.id = id

            var versions: [TrackVersion] = []
            for url in Self.files(in: layout.versionsDir(id)) where url.pathExtension == "json" {
                guard let versionID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
                seen.insert(url)
                guard var version = cachedJSON(TrackVersion.self, at: url) else { continue }
                version.id = versionID
                versions.append(version)
            }
            if !versions.isEmpty {
                track.versions = versions.sorted(by: TrackVersion.order)
            } else if track.versions.count == 1, track.versions[0].id == declaredID {
                // Format 1: the single version takes the folder's ID, which is
                // stable even if track.json's `id` is missing or wrong.
                track.versions[0].id = id
            }
            if !track.versions.contains(where: { $0.id == track.currentVersionID }) {
                track.currentVersionID = track.versions.last?.id
            }
            snapshot.tracks[id] = track

            let notesURL = layout.notesFile(id)
            seen.insert(notesURL)
            if let text = cachedText(at: notesURL), !text.isEmpty {
                snapshot.notes[id] = text
            }

            for (index, version) in track.versions.enumerated() {
                let url = layout.waveformFile(trackID: id, versionID: version.id)
                seen.insert(url)
                var waveform = cachedJSON(WaveformFile.self, at: url)
                if waveform == nil, index == 0 {
                    let legacy = layout.legacyWaveformFile(id)
                    seen.insert(legacy)
                    waveform = cachedJSON(WaveformFile.self, at: legacy)
                }
                if let waveform {
                    snapshot.peaks[VersionKey(track: id, version: version.id)] = waveform.peaks
                }
            }

            var comments: [TrackComment] = []
            for url in Self.files(in: layout.commentsDir(id)) where url.pathExtension == "json" {
                guard let commentID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
                seen.insert(url)
                guard var comment = cachedJSON(TrackComment.self, at: url) else { continue }
                comment.id = commentID
                comments.append(comment)
            }
            if !comments.isEmpty {
                snapshot.comments[id] = comments.sorted(by: TrackComment.playbackOrder)
            }

            if let audio = layout.audioURL(for: track) {
                snapshot.cloudStatus[id] = Self.cloudStatus(of: audio)
            } else {
                snapshot.cloudStatus[id] = .missing
            }
        }

        cache = cache.filter { seen.contains($0.key) }
        return snapshot
    }

    /// A collection's moodboard, if it has one.
    private func scanBoard(of collectionID: UUID, seen: inout Set<URL>) -> Moodboard? {
        let dir = layout.boardDir(collectionID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        var board = Moodboard()
        let settingsURL = layout.boardFile(collectionID)
        seen.insert(settingsURL)
        settleConflictCopies(in: dir, of: [settingsURL.lastPathComponent])
        settleConflictCopies(amongEntitiesIn: layout.boardItemsDir(collectionID))
        if let settings = cachedJSON(BoardSettings.self, at: settingsURL) {
            board.settings = settings
        }
        for url in Self.files(in: layout.boardItemsDir(collectionID)) where url.pathExtension == "json" {
            guard let itemID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            seen.insert(url)
            guard var item = cachedJSON(BoardItem.self, at: url) else { continue }
            item.id = itemID
            board.items[itemID] = item
        }
        return board
    }

    func cloudStatus(of url: URL) -> CloudStatus {
        Self.cloudStatus(of: url)
    }

    // MARK: - Conflict copies

    /// Settles the copies sync services leave beside fixed-name files
    /// (`track.json`, `notes.md`…) in a folder.
    func settleConflictCopies(in directory: URL, of originals: [String]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for original in originals {
            let copies = names.filter { ConflictCopies.isCopy($0, of: original) }
            if !copies.isEmpty { settle(original, copies: copies, in: directory) }
        }
    }

    /// The same for a folder of `<UUID>.json` files (versions, comments…).
    func settleConflictCopies(amongEntitiesIn directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var copies: [String: [String]] = [:]
        for name in names where name.hasSuffix(".json") && name.count > 41 {
            let stem = String(name.prefix(36))
            guard UUID(uuidString: stem) != nil, ConflictCopies.isCopy(name, of: stem + ".json") else { continue }
            copies[stem + ".json", default: []].append(name)
        }
        for (original, copies) in copies { settle(original, copies: copies, in: directory) }
    }

    /// Keeps the newest of a file and its conflict copies under the file's
    /// name (newest by its `updatedAt`, else by when it was written), and
    /// moves the rest to the Trash. Waits while any of them is still only in
    /// the cloud.
    private func settle(_ original: String, copies: [String], in directory: URL) {
        let fm = FileManager.default
        let originalURL = directory.appending(path: original)
        let copyURLs = copies.map { directory.appending(path: $0) }
        let originalExists = fm.fileExists(atPath: originalURL.path)
        let candidates = copyURLs + (originalExists ? [originalURL] : [])
        guard !candidates.contains(where: Self.isOnlyInCloud) else { return }
        guard let newest = candidates.max(by: { Self.stamp(of: $0) < Self.stamp(of: $1) }) else { return }
        do {
            for url in candidates where url != newest { try discard(url) }
            if newest != originalURL {
                try Self.coordinated(writingAt: newest, options: .forMoving) { url in
                    try fm.moveItem(at: url, to: originalURL)
                }
            }
        } catch {
            // Tried again on the next scan.
        }
        cache[originalURL] = nil
    }

    /// When a metadata file was last changed: its `updatedAt` if it has one.
    private static func stamp(of url: URL) -> Date {
        struct Stamped: Decodable { var updatedAt: Date? }
        if url.pathExtension == "json", let data = try? Data(contentsOf: url),
           let date = (try? LibraryJSON.decoder().decode(Stamped.self, from: data))?.updatedAt {
            return date
        }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// A placeholder whose contents haven't been downloaded (any cloud
    /// service built on File Provider, iCloud Drive included).
    static func isOnlyInCloud(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// To the Trash, or gone where there isn't one (some network drives).
    static let moveToTrash: @Sendable (URL) throws -> Void = { url in
        try coordinated(writingAt: url, options: .forDeleting) { url in
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Moves a finished file (e.g. an encoded video in a temporary folder) into the library.
    func moveIntoPlace(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.coordinated(writingAt: destination, options: .forReplacing) { url in
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: source, to: url)
        }
    }

    /// The media files a board's items name, read from the raw JSON (so items
    /// of a type this version doesn't know still count). Nil if any item file
    /// can't be read, or is still only a placeholder from iCloud.
    func boardMediaInUse(of collectionID: UUID) -> Set<String>? {
        let dir = layout.boardItemsDir(collectionID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var used = Set<String>()
        for name in names {
            if name.hasSuffix(".icloud") { return nil }
            guard name.hasSuffix(".json") else { continue }
            guard let data = try? Data(contentsOf: dir.appending(path: name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let file = object["file"] as? String { used.insert(file) }
        }
        return used
    }

    func boardMediaFiles(of collectionID: UUID) -> [URL] {
        Self.files(in: layout.boardMediaDir(collectionID))
    }

    /// Every track ID listed by a collection on disk right now (other than
    /// `excluded`), or nil if any collection file can't be read, in which
    /// case the caller can't be sure a track is unused.
    func trackIDsInCollections(excluding excluded: UUID) -> Set<UUID>? {
        var ids = Set<UUID>()
        for dir in Self.subdirectories(of: layout.collectionsDir) {
            guard let id = UUID(uuidString: dir.lastPathComponent), id != excluded else { continue }
            guard let collection = cachedJSON(TrackCollection.self, at: layout.collectionFile(id)) else { return nil }
            ids.formUnion(collection.trackIDs)
        }
        return ids
    }

    static func cloudStatus(of url: URL) -> CloudStatus {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemIsUploadedKey,
        ]
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: keys) else { return .missing }
        guard values.isUbiquitousItem == true else { return .local }
        if values.ubiquitousItemIsDownloading == true { return .downloading }
        if values.ubiquitousItemDownloadingStatus == .notDownloaded { return .notDownloaded }
        if values.ubiquitousItemIsUploading == true { return .uploading }
        return .downloaded
    }

    // MARK: - Writing

    func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try LibraryJSON.encoder().encode(value)
        try Self.coordinatedWrite(data, to: url)
    }

    func writeText(_ text: String, to url: URL) throws {
        try Self.coordinatedWrite(Data(text.utf8), to: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try Self.coordinatedWrite(data, to: url)
    }

    /// Writes a version file for each version that doesn't have one yet
    /// (format-1 tracks get theirs when their second version arrives).
    func writeMissingVersionFiles(_ versions: [TrackVersion], trackID: UUID) throws {
        for version in versions {
            let url = layout.versionFile(trackID: trackID, versionID: version.id)
            if !FileManager.default.fileExists(atPath: url.path) {
                try writeJSON(version, to: url)
            }
        }
    }

    /// Removes a single small file (comment, notes, old artwork).
    func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try Self.coordinated(writingAt: url, options: .forDeleting) { url in
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Moves a whole track or collection folder to the Trash so a mistaken
    /// delete can be recovered (iCloud Drive also keeps it in Recently Deleted).
    func trash(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try Self.coordinated(writingAt: url, options: .forDeleting) { url in
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Copies an audio file into a track's folder and returns its file name.
    func importAudio(from source: URL, trackID: UUID) throws -> String {
        let dir = layout.trackDir(trackID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = sanitizedFileName(source.deletingPathExtension().lastPathComponent, fallback: "Audio")
        let name = Self.uniqueFileName(base: base, ext: source.pathExtension.lowercased(), in: dir)
        let destination = dir.appending(path: name, directoryHint: .notDirectory)

        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source, options: [],
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { readURL, writeURL in
            do {
                try FileManager.default.copyItem(at: readURL, to: writeURL)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
        return name
    }

    func copyTrackFolder(from sourceID: UUID, to destinationID: UUID) throws {
        // (Versions, waveforms and comments come along; their IDs are only
        // unique within a track, so they can stay as they are.)
        let source = layout.trackDir(sourceID)
        let destination = layout.trackDir(destinationID)
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source, options: [],
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { readURL, writeURL in
            do {
                try FileManager.default.copyItem(at: readURL, to: writeURL)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
    }

    /// Copies a file out of the library (Export audio).
    func export(_ source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { readURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: readURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
    }

    // MARK: - iCloud downloads

    func startDownloading(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    func evict(_ url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }

    // MARK: - Helpers

    private func cachedJSON<T: Decodable & Sendable>(_ type: T.Type, at url: URL) -> T? {
        cached(at: url) { data in try LibraryJSON.decoder().decode(T.self, from: data) }
    }

    private func cachedText(at url: URL) -> String? {
        cached(at: url) { data in String(decoding: data, as: UTF8.self) }
    }

    private func cached<T: Sendable>(at url: URL, decode: (Data) throws -> T) -> T? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .ubiquitousItemHasUnresolvedConflictsKey]
        var url = url
        guard var values = try? url.resourceValues(forKeys: keys) else {
            cache[url] = nil
            return nil
        }
        if values.ubiquitousItemHasUnresolvedConflicts == true {
            Self.resolveConflicts(at: url)
            url.removeAllCachedResourceValues()
            values = (try? url.resourceValues(forKeys: keys)) ?? values
        }
        let modified = values.contentModificationDate ?? .distantPast
        let size = values.fileSize ?? 0
        if let entry = cache[url], entry.modified == modified, entry.size == size, let value = entry.value as? T {
            return value
        }
        guard let data = try? Data(contentsOf: url), let value = try? decode(data) else {
            return nil
        }
        cache[url] = CacheEntry(modified: modified, size: size, value: value)
        return value
    }

    /// iCloud keeps both sides of a conflicting edit. Metadata files are small
    /// and edited by one person at a time, so the newest version wins.
    static func resolveConflicts(at url: URL) {
        try? coordinated(writingAt: url, options: .forMerging) { url in
            guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty else { return }
            let current = NSFileVersion.currentVersionOfItem(at: url)
            let currentDate = current?.modificationDate ?? .distantPast
            if let newest = conflicts.max(by: { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }),
               (newest.modificationDate ?? .distantPast) > currentDate {
                _ = try newest.replaceItem(at: url, options: [])
            }
            for version in conflicts { version.isResolved = true }
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
    }

    static func coordinatedWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinated(writingAt: url, options: .forReplacing) { url in
            try data.write(to: url, options: .atomic)
        }
    }

    static func coordinated(writingAt url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &coordinationError) { url in
            do {
                try body(url)
            } catch {
                bodyError = error
            }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }

    static func subdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    static func files(in url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }

    static func uniqueFileName(base: String, ext: String, in dir: URL) -> String {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = base + suffix
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appending(path: candidate).path) {
            candidate = "\(base) \(n)\(suffix)"
            n += 1
        }
        return candidate
    }

    static let readme = """
    This folder is a music library created by Unnamed, an open-source app for music ideas.

    Everything here is plain files you own:

      Tracks/<id>/                 one folder per idea
        <name>.wav / .mp3 / ...    the audio, exactly as you imported it
                                   (every version you've uploaded is kept)
        track.json                 title, current version, dates, BPM, key
        Versions/<id>.json         one file per uploaded version
        notes.md                   your notes
        Comments/<id>.json         timestamped comments
        Waveforms/<version>.json   waveform overviews
        artwork-*.jpg              artwork, if set

      Collections/<id>/            one folder per collection (album, mixtape...)
        collection.json            title and the ordered list of track ids
        artwork-*.jpg              cover art, if set

      Folders/<id>/folder.json     folders for organising collections and tracks

    You can back this folder up, move it, or open it from another device.
    Please don't rename the <id> folders; that's how tracks are linked to collections.

    """
}

extension TrackComment {
    static func playbackOrder(_ a: TrackComment, _ b: TrackComment) -> Bool {
        a.timestamp == b.timestamp ? a.createdAt < b.createdAt : a.timestamp < b.timestamp
    }
}
