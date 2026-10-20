import Foundation
import Testing
@testable import UnnamedKit

/// The player publishes its clock only as often as a clock or waveform can
/// show the difference (each change redraws whatever displays it), while
/// `exactTime` is always to the moment.
@MainActor
struct PlayerClockTests {
    private func play(seconds: Double, lowPower: Bool = false) async throws -> (LibraryStore, PlayerController) {
        let scratch = try TestAudio.temporaryDirectory()
        let url = try TestAudio.makeWAV(named: "long", seconds: seconds, in: scratch)
        let store = LibraryStore(root: scratch.appending(path: "Library"))
        await store.load()
        let collection = store.createCollection(title: "C")
        let ids = await store.importAudio(from: [url], into: collection.id)
        let player = PlayerController(defaults: UserDefaults(suiteName: "UnnamedKitTests-\(UUID().uuidString)")!)
        player.setVolume(0)
        player.library = store
        player.lowPower = lowPower
        player.play(collection: collection.id, startingAt: ids[0])
        try await Task.sleep(for: .seconds(0.6))
        return (store, player)
    }

    /// How many times `currentTime` changes in a second of playback.
    private func changesInASecond(of player: PlayerController) async throws -> Int {
        var last = player.currentTime
        var changes = 0
        let end = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5))
            if player.currentTime != last {
                changes += 1
                last = player.currentTime
            }
        }
        return changes
    }

    @Test func theClockIsPublishedSparinglyButExactTimeIsExact() async throws {
        let (store, player) = try await play(seconds: 90)
        // A 90 s track moves a pixel of a wide waveform every 0.1 s: about
        // ten changes a second rather than the player's 24 ticks.
        let changes = try await changesInASecond(of: player)
        #expect(changes >= 5 && changes <= 14)

        let before = player.exactTime
        try await Task.sleep(for: .milliseconds(100))
        let after = player.exactTime
        #expect(after - before > 0.05 && after - before < 0.25)
        #expect(abs(player.exactTime - player.currentTime) < 0.2)
        player.stop()
        withExtendedLifetime(store) {}
    }

    @Test func lowPowerPublishesTheClockAFewTimesASecond() async throws {
        let (store, player) = try await play(seconds: 20, lowPower: true)
        let changes = try await changesInASecond(of: player)
        #expect(changes >= 2 && changes <= 5)
        player.stop()
        withExtendedLifetime(store) {}
    }

    @Test func pausingStopsTheClockWhereTheMusicStopped() async throws {
        let (store, player) = try await play(seconds: 90)
        try await Task.sleep(for: .seconds(0.3))
        let playing = player.exactTime
        player.pause()
        #expect(abs(player.currentTime - playing) < 0.05)
        #expect(player.exactTime == player.currentTime)
        player.stop()
        withExtendedLifetime(store) {}
    }
}
