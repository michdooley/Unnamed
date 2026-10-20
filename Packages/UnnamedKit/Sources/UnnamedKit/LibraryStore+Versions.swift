import Foundation

/// Version history: every upload of a track's audio is kept, and one of them
/// is current (the one that plays by default).
extension LibraryStore {
    /// Uploads a new version of a track and makes it current. Earlier
    /// versions, and their comments, are kept.
    @discardableResult
    public func addVersion(to trackID: UUID, from url: URL, name: String? = nil) async -> UUID? {
        guard tracks[trackID] != nil else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let fileName = try await disk.importAudio(from: url, trackID: trackID)
            let audioURL = layout.trackDir(trackID).appending(path: fileName, directoryHint: .notDirectory)
            let analysis = try? await AudioAnalyzer.analyze(url: audioURL)
            // Deleted while importing: its folder is already queued for the Trash.
            guard let existing = tracks[trackID] else { return nil }
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strictly after the latest version, so "v2, v3…" never reorder.
            let latest = existing.versions.map(\.createdAt).max() ?? .distantPast
            let version = TrackVersion(
                audioFileName: fileName,
                originalFileName: url.lastPathComponent,
                duration: analysis?.duration ?? 0,
                createdAt: max(.libraryNow, latest.addingTimeInterval(1)),
                name: trimmed?.isEmpty == false ? trimmed : nil
            )
            saveVersions(of: existing)
            save(version, of: trackID)
            updateTrack(trackID) { track in
                track.versions.append(version)
                track.currentVersionID = version.id
            }
            cloudStatus[trackID] = isInCloud ? .uploading : .local
            if let analysis {
                savePeaks(analysis.peaks, for: VersionKey(track: trackID, version: version.id))
            }
            detectKeyAndTempo(of: trackID, version: version.id)
            return version.id
        } catch {
            report(error, title: "Couldn't add the new version")
            return nil
        }
    }

    /// Makes an earlier (or later) version the one that plays by default.
    public func setCurrentVersion(_ versionID: UUID, of trackID: UUID) {
        guard tracks[trackID]?.versions.contains(where: { $0.id == versionID }) == true else { return }
        updateTrack(trackID) { $0.currentVersionID = versionID }
        adoptKeyAndTempo(of: versionID, for: trackID)
        refreshCloudStatus(of: trackID)
    }

    /// Labels a version ("rough mix", "with vocals"). An empty name clears it.
    public func renameVersion(_ versionID: UUID, of trackID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var track = tracks[trackID], let index = track.versions.firstIndex(where: { $0.id == versionID }) else { return }
        track.versions[index].name = trimmed.isEmpty ? nil : trimmed
        saveVersions(of: track)
        save(track.versions[index], of: trackID)
        updateTrack(trackID) { $0 = track }
    }

    /// The comments that would be deleted along with a version.
    public func comments(deletedWith versionID: UUID, of trackID: UUID) -> [TrackComment] {
        comments(for: trackID, version: versionID)
    }

    /// Deletes one version: its audio goes to the Trash, and its waveform and
    /// comments are removed. A track's only version can't be deleted (delete
    /// the track instead). If it was current, the newest remaining version
    /// becomes current.
    public func deleteVersion(_ versionID: UUID, of trackID: UUID) {
        guard let track = tracks[trackID], track.versions.count > 1,
              let version = track.versions.first(where: { $0.id == versionID }) else { return }
        let wasFirst = track.versions.first?.id == versionID
        // Includes version-less comments when deleting the first version
        // (they belong to it). Versions are only ever appended, so the first
        // version never changes otherwise.
        let doomedComments = comments(for: trackID, version: versionID)
        updateTrack(trackID) { track in
            track.versions.removeAll { $0.id == versionID }
            if track.currentVersionID == versionID {
                track.currentVersionID = track.versions.last?.id
            }
        }
        if track.currentVersionID == versionID, let current = tracks[trackID]?.currentVersionID {
            adoptKeyAndTempo(of: current, for: trackID, judgedBy: track)
        }
        peaks[VersionKey(track: trackID, version: versionID)] = nil
        for comment in doomedComments {
            deleteComment(comment.id, from: trackID)
        }

        let audio = layout.trackDir(trackID).appending(path: version.audioFileName, directoryHint: .notDirectory)
        let file = layout.versionFile(trackID: trackID, versionID: versionID)
        let waveform = layout.waveformFile(trackID: trackID, versionID: versionID)
        let legacyWaveform = layout.legacyWaveformFile(trackID)
        // The remaining versions need their own files before this one goes,
        // or a format-1 track would fall back to its stale single version.
        if let remaining = tracks[trackID] { saveVersions(of: remaining) }
        enqueue { disk in
            try await disk.remove(file)
            try await disk.trash(audio)
            try await disk.remove(waveform)
            if wasFirst { try await disk.remove(legacyWaveform) }
        }
        refreshCloudStatus(of: trackID)
    }

    func refreshCloudStatus(of trackID: UUID) {
        guard let url = audioURL(for: trackID) else { return }
        Task {
            cloudStatus[trackID] = await disk.cloudStatus(of: url)
        }
    }
}
