import Foundation

/// Everything read from a library folder in one pass.
struct LibrarySnapshot: Sendable, Equatable {
    var tracks: [UUID: Track] = [:]
    var collections: [UUID: TrackCollection] = [:]
    var notes: [UUID: String] = [:]
    var comments: [UUID: [TrackComment]] = [:]
    var peaks: [UUID: [UInt8]] = [:]
    var cloudStatus: [UUID: CloudStatus] = [:]
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

    init(layout: LibraryLayout) {
        self.layout = layout
    }

    // MARK: - Setup

    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.collectionsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.tracksDir, withIntermediateDirectories: true)
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

        for dir in Self.subdirectories(of: layout.collectionsDir) {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let file = layout.collectionFile(id)
            seen.insert(file)
            // The folder name is the source of truth for the ID, so a folder
            // duplicated in Finder becomes a separate collection.
            guard var collection = cachedJSON(TrackCollection.self, at: file) else { continue }
            collection.id = id
            snapshot.collections[id] = collection
        }

        for dir in Self.subdirectories(of: layout.tracksDir) {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let file = layout.trackFile(id)
            seen.insert(file)
            guard var track = cachedJSON(Track.self, at: file) else { continue }
            track.id = id
            snapshot.tracks[id] = track

            let notesURL = layout.notesFile(id)
            seen.insert(notesURL)
            if let text = cachedText(at: notesURL), !text.isEmpty {
                snapshot.notes[id] = text
            }

            let waveformURL = layout.waveformFile(id)
            seen.insert(waveformURL)
            if let waveform = cachedJSON(WaveformFile.self, at: waveformURL) {
                snapshot.peaks[id] = waveform.peaks
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

    func cloudStatus(of url: URL) -> CloudStatus {
        Self.cloudStatus(of: url)
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
        track.json                 title, dates, duration, BPM, key
        notes.md                   your notes
        Comments/<id>.json         timestamped comments
        waveform.json              the waveform overview
        artwork-*.jpg              artwork, if set

      Collections/<id>/            one folder per collection (album, mixtape...)
        collection.json            title and the ordered list of track ids
        artwork-*.jpg              cover art, if set

    You can back this folder up, move it, or open it from another device.
    Please don't rename the <id> folders; that's how tracks are linked to collections.

    """
}

extension TrackComment {
    static func playbackOrder(_ a: TrackComment, _ b: TrackComment) -> Bool {
        a.timestamp == b.timestamp ? a.createdAt < b.createdAt : a.timestamp < b.timestamp
    }
}
