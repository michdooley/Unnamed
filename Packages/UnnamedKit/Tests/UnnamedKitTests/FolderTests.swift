import Foundation
import Testing
@testable import UnnamedKit

@MainActor
struct FolderTests {
    private func makeStore() async throws -> LibraryStore {
        let store = LibraryStore(root: try TestAudio.temporaryDirectory().appending(path: "Library"))
        await store.load()
        return store
    }

    @Test func foldersHoldFoldersCollectionsAndTracks() async throws {
        let scratch = try TestAudio.temporaryDirectory()
        let wav = try TestAudio.makeWAV(named: "loose", seconds: 0.2, in: scratch)
        let store = try await makeStore()

        let records = store.createFolder(title: "2026 Records")
        let ep = store.createFolder(title: "EP", in: records.id)
        let album = store.createCollection(title: "Album", in: records.id)
        let loose = try #require(await store.importAudio(from: [wav], folder: ep.id).first)

        #expect(store.subfolders(of: nil).map(\.title) == ["2026 Records"])
        #expect(store.subfolders(of: records.id).map(\.title) == ["EP"])
        #expect(store.collections(inFolder: records.id).map(\.id) == [album.id])
        #expect(store.collections(inFolder: nil).isEmpty)
        #expect(store.looseTracks(inFolder: ep.id).map(\.id) == [loose])
        #expect(store.folderPath(to: ep.id).map(\.title) == ["2026 Records", "EP"])
        #expect(store.contentCount(ofFolder: records.id) == (1, 1, 0))
        await store.flush()

        let reopened = LibraryStore(root: store.root)
        await reopened.load()
        #expect(reopened.folders == store.folders)
        #expect(reopened.folder(ofCollection: album.id) == records.id)
        #expect(reopened.folder(ofTrack: loose) == ep.id)
    }

    @Test func aFolderCantMoveIntoItself() async throws {
        let store = try await makeStore()
        let a = store.createFolder(title: "A")
        let b = store.createFolder(title: "B", in: a.id)
        let c = store.createFolder(title: "C", in: b.id)

        #expect(!store.moveFolder(a.id, into: a.id))
        #expect(!store.moveFolder(a.id, into: c.id))
        #expect(store.moveFolder(c.id, into: nil))
        #expect(store.parentFolder(of: c.id) == nil)
    }

    @Test func deletingAFolderMovesItsContentsUp() async throws {
        let store = try await makeStore()
        let outer = store.createFolder(title: "Outer")
        let inner = store.createFolder(title: "Inner", in: outer.id)
        let deeper = store.createFolder(title: "Deeper", in: inner.id)
        let collection = store.createCollection(title: "Album", in: inner.id)

        store.deleteFolder(inner.id)

        #expect(store.folders[inner.id] == nil)
        #expect(store.parentFolder(of: deeper.id) == outer.id)
        #expect(store.folder(ofCollection: collection.id) == outer.id)
        #expect(store.collections[collection.id] != nil)
    }

    @Test func conflictingMovesFromTwoDevicesDontHideFolders() async throws {
        let store = try await makeStore()
        let a = store.createFolder(title: "A")
        let b = store.createFolder(title: "B")
        let child = store.createFolder(title: "Child", in: a.id)
        await store.flush()

        // Offline, one device moves A into B while another moves B into A.
        for (folder, parent) in [(a, b.id), (b, a.id)] {
            var moved = folder
            moved.parentID = parent
            try LibraryJSON.encoder().encode(moved).write(to: store.layout.folderFile(folder.id))
        }
        await store.reload()

        // Neither can be inside the other, so both surface at the top level.
        #expect(Set(store.subfolders(of: nil).map(\.id)) == [a.id, b.id])
        #expect(store.parentFolder(of: child.id) == a.id)
        #expect(store.folderPath(to: child.id).map(\.title) == ["A", "Child"])

        // Choosing "move A into B" repairs the loop.
        #expect(store.moveFolder(a.id, into: b.id))
        #expect(store.parentFolder(of: a.id) == b.id)
        #expect(store.parentFolder(of: b.id) == nil)
    }

    @Test func itemsInAFolderDeletedElsewhereAppearAtTheTopLevel() async throws {
        let store = try await makeStore()
        let folder = store.createFolder(title: "Gone")
        let collection = store.createCollection(title: "Album", in: folder.id)
        await store.flush()

        try FileManager.default.removeItem(at: store.layout.folderDir(folder.id))
        await store.reload()

        #expect(store.collections(inFolder: nil).map(\.id) == [collection.id])
    }
}
