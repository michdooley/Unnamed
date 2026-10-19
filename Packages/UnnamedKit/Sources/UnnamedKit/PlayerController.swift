import AVFoundation
import Foundation
import MediaPlayer
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Plays tracks from a `LibraryStore`: queue, shuffle, repeat, seeking,
/// and the system Now Playing / media-key integration.
@MainActor
@Observable
public final class PlayerController {
    public private(set) var queue = PlaybackQueue()
    public private(set) var currentTrackID: UUID?
    /// A specific version being played instead of the track's current one
    /// (nil means "whatever version is current").
    public private(set) var playingVersionID: UUID?
    /// The collection the current queue was started from, if any.
    public private(set) var contextCollectionID: UUID?
    public private(set) var isPlaying = false
    /// True while the current track is being fetched from iCloud.
    public private(set) var isLoading = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var volume: Double
    public var problem: String?

    public var shuffle: Bool { queue.shuffle }
    public var repeatMode: RepeatMode { queue.repeatMode }
    public var progress: Double { duration > 0 ? min(1, max(0, currentTime / duration)) : 0 }
    public var hasTrack: Bool { currentTrackID != nil }

    /// The version of `trackID` that's loaded, if that track is the current one.
    public func playingVersion(of trackID: UUID) -> UUID? {
        guard currentTrackID == trackID else { return nil }
        return playingVersionID ?? library?.tracks[trackID]?.currentVersion?.id
    }

    @ObservationIgnored public weak var library: LibraryStore?
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The audio file the current track was started from (set before download finishes).
    @ObservationIgnored private var loadingURL: URL?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var failureObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var seekGeneration = 0
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private let nowPlaying = NowPlayingBridge()
    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let volume = "player.volume"
        static let shuffle = "player.shuffle"
        static let repeatMode = "player.repeat"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 0.85
        queue.setShuffle(defaults.bool(forKey: Keys.shuffle))
        queue.repeatMode = RepeatMode(rawValue: defaults.string(forKey: Keys.repeatMode) ?? "") ?? .off
        player.volume = Float(volume)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 24), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.timeDidChange(time.seconds) }
        }
        nowPlaying.install(on: self)
    }

    // MARK: - Starting playback

    /// Plays a collection from the top (or from `trackID`).
    public func play(collection collectionID: UUID, startingAt trackID: UUID? = nil) {
        guard let collection = library?.collections[collectionID] else { return }
        play(trackIDs: collection.trackIDs, startingAt: trackID, context: collectionID)
    }

    public func play(trackIDs: [UUID], startingAt trackID: UUID? = nil, context: UUID? = nil) {
        var playable = trackIDs.filter { library?.tracks[$0] != nil }
        var context = context
        if let trackID, !playable.contains(trackID) {
            // e.g. an "up next" track opened from a collection it isn't in.
            playable = library?.tracks[trackID] != nil ? [trackID] : []
            context = nil
        }
        guard !playable.isEmpty else { return }
        queue.load(playable, startAt: trackID)
        contextCollectionID = context
        startCurrent(at: 0, autoplay: true)
    }

    /// Clicking a track: plays it, or toggles pause if it's already the current track.
    public func playOrToggle(trackID: UUID, in trackIDs: [UUID], context: UUID?) {
        if currentTrackID == trackID {
            togglePlayPause()
        } else {
            play(trackIDs: trackIDs, startingAt: trackID, context: context)
        }
    }

    /// Plays a track starting at a specific time (e.g. clicking a comment).
    public func play(trackID: UUID, at time: TimeInterval, in trackIDs: [UUID], context: UUID?) {
        if currentTrackID == trackID {
            seek(to: time)
            resume()
        } else {
            let ids = trackIDs.contains(trackID) ? trackIDs : [trackID]
            queue.load(ids.filter { library?.tracks[$0] != nil }, startAt: trackID)
            contextCollectionID = context
            startCurrent(at: time, autoplay: true)
        }
    }

    /// Plays one version of a track (its current version when `version` is nil).
    public func play(trackID: UUID, version: UUID?, at time: TimeInterval = 0, in trackIDs: [UUID], context: UUID?) {
        guard let track = library?.tracks[trackID] else { return }
        let version = version == track.currentVersionID ? nil : version
        if currentTrackID == trackID {
            // Compare the versions actually meant, not the nil-means-current shorthand.
            if (version ?? track.currentVersionID) == playingVersion(of: trackID) {
                seek(to: time)
                resume()
            } else {
                startCurrent(at: time, autoplay: true, version: version)
            }
            return
        }
        let ids = trackIDs.contains(trackID) ? trackIDs : [trackID]
        queue.load(ids.filter { library?.tracks[$0] != nil }, startAt: trackID)
        contextCollectionID = trackIDs.contains(trackID) ? context : nil
        startCurrent(at: time, autoplay: true, version: version)
    }

    public func addToQueue(_ trackID: UUID) {
        if currentTrackID == nil {
            play(trackIDs: [trackID])
        } else {
            queue.enqueue(trackID)
        }
    }

    // MARK: - Transport

    public func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    public func resume() {
        guard currentTrackID != nil else { return }
        isPlaying = true
        if player.currentItem == nil {
            if !isLoading { startCurrent(at: currentTime, autoplay: true, version: playingVersionID) }
        } else {
            player.play()
        }
        updateNowPlaying()
    }

    public func pause() {
        isPlaying = false
        player.pause()
        updateNowPlaying()
    }

    public func next() {
        advance(automatic: false)
    }

    /// Restarts the track if more than a few seconds in, otherwise goes back one.
    public func previous() {
        if currentTime > 3 {
            seek(to: 0)
        } else if let id = queue.goBack() {
            // Landing on the same track (a one-track queue) keeps its version.
            startCurrent(at: 0, autoplay: isPlaying, version: id == currentTrackID ? playingVersionID : nil)
        } else {
            seek(to: 0)
        }
    }

    public func seek(to time: TimeInterval) {
        guard currentTrackID != nil else { return }
        let target = max(0, duration > 0 ? min(time, duration) : time)
        currentTime = target
        updateNowPlaying()
        // While the track is still loading (e.g. downloading from iCloud) just
        // remember the position; `load(url:)` starts from `currentTime`.
        guard player.currentItem != nil else { return }
        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeeking = false
            }
        }
    }

    public func seek(toFraction fraction: Double) {
        seek(to: fraction * duration)
    }

    public func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    public func toggleShuffle() {
        queue.setShuffle(!queue.shuffle)
        defaults.set(queue.shuffle, forKey: Keys.shuffle)
    }

    public func cycleRepeatMode() {
        queue.repeatMode = queue.repeatMode.next
        defaults.set(queue.repeatMode.rawValue, forKey: Keys.repeatMode)
    }

    public func setVolume(_ value: Double) {
        volume = min(1, max(0, value))
        player.volume = Float(volume)
        defaults.set(volume, forKey: Keys.volume)
    }

    public func stop() {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue.clear()
        queue.setShuffle(defaults.bool(forKey: Keys.shuffle))
        queue.repeatMode = RepeatMode(rawValue: defaults.string(forKey: Keys.repeatMode) ?? "") ?? .off
        currentTrackID = nil
        playingVersionID = nil
        loadingURL = nil
        statusObservation = nil
        contextCollectionID = nil
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        nowPlaying.clear()
    }

    // MARK: - Library changes

    /// Call when the library changes: drops deleted tracks from the queue and
    /// reloads the current track if its audio file was replaced.
    public func libraryDidChange() {
        guard let library else { return }
        let referenced = Set(queue.baseOrder + queue.upNext + [currentTrackID].compactMap { $0 })
        let missing = referenced.filter { library.tracks[$0] == nil }
        if !missing.isEmpty {
            let currentRemoved = currentTrackID.map(missing.contains) ?? false
            for id in missing { queue.remove(id) }
            if currentRemoved {
                if queue.advance(automatic: false) != nil {
                    startCurrent(at: 0, autoplay: isPlaying)
                } else {
                    stop()
                }
                return
            }
        }
        if let id = currentTrackID, let track = library.tracks[id] {
            if playingVersionID != nil, playingVersionID == track.currentVersionID {
                // The version being played was just made current.
                playingVersionID = nil
            }
            if let version = playingVersionID, track.version(version) == nil {
                // The version being played was deleted: fall back to the current one.
                startCurrent(at: 0, autoplay: isPlaying)
            } else if let loading = loadingURL,
               let expected = library.audioURL(for: id, version: playingVersionID),
               loading.standardizedFileURL != expected.standardizedFileURL {
                // A different version became current (here or on another device).
                startCurrent(at: 0, autoplay: isPlaying, version: playingVersionID)
            } else if let length = track.version(playingVersionID)?.duration, length > 0,
                      abs(length - duration) > 0.5, player.currentItem == nil {
                duration = length
            }
            updateNowPlaying()
        }
    }

    // MARK: - Internals

    private func advance(automatic: Bool) {
        let previous = currentTrackID
        guard let next = queue.advance(automatic: automatic) else {
            if automatic {
                // End of the queue: park at the start of the last track.
                isPlaying = false
                seek(to: 0)
                updateNowPlaying()
            }
            return
        }
        if automatic, next == previous {
            seek(to: 0)
            player.play()
            return
        }
        startCurrent(at: 0, autoplay: automatic || isPlaying, version: next == previous ? playingVersionID : nil)
    }

    /// Loads the queue's current track. `version` picks a specific version;
    /// every other caller gets the track's current version.
    private func startCurrent(at time: TimeInterval, autoplay: Bool, version: UUID? = nil) {
        guard let id = queue.current, let library, let track = library.tracks[id] else {
            stop()
            return
        }
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTrackID = id
        playingVersionID = track.version(version) == nil ? nil : version
        let version = playingVersionID
        loadingURL = library.audioURL(for: id, version: version)
        duration = track.version(version)?.duration ?? track.duration
        currentTime = time
        isPlaying = autoplay
        isLoading = true
        updateNowPlaying()

        loadTask = Task { [weak self] in
            do {
                let url = try await library.ensureDownloaded(id, version: version)
                guard let self, !Task.isCancelled, self.currentTrackID == id else { return }
                self.isLoading = false
                self.load(url: url)
            } catch {
                guard let self, !Task.isCancelled, self.currentTrackID == id else { return }
                self.isLoading = false
                self.isPlaying = false
                self.problem = "Couldn't play “\(track.title)”. \(error.localizedDescription)"
                self.updateNowPlaying()
            }
        }
    }

    private func load(url: URL) {
        let item = AVPlayerItem(url: url)
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(automatic: true) }
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemFailed() }
        }
        statusObservation = Self.observeFailure(of: item) { [weak self] in
            Task { @MainActor in self?.itemFailed() }
        }
        player.replaceCurrentItem(with: item)
        if currentTime > 0 {
            seek(to: currentTime)
        }
        if isPlaying {
            player.play()
        }
        if duration <= 0 {
            let asset = item.asset
            let id = currentTrackID
            Task { [weak self] in
                guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 else { return }
                guard let self, self.currentTrackID == id else { return }
                self.duration = seconds
                self.updateNowPlaying()
            }
        }
    }

    /// KVO can fire on any thread, so the handler must not be main-actor isolated.
    nonisolated private static func observeFailure(of item: AVPlayerItem, _ onFailure: @escaping @Sendable () -> Void) -> NSKeyValueObservation {
        item.observe(\.status) { item, _ in
            if item.status == .failed { onFailure() }
        }
    }

    private func itemFailed() {
        let title = currentTrackID.flatMap { library?.tracks[$0]?.title } ?? "this track"
        player.pause()
        isPlaying = false
        problem = "Couldn't play “\(title)”. The audio file may be damaged or in a format macOS can't play."
        updateNowPlaying()
    }

    private func timeDidChange(_ seconds: Double) {
        guard !isSeeking, player.currentItem != nil, seconds.isFinite else { return }
        currentTime = seconds
    }

    private func updateNowPlaying() {
        guard let id = currentTrackID, let track = library?.tracks[id] else {
            nowPlaying.clear()
            return
        }
        let collectionTitle = contextCollectionID.flatMap { library?.collections[$0]?.title }
        let artwork = library?.artworkURL(forTrack: id) ?? contextCollectionID.flatMap { library?.artworkURL(forCollection: $0) }
        let title = playingVersionID.map { "\(track.title) (\(track.versionLabel(of: $0)))" } ?? track.title
        nowPlaying.update(
            title: title,
            collection: collectionTitle,
            duration: duration,
            elapsed: currentTime,
            isPlaying: isPlaying,
            artworkURL: artwork
        )
    }
}

/// Bridges the player to Control Center, the menu bar Now Playing widget and media keys.
@MainActor
private final class NowPlayingBridge {
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?

    func install(on controller: PlayerController) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak controller] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in controller?.seek(to: position) }
            return .success
        }
    }

    func update(title: String, collection: String?, duration: TimeInterval, elapsed: TimeInterval, isPlaying: Bool, artworkURL: URL?) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let collection {
            info[MPMediaItemPropertyAlbumTitle] = collection
            info[MPMediaItemPropertyArtist] = collection
        }
        if artworkURL != self.artworkURL {
            self.artworkURL = artworkURL
            artwork = artworkURL.flatMap(Self.makeArtwork)
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    /// Nonisolated on purpose: MediaPlayer calls the artwork handler on a
    /// background queue, and a main-actor closure would trap there.
    nonisolated private static func makeArtwork(_ url: URL) -> MPMediaItemArtwork? {
        guard let cgImage = ArtworkProcessor.thumbnail(at: url, maxPixelSize: 600) else { return nil }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        #if os(macOS)
        let image = NSImage(cgImage: cgImage, size: size)
        #else
        let image = UIImage(cgImage: cgImage)
        #endif
        return MPMediaItemArtwork(boundsSize: size) { _ in image }
    }
}
