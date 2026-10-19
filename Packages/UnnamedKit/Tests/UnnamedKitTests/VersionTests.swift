import Foundation
import Testing
@testable import UnnamedKit

@MainActor
struct VersionTests {
    private func makeTrack(seconds: Double = 0.4) async throws -> (LibraryStore, UUID, URL) {
        let scratch = try TestAudio.temporaryDirectory()
        let wav = try TestAudio.makeWAV(named: "song", seconds: seconds, in: scratch)
        let store = LibraryStore(root: scratch.appending(path: "Library"))
        await store.load()
        let collection = store.createCollection(title: "Ideas")
        let id = try #require(await store.importAudio(from: [wav], into: collection.id).first)
        return (store, id, scratch)
    }

    @Test func aNewTrackHasOneVersionWithItsOwnID() async throws {
        let (store, id, _) = try await makeTrack()
        let track = try #require(store.tracks[id])
        #expect(track.versions.count == 1)
        #expect(track.currentVersionID == id)
        #expect(track.versionLabel(of: id) == "v1")
    }

    @Test func addingAVersionKeepsTheOldOneAndMakesTheNewOneCurrent() async throws {
        let (store, id, scratch) = try await makeTrack(seconds: 0.4)
        let v1 = try #require(store.tracks[id]?.currentVersionID)
        let mix = try TestAudio.makeWAV(named: "song", seconds: 0.8, in: scratch.appending(path: "v2"))

        let v2 = try #require(await store.addVersion(to: id, from: mix, name: "  new vocal "))

        let track = try #require(store.tracks[id])
        #expect(track.versions.map(\.id) == [v1, v2])
        #expect(track.currentVersionID == v2)
        #expect(track.versionLabel(of: v2) == "v2 · new vocal")
        #expect(abs(track.duration - 0.8) < 0.01)
        // Both files exist side by side, even though they had the same name.
        #expect(track.versions.map(\.audioFileName) == ["song.wav", "song 2.wav"])
        #expect(store.peaks(for: id).count == AudioAnalyzer.defaultPeakCount)
        #expect(store.peaks(for: id, version: v1) != store.peaks(for: id, version: v2))

        store.setCurrentVersion(v1, of: id)
        #expect(abs((store.tracks[id]?.duration ?? 0) - 0.4) < 0.01)
        await store.flush()

        let reopened = LibraryStore(root: store.root)
        await reopened.load()
        #expect(reopened.tracks[id] == store.tracks[id])
        #expect(reopened.peaks(for: id, version: v2) == store.peaks(for: id, version: v2))
    }

    @Test func commentsBelongToTheVersionTheyWereMadeOn() async throws {
        let (store, id, scratch) = try await makeTrack()
        let v1 = try #require(store.tracks[id]?.currentVersionID)
        store.addComment(to: id, at: 0.1, text: "on v1")
        let v2 = try #require(await store.addVersion(to: id, from: try TestAudio.makeWAV(named: "b", seconds: 0.5, in: scratch)))
        store.addComment(to: id, at: 0.2, text: "on v2")

        #expect(store.comments(for: id, version: nil).map(\.text) == ["on v2"])
        #expect(store.comments(for: id, version: v1).map(\.text) == ["on v1"])
        #expect(store.comments(for: id, version: v2).map(\.text) == ["on v2"])
    }

    @Test func deletingAVersionRemovesItsAudioWaveformAndComments() async throws {
        let (store, id, scratch) = try await makeTrack()
        let v1 = try #require(store.tracks[id]?.currentVersionID)
        let v2 = try #require(await store.addVersion(to: id, from: try TestAudio.makeWAV(named: "b", seconds: 0.5, in: scratch)))
        store.addComment(to: id, at: 0.2, text: "on v2")
        let v2Audio = try #require(store.audioURL(for: id, version: v2))

        store.deleteVersion(v2, of: id)
        #expect(store.tracks[id]?.versions.map(\.id) == [v1])
        #expect(store.tracks[id]?.currentVersionID == v1)
        #expect(store.comments[id] == nil)
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: v2Audio.path))

        // The last remaining version can't be deleted.
        store.deleteVersion(v1, of: id)
        #expect(store.tracks[id]?.versions.count == 1)
    }

    @Test func formatOneTracksLoadAsASingleVersion() async throws {
        let root = try TestAudio.temporaryDirectory()
        let id = UUID()
        let dir = root.appending(path: "Tracks/\(id.uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
        {"id":"\(id.uuidString)","title":"Old idea","createdAt":"2023-10-10T12:00:00Z","updatedAt":"2023-10-10T12:00:00Z",
         "audioFile":"old.wav","originalFileName":"old.wav","duration":12.5}
        """.utf8).write(to: dir.appending(path: "track.json"))
        try Data(#"{"version":1,"peaks":[1,2,3]}"#.utf8).write(to: dir.appending(path: "waveform.json"))
        try FileManager.default.createDirectory(at: dir.appending(path: "Comments"), withIntermediateDirectories: true)
        let commentID = UUID()
        try Data("""
        {"id":"\(commentID.uuidString)","timestamp":3,"text":"legacy","createdAt":"2023-10-10T12:00:00Z"}
        """.utf8).write(to: dir.appending(path: "Comments/\(commentID.uuidString).json"))

        let store = LibraryStore(root: root)
        await store.load()

        let track = try #require(store.tracks[id])
        #expect(track.versions.count == 1)
        #expect(track.audioFileName == "old.wav")
        #expect(track.duration == 12.5)
        #expect(store.peaks(for: id) == [1, 2, 3])
        #expect(store.comments(for: id, version: nil).map(\.text) == ["legacy"])

        // The single version takes the folder's ID.
        #expect(track.versions.first?.id == id)

        // Rewriting keeps the format-1 fields so older app versions still work.
        store.renameTrack(id, to: "Renamed")
        await store.flush()
        let json = try String(contentsOf: dir.appending(path: "track.json"), encoding: .utf8)
        #expect(json.contains(#""audioFile" : "old.wav""#))
    }

    @Test func aFormatOneTrackWithoutAnIDKeepsAStableVersionID() async throws {
        let root = try TestAudio.temporaryDirectory()
        let id = UUID()
        let dir = root.appending(path: "Tracks/\(id.uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"title":"No id","audioFile":"a.wav","duration":3}"#.utf8).write(to: dir.appending(path: "track.json"))

        let first = LibraryStore(root: root)
        await first.load()
        let second = LibraryStore(root: root)
        await second.load()
        #expect(first.tracks[id]?.versions.first?.id == id)
        #expect(second.tracks[id]?.versions.first?.id == id)
    }

    @Test func anOlderCopyOfTrackJSONCantEraseAVersion() async throws {
        let (store, id, scratch) = try await makeTrack()
        await store.flush()
        let trackFile = store.layout.trackFile(id)
        // What another device might still have, from before the new version.
        let stale = try Data(contentsOf: trackFile)

        let v2 = try #require(await store.addVersion(to: id, from: try TestAudio.makeWAV(named: "b", seconds: 0.5, in: scratch)))
        await store.flush()
        try stale.write(to: trackFile)     // the other device's edit wins the conflict
        await store.reload()

        #expect(store.tracks[id]?.versions.map(\.id).contains(v2) == true)
        #expect(store.tracks[id]?.versions.count == 2)
    }

    @Test func commentsCantBePostedToADeletedVersion() async throws {
        let (store, id, scratch) = try await makeTrack()
        let v2 = try #require(await store.addVersion(to: id, from: try TestAudio.makeWAV(named: "b", seconds: 0.5, in: scratch)))
        store.deleteVersion(v2, of: id)
        #expect(store.addComment(to: id, at: 1, text: "too late", version: v2) == nil)
        #expect(store.comments[id] == nil)
    }

    @Test func playsAnOlderVersionAndFallsBackWhenItIsDeleted() async throws {
        let (store, id, scratch) = try await makeTrack()
        let v1 = try #require(store.tracks[id]?.currentVersionID)
        let v2 = try #require(await store.addVersion(to: id, from: try TestAudio.makeWAV(named: "b", seconds: 0.5, in: scratch)))
        let defaults = UserDefaults(suiteName: "UnnamedKitTests-\(UUID().uuidString)")!
        let player = PlayerController(defaults: defaults)
        player.setVolume(0)
        player.library = store

        player.play(trackID: id, version: v1, in: [id], context: nil)
        #expect(player.playingVersionID == v1)
        #expect(player.playingVersion(of: id) == v1)
        #expect(abs(player.duration - 0.4) < 0.01)

        store.deleteVersion(v1, of: id)
        player.libraryDidChange()
        #expect(player.playingVersionID == nil)
        #expect(player.playingVersion(of: id) == v2)
        player.stop()
    }

    @Test func makingThePlayingVersionCurrentFollowsCurrentFromThenOn() async throws {
        let (store, id, scratch) = try await makeTrack()
        let v1 = try #require(store.tracks[id]?.currentVersionID)
        _ = try #require(await store.addVersion(to: id, from: try TestAudio.makeWAV(named: "b", seconds: 0.5, in: scratch)))
        let defaults = UserDefaults(suiteName: "UnnamedKitTests-\(UUID().uuidString)")!
        let player = PlayerController(defaults: defaults)
        player.setVolume(0)
        player.library = store

        player.play(trackID: id, version: v1, in: [id], context: nil)
        store.setCurrentVersion(v1, of: id)
        player.libraryDidChange()
        #expect(player.playingVersionID == nil)
        #expect(player.playingVersion(of: id) == v1)
        player.stop()
    }
}
