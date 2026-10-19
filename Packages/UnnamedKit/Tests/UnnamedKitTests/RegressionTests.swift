import Foundation
import MediaPlayer
import Testing
@testable import UnnamedKit

/// Bugs found in review, pinned so they stay fixed.
@MainActor
struct RegressionTests {
    private func makeLibrary(trackCount: Int) async throws -> (LibraryStore, TrackCollection, [UUID]) {
        let scratch = try TestAudio.temporaryDirectory()
        let urls = try (1...trackCount).map { try TestAudio.makeWAV(named: "t\($0)", seconds: 0.3, in: scratch) }
        let store = LibraryStore(root: scratch.appending(path: "Library"))
        await store.load()
        let collection = store.createCollection(title: "C")
        let ids = await store.importAudio(from: urls, into: collection.id)
        return (store, collection, ids)
    }

    private func makePlayer(_ store: LibraryStore) -> PlayerController {
        let defaults = UserDefaults(suiteName: "UnnamedKitTests-\(UUID().uuidString)")!
        let player = PlayerController(defaults: defaults)
        player.setVolume(0)
        player.library = store
        return player
    }

    @Test func droppingATrackOnItselfKeepsItInPlace() async throws {
        let (store, collection, ids) = try await makeLibrary(trackCount: 3)
        store.reorder([ids[0]], in: collection.id, before: ids[0])
        #expect(store.collections[collection.id]?.trackIDs == ids)
    }

    @Test func itemsCreatedInTheSameSecondHaveAStableOrder() async throws {
        let (store, _, _) = try await makeLibrary(trackCount: 3)
        let first = store.tracksNewestFirst.map(\.id)
        for _ in 0..<20 {
            #expect(store.tracksNewestFirst.map(\.id) == first)
        }
    }

    @Test func playingATrackOutsideTheGivenListPlaysThatTrack() async throws {
        let (store, collection, ids) = try await makeLibrary(trackCount: 3)
        store.removeTracks([ids[2]], from: collection.id)
        let player = makePlayer(store)

        player.play(trackIDs: store.collections[collection.id]!.trackIDs, startingAt: ids[2], context: collection.id)

        #expect(player.currentTrackID == ids[2])
        #expect(player.contextCollectionID == nil)
        player.stop()
    }

    @Test func nowPlayingArtworkCanBeRenderedOffTheMainThread() async throws {
        let (store, collection, ids) = try await makeLibrary(trackCount: 1)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        await store.setArtwork(forCollection: collection.id, from: .data(png))
        let player = makePlayer(store)
        player.play(collection: collection.id, startingAt: ids[0])

        let artwork = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        nonisolated(unsafe) let unsafeArtwork = artwork
        // MediaPlayer asks for the image on a background queue; this used to trap.
        let rendered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: unsafeArtwork.image(at: CGSize(width: 64, height: 64)) != nil)
            }
        }
        #expect(rendered)
        player.stop()
    }

    @Test func deletingACollectionKeepsTracksAnotherDeviceJustFiled() async throws {
        let (store, collection, ids) = try await makeLibrary(trackCount: 2)
        await store.flush()
        // Another device put the first track in a collection this Mac hasn't loaded yet.
        let other = TrackCollection(title: "Live", trackIDs: [ids[0]])
        try LibraryJSON.encoder().encode(other).write(to: store.layout.collectionFile(other.id).creatingParent())

        await store.deleteCollection(collection.id)

        #expect(store.tracks[ids[0]] != nil)
        #expect(store.tracks[ids[1]] == nil)
    }

    @Test func anUnreadableCollectionFileMeansNoTracksAreDeleted() async throws {
        let (store, collection, ids) = try await makeLibrary(trackCount: 2)
        await store.flush()
        try Data("{ half-synced".utf8).write(to: store.layout.collectionFile(UUID()).creatingParent())

        await store.deleteCollection(collection.id)

        #expect(store.collections[collection.id] == nil)
        #expect(Set(store.tracks.keys) == Set(ids))
    }

    @Test func theClockKeepsRunningAfterASeekBeforeTheTrackIsReady() async throws {
        let scratch = try TestAudio.temporaryDirectory()
        let url = try TestAudio.makeWAV(named: "long", seconds: 4, in: scratch)
        let store = LibraryStore(root: scratch.appending(path: "Library"))
        await store.load()
        let collection = store.createCollection(title: "C")
        let ids = await store.importAudio(from: [url], into: collection.id)
        let player = makePlayer(store)

        player.play(trackID: ids[0], at: 0.5, in: ids, context: collection.id)
        player.seek(to: 0.6)
        try await Task.sleep(for: .seconds(2.2))

        #expect(player.currentTime > 0.9)
        player.stop()
    }

    @Test func duplicatingWithoutACollectionKeepsTheCopyInOne() async throws {
        let (store, collection, ids) = try await makeLibrary(trackCount: 1)
        let copy = try #require(await store.duplicateTrack(ids[0], in: nil))
        #expect(store.collections[collection.id]?.trackIDs == [ids[0], copy])
    }
}

extension URL {
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
