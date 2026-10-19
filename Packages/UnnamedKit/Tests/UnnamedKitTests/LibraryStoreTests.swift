import Foundation
import Testing
@testable import UnnamedKit

@MainActor
struct LibraryStoreTests {
    @Test func createsTheLibraryLayout() async throws {
        let root = try TestAudio.temporaryDirectory().appending(path: "Library")
        let store = LibraryStore(root: root)
        await store.load()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: root.appending(path: "library.json").path))
        #expect(fm.fileExists(atPath: root.appending(path: "README.txt").path))
        #expect(fm.fileExists(atPath: root.appending(path: "Tracks").path))
        #expect(fm.fileExists(atPath: root.appending(path: "Collections").path))
        #expect(!store.isInCloud)
    }

    @Test func importsAudioAndPersistsEverything() async throws {
        let scratch = try TestAudio.temporaryDirectory()
        let root = scratch.appending(path: "Library")
        let wav = try TestAudio.makeWAV(named: "2023-08-15 atmos", seconds: 1.5, in: scratch)

        let store = LibraryStore(root: root)
        await store.load()
        let collection = store.createCollection(title: "  Snippets ")
        let imported = await store.importAudio(from: [wav, scratch.appending(path: "notes.txt")], into: collection.id)

        #expect(collection.title == "Snippets")
        #expect(imported.count == 1)
        let trackID = try #require(imported.first)
        let track = try #require(store.tracks[trackID])
        #expect(track.title == "2023-08-15 atmos")
        #expect(abs(track.duration - 1.5) < 0.01)
        #expect(store.peaks[trackID]?.count == AudioAnalyzer.defaultPeakCount)
        #expect(store.collections[collection.id]?.trackIDs == [trackID])
        #expect(store.cloudStatus[trackID] == .local)
        #expect(store.pendingImports.isEmpty)

        let audioURL = try #require(store.audioURL(for: trackID))
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(audioURL.lastPathComponent == "2023-08-15 atmos.wav")

        store.setNotes("needs a bridge", for: trackID)
        let comment = try #require(store.addComment(to: trackID, at: 0.75, text: "  love this drop ", author: "me"))
        #expect(comment.text == "love this drop")
        store.renameTrack(trackID, to: "atmos v2")
        store.updateTrack(trackID) { $0.bpm = 128; $0.musicalKey = "F# minor" }
        store.flushNotes()
        await store.flush()

        // A fresh store reading the same folder sees the same library.
        let reopened = LibraryStore(root: root)
        await reopened.load()
        #expect(reopened.tracks == store.tracks)
        #expect(reopened.collections == store.collections)
        #expect(reopened.notes[trackID] == "needs a bridge")
        #expect(reopened.comments[trackID] == [comment])
        #expect(reopened.peaks[trackID] == store.peaks[trackID])
        #expect(reopened.tracks[trackID]?.title == "atmos v2")
        #expect(reopened.tracks[trackID]?.bpm == 128)
    }

    @Test func managesCollectionMembershipAndOrder() async throws {
        let scratch = try TestAudio.temporaryDirectory()
        let urls = try (1...3).map { try TestAudio.makeWAV(named: "t\($0)", seconds: 0.2, in: scratch) }
        let store = LibraryStore(root: scratch.appending(path: "Library"))
        await store.load()

        let album = store.createCollection(title: "Album")
        let ids = await store.importAudio(from: urls, into: album.id)
        #expect(store.collections[album.id]?.trackIDs == ids)

        store.reorder([ids[2]], in: album.id, before: ids[0])
        #expect(store.collections[album.id]?.trackIDs == [ids[2], ids[0], ids[1]])
        store.reorder([ids[2]], in: album.id, before: nil)
        #expect(store.collections[album.id]?.trackIDs == ids)

        // A mixtape can reference tracks that also live elsewhere.
        let mixtape = store.createCollection(title: "Mixtape")
        store.addTracks([ids[1], ids[1], ids[0]], to: mixtape.id)
        #expect(store.collections[mixtape.id]?.trackIDs == [ids[1], ids[0]])
        #expect(store.collections(containing: ids[1]).map(\.title) == ["Album", "Mixtape"])

        store.moveTracks([ids[2]], from: album.id, to: mixtape.id)
        #expect(store.collections[album.id]?.trackIDs == [ids[0], ids[1]])
        #expect(store.collections[mixtape.id]?.trackIDs == [ids[1], ids[0], ids[2]])

        // Deleting a track removes it from every collection.
        store.deleteTrack(ids[0])
        #expect(store.collections[album.id]?.trackIDs == [ids[1]])
        #expect(store.collections[mixtape.id]?.trackIDs == [ids[1], ids[2]])
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: store.layout.trackDir(ids[0]).path))

        // Deleting a collection with its tracks keeps tracks used elsewhere.
        store.deleteCollection(mixtape.id, deleteTracks: true)
        #expect(store.tracks[ids[1]] != nil)
        #expect(store.tracks[ids[2]] == nil)
        await store.flush()

        let reopened = LibraryStore(root: store.root)
        await reopened.load()
        #expect(reopened.collections.count == 1)
        #expect(reopened.collections[album.id]?.trackIDs == [ids[1]])
        #expect(Set(reopened.tracks.keys) == [ids[1]])
    }

    @Test func duplicatesTracksWithTheirNotesAndComments() async throws {
        let scratch = try TestAudio.temporaryDirectory()
        let wav = try TestAudio.makeWAV(named: "idea", seconds: 0.3, in: scratch)
        let store = LibraryStore(root: scratch.appending(path: "Library"))
        await store.load()
        let collection = store.createCollection(title: "C")
        let id = try #require(await store.importAudio(from: [wav], into: collection.id).first)
        store.setNotes("lyrics", for: id)
        store.addComment(to: id, at: 0.1, text: "nice")

        let copyID = try #require(await store.duplicateTrack(id, in: collection.id))
        #expect(store.tracks[copyID]?.title == "idea copy")
        #expect(store.collections[collection.id]?.trackIDs == [id, copyID])
        await store.flush()

        let reopened = LibraryStore(root: store.root)
        await reopened.load()
        #expect(reopened.notes[copyID] == "lyrics")
        #expect(reopened.comments[copyID]?.map(\.text) == ["nice"])
        #expect(reopened.tracks[copyID]?.audioFileName == "idea.wav")
    }

    @Test func picksUpChangesMadeByAnotherDevice() async throws {
        let scratch = try TestAudio.temporaryDirectory()
        let root = scratch.appending(path: "Library")
        let mac = LibraryStore(root: root)
        let phone = LibraryStore(root: root)
        await mac.load()
        await phone.load()

        let collection = phone.createCollection(title: "From my phone")
        await phone.flush()
        #expect(mac.collections[collection.id] == nil)

        await mac.reload()
        #expect(mac.collections[collection.id]?.title == "From my phone")

        mac.renameCollection(collection.id, to: "Renamed on Mac")
        await mac.flush()
        await phone.reload()
        #expect(phone.collections[collection.id]?.title == "Renamed on Mac")
    }

    @Test func setsAndReplacesArtwork() async throws {
        let scratch = try TestAudio.temporaryDirectory()
        let store = LibraryStore(root: scratch.appending(path: "Library"))
        await store.load()
        let collection = store.createCollection(title: "Art")

        // A 1x1 PNG.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        await store.setArtwork(forCollection: collection.id, from: .data(png))
        let first = try #require(store.artworkURL(forCollection: collection.id))
        #expect(FileManager.default.fileExists(atPath: first.path))

        await store.setArtwork(forCollection: collection.id, from: .data(png))
        let second = try #require(store.artworkURL(forCollection: collection.id))
        #expect(first != second)
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: first.path))

        store.removeArtwork(forCollection: collection.id)
        await store.flush()
        #expect(store.artworkURL(forCollection: collection.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func toleratesForeignAndBrokenFiles() async throws {
        let root = try TestAudio.temporaryDirectory()
        let fm = FileManager.default
        let store = LibraryStore(root: root)
        await store.load()

        try fm.createDirectory(at: root.appending(path: "Tracks/not-a-uuid"), withIntermediateDirectories: true)
        let broken = root.appending(path: "Tracks/\(UUID().uuidString)")
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appending(path: "track.json"))
        let minimalID = UUID()
        let minimal = root.appending(path: "Collections/\(minimalID.uuidString)")
        try fm.createDirectory(at: minimal, withIntermediateDirectories: true)
        try Data(#"{"title":"Hand made"}"#.utf8).write(to: minimal.appending(path: "collection.json"))

        await store.reload()
        #expect(store.tracks.isEmpty)
        #expect(store.collections[minimalID]?.title == "Hand made")
        #expect(store.collections[minimalID]?.trackIDs == [])
    }
}
