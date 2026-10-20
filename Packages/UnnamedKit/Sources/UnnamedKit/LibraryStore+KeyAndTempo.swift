import Foundation

/// Key and tempo, worked out from the audio (see `MusicAnalyzer`) whenever a
/// track or a new version is added, and on request.
///
/// What's heard is kept with each version. The track's own BPM and key take
/// it on unless they've been set by hand: a value the app detected for any of
/// the track's versions is the app's to replace; anything else is the user's.
extension LibraryStore {
    /// Listens to a version (the current one when `version` is nil) in the
    /// background, one recording at a time. With `replacing`, what's heard
    /// replaces even values set by hand, and audio still in iCloud is
    /// downloaded first; otherwise only audio on this Mac is listened to.
    /// The task gives what was heard (nil if the audio couldn't be read).
    @discardableResult
    public func detectKeyAndTempo(of trackID: UUID, version versionID: UUID? = nil, replacing: Bool = false) -> Task<MusicAnalyzer.Result?, Never>? {
        guard let version = tracks[trackID]?.version(versionID) else { return nil }
        let versionID = version.id
        listening[trackID, default: 0] += 1
        let previous = detectionQueue
        let job = Task { [weak self] () -> MusicAnalyzer.Result? in
            await previous?.value
            guard let self else { return nil }
            defer { self.doneListening(to: trackID) }
            return await self.listen(to: versionID, of: trackID, replacing: replacing)
        }
        detectionQueue = Task { _ = await job.value }
        return job
    }

    /// Listens to every track that's missing a key or a tempo and hasn't been
    /// listened to yet (and whose audio is on this Mac). Returns how many.
    @discardableResult
    public func detectMissingKeysAndTempos() -> Int {
        let wanted = tracks.values.filter { track in
            guard track.archivedAt == nil, track.bpm == nil || track.musicalKey == nil,
                  let version = track.currentVersion, version.detectedAt == nil else { return false }
            return cloudStatus[track.id].map { $0.isPlayableWithoutDownload } ?? true
        }
        for track in wanted.sorted(by: { $0.createdAt > $1.createdAt }) {
            detectKeyAndTempo(of: track.id)
        }
        return wanted.count
    }

    /// Picks up listening that a quit interrupted: versions added in the
    /// last day that were never listened to (and whose audio is on this Mac).
    func resumeDetection(now: Date = Date()) {
        for track in tracks.values where track.archivedAt == nil {
            for version in track.versions where version.detectedAt == nil && now.timeIntervalSince(version.createdAt) < 24 * 3600 {
                detectKeyAndTempo(of: track.id, version: version.id)
            }
        }
    }

    /// Waits until everything queued has been listened to.
    public func waitForDetection() async {
        while let queue = detectionQueue {
            await queue.value
            if detectionQueue == queue { break }
        }
    }

    public func isListening(to trackID: UUID) -> Bool {
        listening[trackID] != nil
    }

    private func doneListening(to trackID: UUID) {
        let remaining = (listening[trackID] ?? 1) - 1
        listening[trackID] = remaining > 0 ? remaining : nil
    }

    private func listen(to versionID: UUID, of trackID: UUID, replacing: Bool) async -> MusicAnalyzer.Result? {
        guard let url = audioURL(for: trackID, version: versionID) else { return nil }
        let audio: URL
        if replacing {
            guard let downloaded = try? await ensureDownloaded(trackID, version: versionID) else { return nil }
            audio = downloaded
        } else {
            guard await disk.cloudStatus(of: url).isPlayableWithoutDownload else { return nil }
            audio = url
        }
        let heard = try? await Task.detached(priority: .utility) {
            try await MusicAnalyzer.analyze(url: audio)
        }.value
        guard let heard else { return nil }
        record(heard, for: versionID, of: trackID, replacing: replacing)
        return heard
    }

    /// Keeps what was heard with the version, and gives it to the track if
    /// the version is current and the track's values are the app's to change.
    func record(_ heard: MusicAnalyzer.Result, for versionID: UUID, of trackID: UUID, replacing: Bool = false) {
        guard let before = tracks[trackID], let index = before.versions.firstIndex(where: { $0.id == versionID }) else { return }
        var version = before.versions[index]
        version.detectedBPM = heard.bpm
        version.detectedKey = heard.key?.name
        version.detectedAt = .libraryNow
        // Only the version's own file changes (the track isn't "edited").
        save(version, of: trackID)
        tracks[trackID]?.versions[index] = version
        guard before.currentVersion?.id == versionID else { return }
        give(version, to: trackID, judgedBy: before, replacing: replacing)
    }

    /// After the current version changes: the track takes on what was heard
    /// in the new one (listening to it first if it hasn't been yet).
    func adoptKeyAndTempo(of versionID: UUID, for trackID: UUID, judgedBy before: Track? = nil) {
        guard let track = tracks[trackID], let version = track.versions.first(where: { $0.id == versionID }) else { return }
        guard version.detectedAt != nil else {
            detectKeyAndTempo(of: trackID, version: versionID)
            return
        }
        give(version, to: trackID, judgedBy: before ?? track, replacing: false)
    }

    private func give(_ version: TrackVersion, to trackID: UUID, judgedBy before: Track, replacing: Bool) {
        // Values the app put there itself, for any version, are its to change.
        let heardTempos = Set(before.versions.compactMap(\.detectedBPM))
        let heardKeys = Set(before.versions.compactMap(\.detectedKey))
        updateTrack(trackID) { track in
            if let bpm = version.detectedBPM, replacing || track.bpm.map(heardTempos.contains) ?? true {
                track.bpm = bpm
            }
            if let key = version.detectedKey, replacing || track.musicalKey.map(heardKeys.contains) ?? true {
                track.musicalKey = key
            }
        }
    }
}
