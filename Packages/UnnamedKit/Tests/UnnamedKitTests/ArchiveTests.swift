import Foundation
import Testing
@testable import UnnamedKit

@MainActor
struct ArchiveTests {
    private func makeLibrary() async throws -> (LibraryStore, folder: LibraryFolder, album: TrackCollection, mixtape: TrackCollection, ids: [UUID]) {
        let scratch = try TestAudio.temporaryDirectory()
        let urls = try (1...3).map { try TestAudio.makeWAV(named: "t\($0)", seconds: 0.2, in: scratch) }
        let store = LibraryStore(root: scratch.appending(path: "Library"))
        await store.load()
        let folder = store.createFolder(title: "2026")
        let album = store.createCollection(title: "Album", in: folder.id)
        let mixtape = store.createCollection(title: "Mixtape")
        let ids = await store.importAudio(from: urls, into: album.id)
        store.addTracks([ids[0]], to: mixtape.id)
        return (store, folder, album, mixtape, ids)
    }

    @Test func archivingACollectionHidesItAndOnlyItsOwnTracks() async throws {
        let (store, folder, album, _, ids) = try await makeLibrary()

        store.setArchived(true, collection: album.id)

        #expect(store.collections(inFolder: folder.id).isEmpty)
        #expect(store.archivedCollections.map(\.id) == [album.id])
        #expect(store.isArchived(collection: album.id))
        // ids[0] is also on the mixtape, so it stays in view.
        #expect(store.activeTracksNewestFirst.map(\.id) == [ids[0]])
        // Nothing moved: the collection still holds every track.
        #expect(store.collections[album.id]?.trackIDs == ids)

        store.setArchived(false, collection: album.id)
        #expect(store.collections(inFolder: folder.id).map(\.id) == [album.id])
        #expect(store.activeTracksNewestFirst.count == 3)
    }

    @Test func archivingAFolderHidesEverythingInside() async throws {
        let (store, folder, album, _, _) = try await makeLibrary()
        let inner = store.createFolder(title: "Inner", in: folder.id)
        let innerCollection = store.createCollection(title: "Deep", in: inner.id)

        store.setArchived(true, folder: folder.id)

        #expect(store.subfolders(of: nil).isEmpty)
        #expect(store.isArchived(folder: inner.id))
        #expect(store.isArchived(collection: innerCollection.id))
        #expect(store.isArchived(collection: album.id))
        // Only the outermost archived thing is listed; the rest come along.
        #expect(store.archivedFolders.map(\.id) == [folder.id])
        #expect(store.archivedCollections.isEmpty)
        // Inside an archived folder, its contents still show normally.
        #expect(store.subfolders(of: folder.id).map(\.id) == [inner.id])
    }

    @Test func archivingATrackHidesItFromItsCollections() async throws {
        let (store, folder, album, mixtape, ids) = try await makeLibrary()

        store.setArchived(true, track: ids[1])

        #expect(store.tracks(in: album.id).map(\.id) == [ids[0], ids[2]])
        #expect(store.tracks(in: album.id, includingArchived: true).count == 3)
        #expect(store.trackIDs(inFolder: folder.id) == [ids[0], ids[2]])
        #expect(store.archivedTracks.map(\.id) == [ids[1]])
        #expect(store.isHidden(track: ids[1]))
        #expect(!store.isHidden(track: ids[0]))
        #expect(store.collections[mixtape.id]?.trackIDs == [ids[0]])
        await store.flush()

        let reopened = LibraryStore(root: store.root)
        await reopened.load()
        #expect(reopened.tracks[ids[1]]?.archivedAt != nil)
        #expect(reopened.tracks(in: album.id).count == 2)

        store.setArchived(false, track: ids[1])
        #expect(store.tracks(in: album.id).map(\.id) == ids)
    }

    @Test func playingACollectionSkipsArchivedTracks() async throws {
        let (store, _, album, _, ids) = try await makeLibrary()
        store.setArchived(true, track: ids[0])
        let player = PlayerController(defaults: UserDefaults(suiteName: "UnnamedKitTests-\(UUID().uuidString)")!)
        player.library = store
        player.setVolume(0)

        player.play(collection: album.id)

        #expect(player.queue.baseOrder == [ids[1], ids[2]])
        player.stop()
    }

    @Test func archivingAQueuedTrackTakesItOutOfTheQueue() async throws {
        let (store, _, album, _, ids) = try await makeLibrary()
        let player = PlayerController(defaults: UserDefaults(suiteName: "UnnamedKitTests-\(UUID().uuidString)")!)
        player.library = store
        player.setVolume(0)
        player.play(collection: album.id)

        store.setArchived(true, track: ids[2])
        store.setArchived(true, track: ids[0])   // the one playing finishes
        player.libraryDidChange()

        #expect(player.currentTrackID == ids[0])
        #expect(player.queue.baseOrder == [ids[0], ids[1]])
        player.stop()
    }

    @Test func deletingAnArchivedFolderKeepsItsContentsArchived() async throws {
        let (store, folder, album, _, _) = try await makeLibrary()
        let inner = store.createFolder(title: "Inner", in: folder.id)
        store.setArchived(true, folder: folder.id)

        store.deleteFolder(folder.id)

        #expect(store.isArchived(collection: album.id))
        #expect(store.isArchived(folder: inner.id))
        #expect(store.collections(inFolder: nil).allSatisfy { $0.id != album.id })
    }

    @Test func removingATrackKeepsItSomewhereVisible() async throws {
        let (store, _, album, mixtape, ids) = try await makeLibrary()
        // ids[0] is on the album and the mixtape.
        #expect(store.canRemove(track: ids[0], from: album.id))
        #expect(!store.canRemove(track: ids[1], from: album.id))

        store.setArchived(true, collection: mixtape.id)
        // Only the archived mixtape would be left: it would vanish.
        #expect(!store.canRemove(track: ids[0], from: album.id))
        // Tidying the archived mixtape is fine; it's still on the album.
        #expect(store.canRemove(track: ids[0], from: mixtape.id))
    }

    @Test func aDuplicateOfAnArchivedTrackIsNotArchived() async throws {
        let (store, _, album, _, ids) = try await makeLibrary()
        store.setArchived(true, track: ids[1])

        let copy = try #require(await store.duplicateTrack(ids[1], in: album.id))

        #expect(store.tracks[copy]?.archivedAt == nil)
    }

    @Test func thePlayerAlwaysStartsAtFullVolume() {
        let defaults = UserDefaults(suiteName: "UnnamedKitTests-\(UUID().uuidString)")!
        defaults.set(0.0, forKey: "player.volume")   // left behind by an older version
        let player = PlayerController(defaults: defaults)
        #expect(player.volume == 1)
        player.setVolume(0.3)
        #expect(PlayerController(defaults: defaults).volume == 1)
    }
}
