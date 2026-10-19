import Foundation
import Testing
@testable import UnnamedKit

struct ScratchTests {
    /// One second of a 440 Hz tone at 48 kHz.
    private func tone(seconds: Double = 2) -> DecodedTrack {
        let rate = 48_000.0
        let count = Int(seconds * rate)
        let samples = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
        for i in 0..<count { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / rate) * 0.5) }
        return DecodedTrack(url: URL(filePath: "/tone"), sampleRate: rate, samples: samples)
    }

    /// Renders `seconds` of audio, returning the last buffer.
    @discardableResult
    private func render(_ voice: ScratchVoice, seconds: Double, hostTime: UInt64 = 1_000) -> [Float] {
        var buffer = [Float](repeating: 0, count: 512)
        let buffers = Int(seconds * voice.track.sampleRate / 512)
        for _ in 0..<buffers {
            buffer.withUnsafeMutableBufferPointer { voice.render(frames: 512, hostTime: hostTime, into: $0.baseAddress!) }
        }
        return buffer
    }

    @Test func theNeedleFollowsTheHand() {
        let voice = ScratchVoice(track: tone(), at: 0.5, feel: .disc)
        voice.setHand(seconds: -0.3)
        render(voice, seconds: 0.25)
        #expect(abs(voice.position.seconds - 0.2) < 0.002)
    }

    @Test func aHeldRecordIsSilent() {
        let voice = ScratchVoice(track: tone(), at: 0.5, feel: .disc)
        let last = render(voice, seconds: 0.2)
        #expect(last.map(abs).max()! < 0.01)
    }

    @Test func lettingGoSpinsBackUpToExactlyNormalSpeed() {
        let voice = ScratchVoice(track: tone(), at: 0.5, feel: .disc)
        voice.release(toSpeed: 1)
        render(voice, seconds: 0.5)
        #expect(voice.isLocked)
        // Spinning up covers half the distance it would have at full speed.
        #expect(abs(voice.position.seconds - (0.5 + 0.5 - ScratchVoice.spinUpTime / 2)) < 0.01)
    }

    @Test func aGrabbedRecordBrakesToAStop() {
        let voice = ScratchVoice(track: tone(), at: 0.5, feel: .disc, velocity: 1, braking: true)
        render(voice, seconds: 0.3)
        #expect(voice.isResting)
        #expect(abs(voice.position.seconds - (0.5 + ScratchVoice.brakeTime / 2)) < 0.01)
    }

    @Test func theHandTakesOverFromTheBrake() {
        let voice = ScratchVoice(track: tone(), at: 0.5, feel: .disc, velocity: 1, braking: true)
        render(voice, seconds: 0.02)
        let caught = voice.position.seconds
        voice.setHand(seconds: 0.1)
        render(voice, seconds: 0.3)
        #expect(abs(voice.position.seconds - (caught + 0.1)) < 0.01)
    }

    @Test func scrubbingTheBarAtPlayingSpeedPlaysSmoothly() {
        // A 60 s track on a 190 pt bar: at playing speed the pointer moves a
        // point (0.3 s of music) every 0.3 s.
        let voice = ScratchVoice(track: tone(seconds: 8), at: 1, feel: .bar)
        var hand = 0.0
        var speeds: [Double] = []
        for step in 0..<16 {
            hand += 0.3
            voice.setHand(seconds: hand)
            for _ in 0..<28 {   // ≈ 0.3 s of 512-frame buffers
                render(voice, seconds: 512 / 48_000)
                if step >= 6 { speeds.append(voice.speed) }
            }
        }
        #expect(speeds.min()! > 0.75)
        #expect(speeds.max()! < 1.25)
    }

    @Test func aTimedStartIsSilentUntilThen() {
        let voice = ScratchVoice(track: tone(), at: 0.5, feel: .disc, velocity: 1, startAt: 1_000 + HostClock.ticks(1))
        let last = render(voice, seconds: 0.2)
        #expect(last.allSatisfy { $0 == 0 })
        #expect(abs(voice.position.seconds - 0.5) < 0.0001)
    }

    @Test func aFadeEndsInSilence() {
        let voice = ScratchVoice(track: tone(), at: 0.5, feel: .disc)
        voice.release(toSpeed: 1)
        render(voice, seconds: 0.4)
        #expect(!voice.isSilent)
        voice.fadeOut()
        let last = render(voice, seconds: 0.05)
        #expect(voice.isSilent)
        #expect(last.map(abs).max()! < 0.001)
    }

    @Test func decodingMixesDownToMono() throws {
        let scratch = try TestAudio.temporaryDirectory()
        let url = try TestAudio.makeWAV(seconds: 1.5, in: scratch)
        let track = try DecodedTrack.decode(url)
        #expect(abs(track.duration - 1.5) < 0.01)
        #expect(track.samples.contains { $0 != 0 })
    }

    @MainActor
    @Test func scratchingMovesTheMusicAndPlaybackCarriesOn() async throws {
        let scratch = try TestAudio.temporaryDirectory()
        let url = try TestAudio.makeWAV(named: "long", seconds: 6, in: scratch)
        let store = LibraryStore(root: scratch.appending(path: "Library"))
        await store.load()
        let collection = store.createCollection(title: "C")
        let ids = await store.importAudio(from: [url], into: collection.id)
        let player = PlayerController(defaults: UserDefaults(suiteName: "UnnamedKitTests-\(UUID().uuidString)")!)
        player.setVolume(0)
        player.library = store
        player.play(collection: collection.id, startingAt: ids[0])
        try await Task.sleep(for: .seconds(0.5))
        player.prepareScratch()
        try await Task.sleep(for: .seconds(0.3))
        let before = player.currentTime

        player.beginScratch()
        #expect(player.isScratching)
        try await Task.sleep(for: .seconds(0.15))
        // The deck took over: AVPlayer stopped at the handover.
        #expect(player.engineRate == 0)
        player.scratch(by: 2)
        try await Task.sleep(for: .seconds(0.3))
        player.endScratch()
        try await Task.sleep(for: .seconds(1.2))

        #expect(!player.isScratching)
        #expect(player.isPlaying)
        #expect(player.timedHandOffs == 1)
        // Moved ~2 s by hand, then kept playing.
        #expect(player.currentTime > before + 2.5)
        let later = player.currentTime
        try await Task.sleep(for: .seconds(0.4))
        #expect(player.currentTime > later + 0.2)
        player.stop()
    }

    @MainActor
    @Test func lettingGoWhilePausedStaysPaused() async throws {
        let scratch = try TestAudio.temporaryDirectory()
        let url = try TestAudio.makeWAV(named: "long", seconds: 6, in: scratch)
        let store = LibraryStore(root: scratch.appending(path: "Library"))
        await store.load()
        let collection = store.createCollection(title: "C")
        let ids = await store.importAudio(from: [url], into: collection.id)
        let player = PlayerController(defaults: UserDefaults(suiteName: "UnnamedKitTests-\(UUID().uuidString)")!)
        player.setVolume(0)
        player.library = store
        player.play(collection: collection.id, startingAt: ids[0])
        try await Task.sleep(for: .seconds(0.4))
        player.pause()

        player.beginScratch(at: 3)
        try await Task.sleep(for: .seconds(0.2))
        player.endScratch()
        try await Task.sleep(for: .seconds(0.6))

        #expect(!player.isScratching)
        #expect(!player.isPlaying)
        #expect(abs(player.currentTime - 3) < 0.1)
        player.stop()
    }
}
