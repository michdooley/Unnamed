import Foundation
import Testing
@testable import UnnamedKit

/// Key and tempo are filled in from the audio when it's added, without
/// overriding what someone has typed.
@MainActor
struct KeyAndTempoTests {
    static let aMinor = MusicalKey(tonic: 9, isMinor: true)
    static let cMajor = MusicalKey(tonic: 0, isMinor: false)

    private func makeLibrary() async throws -> (LibraryStore, TrackCollection, URL) {
        let scratch = try TestAudio.temporaryDirectory()
        let store = LibraryStore(root: scratch.appending(path: "Library"))
        await store.load()
        return (store, store.createCollection(title: "Album"), scratch)
    }

    /// Synthesized off the main actor, so the player tests running alongside keep their timing.
    private func song(_ key: MusicalKey, bpm: Double, named name: String, in directory: URL) async throws -> URL {
        try await Task.detached {
            try TestMusic.writeWAV(TestMusic.song(key: key, bpm: bpm, seconds: 20, seed: UInt64(bpm)), named: name, in: directory)
        }.value
    }

    @Test func importingASongFillsInItsKeyAndTempo() async throws {
        let (store, collection, scratch) = try await makeLibrary()
        let url = try await song(Self.aMinor, bpm: 120, named: "groove", in: scratch)
        let id = try #require(await store.importAudio(from: [url], into: collection.id).first)
        await store.waitForDetection()

        let track = try #require(store.tracks[id])
        #expect(track.bpm == 120)
        #expect(track.musicalKey == "A minor")
        #expect(track.currentVersion?.detectedAt != nil)
        #expect(!store.isListening(to: id))

        // Both are kept on disk: the track's values and what was heard.
        await store.flush()
        let reopened = LibraryStore(root: store.root)
        await reopened.load()
        #expect(reopened.tracks[id]?.bpm == 120)
        #expect(reopened.tracks[id]?.musicalKey == "A minor")
        #expect(reopened.tracks[id]?.currentVersion?.detectedKey == "A minor")
        #expect(reopened.tracks[id]?.currentVersion?.detectedBPM == 120)
    }

    @Test func aNewVersionUpdatesDetectedValuesButNotTypedOnes() async throws {
        let (store, collection, scratch) = try await makeLibrary()
        let first = try await song(Self.aMinor, bpm: 120, named: "v1", in: scratch)
        let id = try #require(await store.importAudio(from: [first], into: collection.id).first)
        await store.waitForDetection()
        // Someone feels it in half time.
        store.updateTrack(id) { $0.bpm = 60 }

        let second = try await song(Self.cMajor, bpm: 96, named: "v2", in: scratch)
        let v2 = try #require(await store.addVersion(to: id, from: second))
        await store.waitForDetection()
        #expect(store.tracks[id]?.bpm == 60)
        #expect(store.tracks[id]?.musicalKey == "C major")
        #expect(store.tracks[id]?.version(v2)?.detectedBPM == 96)

        // Back to the first take: its key comes back with it.
        store.setCurrentVersion(id, of: id)
        #expect(store.tracks[id]?.musicalKey == "A minor")
        #expect(store.tracks[id]?.bpm == 60)

        // Asking for it explicitly replaces even typed values.
        let heard = await store.detectKeyAndTempo(of: id, replacing: true)?.value
        #expect(heard?.bpm == 120)
        #expect(store.tracks[id]?.bpm == 120)
    }

    @Test func deletingTheCurrentVersionBringsBackTheOthersValues() async throws {
        let (store, collection, scratch) = try await makeLibrary()
        let first = try await song(Self.aMinor, bpm: 120, named: "v1", in: scratch)
        let second = try await song(Self.cMajor, bpm: 96, named: "v2", in: scratch)
        let id = try #require(await store.importAudio(from: [first], into: collection.id).first)
        let v2 = try #require(await store.addVersion(to: id, from: second))
        await store.waitForDetection()
        #expect(store.tracks[id]?.bpm == 96)

        store.deleteVersion(v2, of: id)
        #expect(store.tracks[id]?.bpm == 120)
        #expect(store.tracks[id]?.musicalKey == "A minor")
    }

    @Test func listensToTracksMissingAKeyOrTempo() async throws {
        let (store, collection, scratch) = try await makeLibrary()
        let url = try await song(Self.cMajor, bpm: 128, named: "a", in: scratch)
        let id = try #require(await store.importAudio(from: [url], into: collection.id).first)
        await store.waitForDetection()
        // Already listened to: nothing to do.
        #expect(store.detectMissingKeysAndTempos() == 0)

        // A track from before detection existed.
        store.updateTrack(id) { track in
            track.bpm = nil
            track.musicalKey = nil
            track.versions[0].detectedAt = nil
        }
        #expect(store.detectMissingKeysAndTempos() == 1)
        await store.waitForDetection()
        #expect(store.tracks[id]?.bpm == 128)
        #expect(store.tracks[id]?.musicalKey == "C major")
    }

    @Test func listeningAQuitInterruptedPicksUpOnTheNextLaunch() async throws {
        let (store, collection, scratch) = try await makeLibrary()
        let url = try await song(Self.aMinor, bpm: 96, named: "recent", in: scratch)
        let id = try #require(await store.importAudio(from: [url], into: collection.id).first)
        await store.waitForDetection()
        // As if the app quit before it had listened.
        store.updateTrack(id) { track in
            track.bpm = nil
            track.musicalKey = nil
            track.versions[0].detectedAt = nil
        }
        // Only recent additions are picked up again.
        store.resumeDetection(now: Date().addingTimeInterval(2 * 24 * 3600))
        await store.waitForDetection()
        #expect(store.tracks[id]?.bpm == nil)

        store.resumeDetection()
        await store.waitForDetection()
        #expect(store.tracks[id]?.bpm == 96)
        #expect(store.tracks[id]?.musicalKey == "A minor")
    }
}
