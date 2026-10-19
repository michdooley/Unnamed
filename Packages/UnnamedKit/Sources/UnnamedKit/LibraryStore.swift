import Foundation
import Observation

/// A problem worth showing to the user.
public struct LibraryIssue: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

/// A track that is still being copied into the library and analysed.
public struct PendingImport: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let collectionID: UUID
}

/// The in-memory view of a library folder, and the only way the app changes it.
///
/// Mutations update memory immediately (so the UI is instant) and queue the
/// matching file writes, which run in order on a background actor. Changes
/// that arrive from iCloud are picked up by watching the folder and rescanning.
@MainActor
@Observable
public final class LibraryStore {
    public let layout: LibraryLayout
    public var root: URL { layout.root }
    /// Whether the library folder lives in iCloud Drive.
    public let isInCloud: Bool

    public internal(set) var tracks: [UUID: Track] = [:]
    public internal(set) var collections: [UUID: TrackCollection] = [:]
    public internal(set) var folders: [UUID: LibraryFolder] = [:]
    public private(set) var notes: [UUID: String] = [:]
    public private(set) var comments: [UUID: [TrackComment]] = [:]
    /// Waveform overviews, per version.
    public internal(set) var peaks: [VersionKey: [UInt8]] = [:]
    public internal(set) var cloudStatus: [UUID: CloudStatus] = [:]
    public private(set) var pendingImports: [PendingImport] = []
    public private(set) var isLoaded = false
    /// The most recent problem from a background operation. The UI shows and clears it.
    public var issue: LibraryIssue?

    /// A queued file operation. A job without `run` is a barrier: its `done`
    /// fires once everything queued before it has finished.
    private struct WriteJob: Sendable {
        var run: (@Sendable (LibraryDisk) async throws -> Void)?
        var done: (@Sendable () -> Void)?
    }

    @ObservationIgnored let disk: LibraryDisk
    @ObservationIgnored private let writes: AsyncStream<WriteJob>.Continuation
    @ObservationIgnored private var writerTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWriteCount = 0
    @ObservationIgnored private var mutationGeneration = 0
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var downloadPollTask: Task<Void, Never>?
    @ObservationIgnored private var notesSaveTasks: [UUID: Task<Void, Never>] = [:]
    #if os(macOS)
    @ObservationIgnored private var watcher: FolderWatcher?
    #endif

    public init(root: URL) {
        layout = LibraryLayout(root: root)
        disk = LibraryDisk(layout: layout)
        isInCloud = Self.isUbiquitous(root)
        let (stream, continuation) = AsyncStream<WriteJob>.makeStream()
        writes = continuation
        let disk = disk
        // The writer runs off the main actor and never waits for it, so writes
        // keep draining even while the main thread is blocked (see `waitForWrites`).
        writerTask = Task.detached { [weak self] in
            for await job in stream {
                if let run = job.run {
                    let failure: (any Error)?
                    do {
                        try await run(disk)
                        failure = nil
                    } catch {
                        failure = error
                    }
                    Task { @MainActor in self?.writeFinished(failure) }
                }
                job.done?()
            }
        }
    }

    /// Stops watching and finishes pending writes. Call before discarding the store.
    public func close() async {
        flushNotes()
        await flush()
        stopWatching()
        rescanTask?.cancel()
        downloadPollTask?.cancel()
        writes.finish()
    }

    // MARK: - Loading & sync

    public func load() async {
        do {
            try await disk.prepare()
        } catch {
            report(error, title: "Couldn't open the library")
        }
        await reload()
        isLoaded = true
    }

    /// Re-reads the folder. Cheap: unchanged files are served from a cache.
    public func reload() async {
        let generation = mutationGeneration
        let snapshot = await disk.scan()
        // If the app changed something while we were scanning, the snapshot may
        // predate that change. Try again once the writes have landed.
        guard generation == mutationGeneration, pendingWriteCount == 0, notesSaveTasks.isEmpty else {
            scheduleRescan(after: .milliseconds(400))
            return
        }
        apply(snapshot)
    }

    public func scheduleRescan(after delay: Duration = .milliseconds(250)) {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    public func startWatching() {
        #if os(macOS)
        guard watcher == nil else { return }
        let watcher = FolderWatcher(url: root) { [weak self] in
            Task { @MainActor in self?.scheduleRescan() }
        }
        watcher.start()
        self.watcher = watcher
        #endif
        // FSEvents doesn't report every iCloud metadata change (like a download
        // finishing), so also poll gently.
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.reload()
            }
        }
    }

    public func stopWatching() {
        #if os(macOS)
        watcher?.stop()
        watcher = nil
        #endif
        pollTask?.cancel()
        pollTask = nil
    }

    /// Waits until every queued write has hit the disk.
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writes.yield(WriteJob(run: nil, done: { continuation.resume() }))
        }
    }

    /// Blocks until queued writes finish (or the timeout passes). For app
    /// termination, where awaiting isn't reliable. Returns false on timeout.
    @discardableResult
    public func waitForWrites(timeout: TimeInterval) -> Bool {
        flushNotes()
        let semaphore = DispatchSemaphore(value: 0)
        writes.yield(WriteJob(run: nil, done: { semaphore.signal() }))
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    private func apply(_ snapshot: LibrarySnapshot) {
        if tracks != snapshot.tracks { tracks = snapshot.tracks }
        if collections != snapshot.collections { collections = snapshot.collections }
        if folders != snapshot.folders { folders = snapshot.folders }
        if notes != snapshot.notes { notes = snapshot.notes }
        if comments != snapshot.comments { comments = snapshot.comments }
        if peaks != snapshot.peaks { peaks = snapshot.peaks }
        if cloudStatus != snapshot.cloudStatus { cloudStatus = snapshot.cloudStatus }
    }

    // MARK: - Queries

    public var collectionsNewestFirst: [TrackCollection] {
        collections.values.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return Self.titleOrder(a.title, a.id, b.title, b.id)
        }
    }

    public var tracksNewestFirst: [Track] {
        tracks.values.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return Self.titleOrder(a.title, a.id, b.title, b.id)
        }
    }

    /// Tie-breaker so items created in the same second keep a stable order.
    public static func titleOrder(_ titleA: String, _ idA: UUID, _ titleB: String, _ idB: UUID) -> Bool {
        switch titleA.localizedStandardCompare(titleB) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: idA.uuidString < idB.uuidString
        }
    }

    /// A collection's tracks in order. Archived tracks are left out unless `includingArchived`.
    public func tracks(in collectionID: UUID, includingArchived: Bool = false) -> [Track] {
        (collections[collectionID]?.trackIDs.compactMap { tracks[$0] } ?? [])
            .filter { includingArchived || $0.archivedAt == nil }
    }

    /// Tracks that would be deleted with a collection (not in any other one).
    public func tracksOnlyIn(_ collectionID: UUID) -> [UUID] {
        (collections[collectionID]?.trackIDs ?? []).filter { trackID in
            tracks[trackID] != nil && !collections.values.contains { $0.id != collectionID && $0.trackIDs.contains(trackID) }
        }
    }

    public func collections(containing trackID: UUID) -> [TrackCollection] {
        collections.values
            .filter { $0.trackIDs.contains(trackID) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func totalDuration(of collectionID: UUID) -> TimeInterval {
        tracks(in: collectionID).reduce(0) { $0 + $1.duration }
    }

    /// The audio of a version (the current one when `version` is nil).
    public func audioURL(for trackID: UUID, version: UUID? = nil) -> URL? {
        tracks[trackID].flatMap { layout.audioURL(for: $0, version: version) }
    }

    /// The waveform of a version (the current one when `version` is nil).
    public func peaks(for trackID: UUID, version: UUID? = nil) -> [UInt8] {
        guard let id = tracks[trackID]?.version(version)?.id else { return [] }
        return peaks[VersionKey(track: trackID, version: id)] ?? []
    }

    public func artworkURL(forTrack trackID: UUID) -> URL? {
        tracks[trackID].flatMap(layout.artworkURL(for:))
    }

    public func artworkURL(forCollection collectionID: UUID) -> URL? {
        collections[collectionID].flatMap(layout.artworkURL(for:))
    }

    // MARK: - Collections

    @discardableResult
    public func createCollection(title: String, trackIDs: [UUID] = [], in folderID: UUID? = nil) -> TrackCollection {
        let collection = TrackCollection(
            title: Self.cleanTitle(title, fallback: "Untitled Collection"),
            trackIDs: trackIDs,
            folderID: folderID.flatMap { folders[$0] != nil ? $0 : nil }
        )
        collections[collection.id] = collection
        save(collection)
        return collection
    }

    public func renameCollection(_ id: UUID, to title: String) {
        updateCollection(id) { $0.title = Self.cleanTitle(title, fallback: $0.title) }
    }

    /// Deletes a collection along with the tracks that aren't in any other
    /// collection (everything goes to the Trash). Tracks shared with another
    /// collection stay. Pass `deleteTracks: false` to keep them all.
    ///
    /// Another device may have just added one of these tracks to a collection
    /// that hasn't synced here yet, so before deleting a track this re-reads
    /// every collection file on disk; if any can't be read, no tracks are
    /// deleted (they stay in All Tracks). Everything goes to the Trash.
    public func deleteCollection(_ id: UUID, deleteTracks: Bool = true) async {
        guard let collection = collections.removeValue(forKey: id) else { return }
        let dir = layout.collectionDir(id)
        enqueue { disk in try await disk.trash(dir) }
        guard deleteTracks else { return }
        let candidates = collection.trackIDs
        guard let onDisk = await disk.trackIDsInCollections(excluding: id) else { return }
        for trackID in candidates where !onDisk.contains(trackID)
            && !collections.values.contains(where: { $0.trackIDs.contains(trackID) }) {
            deleteTrack(trackID)
        }
    }

    public func addTracks(_ trackIDs: [UUID], to collectionID: UUID, at index: Int? = nil) {
        updateCollection(collectionID) { collection in
            var seen = Set(collection.trackIDs)
            let new = trackIDs.filter { seen.insert($0).inserted }
            let position = min(max(0, index ?? collection.trackIDs.count), collection.trackIDs.count)
            collection.trackIDs.insert(contentsOf: new, at: position)
        }
    }

    public func removeTracks(_ trackIDs: Set<UUID>, from collectionID: UUID) {
        updateCollection(collectionID) { $0.trackIDs.removeAll { trackIDs.contains($0) } }
    }

    /// Moves tracks from one collection to another.
    public func moveTracks(_ trackIDs: [UUID], from source: UUID, to destination: UUID) {
        guard source != destination else { return }
        addTracks(trackIDs, to: destination)
        removeTracks(Set(trackIDs), from: source)
    }

    /// Reorders tracks within a collection, placing `trackIDs` just before
    /// `target` (or at the end when `target` is nil).
    public func reorder(_ trackIDs: [UUID], in collectionID: UUID, before target: UUID?) {
        if let target, trackIDs.contains(target) { return }
        updateCollection(collectionID) { collection in
            let moving = collection.trackIDs.filter { trackIDs.contains($0) }
            guard !moving.isEmpty else { return }
            var remaining = collection.trackIDs.filter { !trackIDs.contains($0) }
            let position = target.flatMap { remaining.firstIndex(of: $0) } ?? remaining.count
            remaining.insert(contentsOf: moving, at: position)
            collection.trackIDs = remaining
        }
    }

    public func setTrackOrder(_ trackIDs: [UUID], in collectionID: UUID) {
        updateCollection(collectionID) { $0.trackIDs = trackIDs }
    }

    func updateCollection(_ id: UUID, _ change: (inout TrackCollection) -> Void) {
        guard var collection = collections[id] else { return }
        let before = collection
        change(&collection)
        guard collection != before else { return }
        collection.updatedAt = .libraryNow
        collections[id] = collection
        save(collection)
    }

    func save(_ collection: TrackCollection) {
        let url = layout.collectionFile(collection.id)
        enqueue { disk in try await disk.writeJSON(collection, to: url) }
    }

    // MARK: - Tracks

    /// Copies audio files into the library as new tracks in a collection
    /// (inserted at `index`, or appended). Files that aren't audio are skipped.
    @discardableResult
    public func importAudio(from urls: [URL], into collectionID: UUID, at index: Int? = nil) async -> [UUID] {
        guard collections[collectionID] != nil else { return [] }
        let audioURLs = urls.filter(AudioAnalyzer.isAudioFile)
        let items = audioURLs.map {
            PendingImport(id: UUID(), title: $0.deletingPathExtension().lastPathComponent, collectionID: collectionID)
        }
        pendingImports.append(contentsOf: items)
        var imported: [UUID] = []
        var position = index
        for (url, item) in zip(audioURLs, items) {
            // The collection can be deleted while files are still importing.
            guard collections[collectionID] != nil else {
                pendingImports.removeAll { $0.id == item.id }
                continue
            }
            do {
                let track = try await importOne(url: url, id: item.id, title: item.title)
                guard collections[collectionID] != nil else {
                    deleteTrack(track.id)
                    pendingImports.removeAll { $0.id == item.id }
                    continue
                }
                imported.append(track.id)
                addTracks([track.id], to: collectionID, at: position)
                position = position.map { $0 + 1 }
            } catch {
                report(error, title: "Couldn't import “\(url.lastPathComponent)”")
            }
            pendingImports.removeAll { $0.id == item.id }
        }
        return imported
    }

    private func importOne(url: URL, id: UUID, title: String) async throws -> Track {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let fileName = try await disk.importAudio(from: url, trackID: id)
        let audioURL = layout.trackDir(id).appending(path: fileName, directoryHint: .notDirectory)
        let analysis = try? await AudioAnalyzer.analyze(url: audioURL)
        let track = Track(
            id: id,
            title: Self.cleanTitle(title, fallback: "Untitled"),
            audioFileName: fileName,
            originalFileName: url.lastPathComponent,
            duration: analysis?.duration ?? 0
        )
        tracks[id] = track
        cloudStatus[id] = isInCloud ? .uploading : .local
        save(track)
        saveVersions(of: track)
        if let analysis { savePeaks(analysis.peaks, for: VersionKey(track: id, version: id)) }
        return track
    }

    public func updateTrack(_ id: UUID, _ change: (inout Track) -> Void) {
        guard var track = tracks[id] else { return }
        let before = track
        change(&track)
        guard track != before else { return }
        track.updatedAt = .libraryNow
        tracks[id] = track
        save(track)
    }

    public func renameTrack(_ id: UUID, to title: String) {
        updateTrack(id) { $0.title = Self.cleanTitle(title, fallback: $0.title) }
    }

    /// Copies a track (audio, notes, comments, artwork). The copy is placed
    /// right after the original in `collectionID`, or else in the first
    /// collection the original is in (a track always has a collection).
    @discardableResult
    public func duplicateTrack(_ id: UUID, in collectionID: UUID? = nil) async -> UUID? {
        guard let original = tracks[id] else { return nil }
        if let task = notesSaveTasks.removeValue(forKey: id) {
            task.cancel()
            writeNotes(for: id)
        }
        await flush()
        let newID = UUID()
        do {
            try await disk.copyTrackFolder(from: id, to: newID)
        } catch {
            report(error, title: "Couldn't duplicate “\(original.title)”")
            return nil
        }
        var copy = original
        copy.id = newID
        copy.title = "\(original.title) copy"
        copy.createdAt = .libraryNow
        copy.updatedAt = .libraryNow
        copy.archivedAt = nil
        tracks[newID] = copy
        notes[newID] = notes[id]
        comments[newID] = comments[id]
        for version in copy.versions {
            peaks[VersionKey(track: newID, version: version.id)] = peaks[VersionKey(track: id, version: version.id)]
        }
        cloudStatus[newID] = isInCloud ? .uploading : .local
        save(copy)
        let home = collectionID.flatMap { collections[$0] != nil ? $0 : nil } ?? collections(containing: id).first?.id
        if let home {
            let index = collections[home]?.trackIDs.firstIndex(of: id).map { $0 + 1 }
            addTracks([newID], to: home, at: index)
        }
        return newID
    }

    /// Deletes a track everywhere: from every collection, and its folder goes to the Trash.
    public func deleteTrack(_ id: UUID) {
        guard let track = tracks.removeValue(forKey: id) else { return }
        notesSaveTasks.removeValue(forKey: id)?.cancel()
        notes[id] = nil
        comments[id] = nil
        for version in track.versions { peaks[VersionKey(track: id, version: version.id)] = nil }
        cloudStatus[id] = nil
        for collection in collections.values where collection.trackIDs.contains(id) {
            updateCollection(collection.id) { $0.trackIDs.removeAll { $0 == id } }
        }
        let dir = layout.trackDir(id)
        enqueue { disk in try await disk.trash(dir) }
    }

    func save(_ track: Track) {
        let url = layout.trackFile(track.id)
        enqueue { disk in try await disk.writeJSON(track, to: url) }
    }

    /// Writes any version files that don't exist yet.
    func saveVersions(of track: Track) {
        let versions = track.versions
        let trackID = track.id
        enqueue { disk in try await disk.writeMissingVersionFiles(versions, trackID: trackID) }
    }

    func save(_ version: TrackVersion, of trackID: UUID) {
        let url = layout.versionFile(trackID: trackID, versionID: version.id)
        enqueue { disk in try await disk.writeJSON(version, to: url) }
    }

    func savePeaks(_ values: [UInt8], for key: VersionKey) {
        guard tracks[key.track] != nil else { return }
        peaks[key] = values
        let url = layout.waveformFile(trackID: key.track, versionID: key.version)
        enqueue { disk in try await disk.writeJSON(WaveformFile(peaks: values), to: url) }
    }

    // MARK: - Notes

    /// Updates notes immediately in memory; the file is written after a short pause in typing.
    public func setNotes(_ text: String, for trackID: UUID) {
        guard tracks[trackID] != nil else { return }
        let value: String? = text.isEmpty ? nil : text
        guard notes[trackID] != value else { return }
        notes[trackID] = value
        mutationGeneration += 1
        notesSaveTasks[trackID]?.cancel()
        notesSaveTasks[trackID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.notesSaveTasks[trackID] = nil
            self.writeNotes(for: trackID)
        }
    }

    /// Writes any notes still waiting for the typing pause.
    public func flushNotes() {
        let ids = Array(notesSaveTasks.keys)
        for id in ids {
            notesSaveTasks.removeValue(forKey: id)?.cancel()
            writeNotes(for: id)
        }
    }

    private func writeNotes(for id: UUID) {
        let text = notes[id]
        let url = layout.notesFile(id)
        enqueue { disk in
            if let text {
                try await disk.writeText(text, to: url)
            } else {
                try await disk.remove(url)
            }
        }
    }

    // MARK: - Comments

    /// Comments on one version (the current one when `version` is nil).
    /// Comments made before versions existed belong to the first version.
    public func comments(for trackID: UUID, version: UUID?) -> [TrackComment] {
        guard let track = tracks[trackID], let shown = track.version(version)?.id else { return [] }
        let first = track.versions.first?.id
        return (comments[trackID] ?? []).filter { ($0.versionID ?? first) == shown }
    }

    /// Adds a comment to a version (the current one when `version` is nil).
    /// Returns nil if that version no longer exists.
    @discardableResult
    public func addComment(to trackID: UUID, at timestamp: TimeInterval, text: String, author: String? = nil, version: UUID? = nil) -> TrackComment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let track = tracks[trackID], track.version(version) != nil else { return nil }
        let comment = TrackComment(timestamp: max(0, timestamp), text: trimmed, author: author, versionID: track.version(version)?.id)
        var list = comments[trackID] ?? []
        list.append(comment)
        list.sort(by: TrackComment.playbackOrder)
        comments[trackID] = list
        let url = layout.commentFile(trackID: trackID, commentID: comment.id)
        enqueue { disk in try await disk.writeJSON(comment, to: url) }
        return comment
    }

    public func updateComment(_ commentID: UUID, on trackID: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var list = comments[trackID], let index = list.firstIndex(where: { $0.id == commentID }) else { return }
        list[index].text = trimmed
        let comment = list[index]
        comments[trackID] = list
        let url = layout.commentFile(trackID: trackID, commentID: commentID)
        enqueue { disk in try await disk.writeJSON(comment, to: url) }
    }

    public func deleteComment(_ commentID: UUID, from trackID: UUID) {
        guard var list = comments[trackID] else { return }
        list.removeAll { $0.id == commentID }
        comments[trackID] = list.isEmpty ? nil : list
        let url = layout.commentFile(trackID: trackID, commentID: commentID)
        enqueue { disk in try await disk.remove(url) }
    }

    // MARK: - Artwork

    public enum ArtworkSource: Sendable {
        case file(URL)
        case data(Data)
    }

    /// Sets a track's artwork. `credit` names the photographer for Unsplash photos.
    public func setArtwork(forTrack trackID: UUID, from source: ArtworkSource, credit: ArtworkCredit? = nil) async {
        guard tracks[trackID] != nil else { return }
        let dir = layout.trackDir(trackID)
        guard let fileName = await writeArtwork(source, into: dir, while: { self.tracks[trackID] != nil }),
              let track = tracks[trackID] else { return }
        let old = layout.artworkURL(for: track)
        updateTrack(trackID) {
            $0.artworkFileName = fileName
            $0.artworkCredit = credit
        }
        if let old { enqueue { disk in try await disk.remove(old) } }
    }

    public func removeArtwork(forTrack trackID: UUID) {
        guard let track = tracks[trackID], let old = layout.artworkURL(for: track) else { return }
        updateTrack(trackID) {
            $0.artworkFileName = nil
            $0.artworkCredit = nil
        }
        enqueue { disk in try await disk.remove(old) }
    }

    /// Sets a collection's cover. `credit` names the photographer for Unsplash photos.
    public func setArtwork(forCollection collectionID: UUID, from source: ArtworkSource, credit: ArtworkCredit? = nil) async {
        guard collections[collectionID] != nil else { return }
        let dir = layout.collectionDir(collectionID)
        guard let fileName = await writeArtwork(source, into: dir, while: { self.collections[collectionID] != nil }),
              let collection = collections[collectionID] else { return }
        let old = layout.artworkURL(for: collection)
        updateCollection(collectionID) {
            $0.artworkFileName = fileName
            $0.artworkCredit = credit
        }
        if let old { enqueue { disk in try await disk.remove(old) } }
    }

    public func removeArtwork(forCollection collectionID: UUID) {
        guard let collection = collections[collectionID], let old = layout.artworkURL(for: collection) else { return }
        updateCollection(collectionID) {
            $0.artworkFileName = nil
            $0.artworkCredit = nil
        }
        enqueue { disk in try await disk.remove(old) }
    }

    /// Each new artwork gets a fresh file name, so caches keyed by URL never show a stale image.
    private func writeArtwork(_ source: ArtworkSource, into dir: URL, while stillExists: () -> Bool) async -> String? {
        do {
            let jpeg = try await Task.detached(priority: .userInitiated) {
                switch source {
                case .file(let url):
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    return try ArtworkProcessor.jpegData(fromImageAt: url)
                case .data(let data):
                    return try ArtworkProcessor.jpegData(fromImageData: data)
                }
            }.value
            // Deleted while the image was being processed: don't recreate its folder.
            guard stillExists() else { return nil }
            let fileName = "artwork-\(UUID().uuidString.prefix(8).lowercased()).jpg"
            try await disk.writeData(jpeg, to: dir.appending(path: fileName, directoryHint: .notDirectory))
            return fileName
        } catch {
            report(error, title: "Couldn't use that image")
            return nil
        }
    }

    // MARK: - iCloud downloads

    /// Asks iCloud to download a track's audio so it plays offline.
    public func download(_ trackID: UUID) {
        guard isInCloud, let url = audioURL(for: trackID) else { return }
        cloudStatus[trackID] = .downloading
        Task {
            do {
                try await disk.startDownloading(url)
            } catch {
                report(error, title: "Couldn't download the audio")
            }
            pollDownloads()
        }
    }

    /// Frees local space; the audio stays in iCloud and downloads again on play.
    public func removeDownload(_ trackID: UUID) {
        guard isInCloud, let url = audioURL(for: trackID) else { return }
        Task {
            do {
                try await disk.evict(url)
                cloudStatus[trackID] = await disk.cloudStatus(of: url)
            } catch {
                report(error, title: "Couldn't remove the download")
            }
        }
    }

    /// Returns a playable local URL for a version (the current one when
    /// `version` is nil), downloading from iCloud first if needed.
    public func ensureDownloaded(_ trackID: UUID, version: UUID? = nil, timeout: Duration = .seconds(600)) async throws -> URL {
        guard let url = audioURL(for: trackID, version: version) else { throw CocoaError(.fileNoSuchFile) }
        let tracksStatus = version == nil || version == tracks[trackID]?.currentVersionID
        var status = await disk.cloudStatus(of: url)
        if status.isPlayableWithoutDownload { return url }
        guard isInCloud else { throw CocoaError(.fileNoSuchFile) }
        if status != .missing {
            try await disk.startDownloading(url)
        }
        if tracksStatus { cloudStatus[trackID] = .downloading }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(400))
            status = await disk.cloudStatus(of: url)
            if status == .notDownloaded {
                try? await disk.startDownloading(url)
            }
            if status.isPlayableWithoutDownload {
                if tracksStatus { cloudStatus[trackID] = status }
                return url
            }
        }
        throw CocoaError(.fileReadUnknown)
    }

    public func exportAudio(of trackID: UUID, version: UUID? = nil, to destination: URL) async throws {
        let source = try await ensureDownloaded(trackID, version: version)
        try await disk.export(source, to: destination)
    }

    private func pollDownloads() {
        guard downloadPollTask == nil else { return }
        downloadPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let downloading = self.cloudStatus.filter { $0.value == .downloading }.map(\.key)
                if downloading.isEmpty { break }
                for id in downloading {
                    guard let url = self.audioURL(for: id) else { continue }
                    self.cloudStatus[id] = await self.disk.cloudStatus(of: url)
                }
            }
            self?.downloadPollTask = nil
        }
    }

    // MARK: - Plumbing

    func enqueue(_ run: @escaping @Sendable (LibraryDisk) async throws -> Void) {
        mutationGeneration += 1
        pendingWriteCount += 1
        writes.yield(WriteJob(run: run))
    }

    private func writeFinished(_ error: (any Error)?) {
        pendingWriteCount -= 1
        if let error {
            report(error, title: "Couldn't save a change")
        }
    }

    func report(_ error: any Error, title: String) {
        issue = LibraryIssue(title: title, message: error.localizedDescription)
    }

    static func cleanTitle(_ title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func isUbiquitous(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            return true
        }
        // A folder that doesn't exist yet can't report it; fall back to the path.
        return url.standardizedFileURL.path.contains("/Library/Mobile Documents/")
    }
}
