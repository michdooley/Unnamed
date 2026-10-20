import AVFoundation
import Foundation
import Testing
@testable import UnnamedKit

/// Synthesized music for the key and tempo detector: chords with a bass line
/// and a melody, played on harmonic-rich tones, over a drum groove.
enum TestMusic {
    static let sampleRate = 22_050.0

    struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }

    /// Chord progressions, as (root, minor?) in semitones above the tonic.
    static func progression(minor: Bool) -> [(Int, Bool)] {
        // I–vi–IV–V, or i–iv–V–i with the raised leading tone.
        minor ? [(0, true), (5, true), (7, false), (0, true)] : [(0, false), (9, true), (5, false), (7, false)]
    }

    /// A song: four bars to a chord, `bpm` beats a minute, in `key`.
    /// `concertA` detunes the whole thing (432 for "A = 432").
    static func song(key: MusicalKey, bpm: Double, seconds: Double, concertA: Double = 440,
                     drums: Bool = true, harmony: Bool = true, seed: UInt64 = 1) -> [Float] {
        let count = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: count)
        var random = Random(state: seed)
        let beat = 60 / bpm
        func frequency(_ midi: Double) -> Double { concertA * pow(2, (midi - 69) / 12) }

        func addTone(midi: Double, start: Double, length: Double, level: Double) {
            let f = frequency(midi)
            let from = Int(start * sampleRate), to = min(count, Int((start + length) * sampleRate))
            guard from < to else { return }
            for i in from..<to {
                let t = Double(i - from) / sampleRate
                let envelope = min(1, t / 0.01) * exp(-t * 1.2) * min(1, (Double(to - i) / sampleRate) / 0.05)
                var value = 0.0
                for harmonic in 1...6 where f * Double(harmonic) < sampleRate / 2 {
                    value += sin(2 * .pi * f * Double(harmonic) * t) / Double(harmonic)
                }
                out[i] += Float(value * envelope * level)
            }
        }

        if harmony {
            let chords = progression(minor: key.isMinor)
            let scale = key.isMinor ? [0, 2, 3, 5, 7, 8, 11] : [0, 2, 4, 5, 7, 9, 11]
            let barLength = beat * 4
            var bar = 0
            while Double(bar) * barLength < seconds {
                let (root, minorChord) = chords[bar % chords.count]
                let start = Double(bar) * barLength
                let tonicMidi = 48 + Double(key.tonic)   // around C3
                // Bass: the root, on each half bar.
                for half in 0..<2 {
                    addTone(midi: tonicMidi - 12 + Double(root), start: start + Double(half) * beat * 2, length: beat * 2, level: 0.22)
                }
                // The chord, held for the bar.
                for interval in [0, minorChord ? 3 : 4, 7] {
                    addTone(midi: tonicMidi + Double(root + interval), start: start, length: barLength, level: 0.12)
                }
                // A melody on the scale, mostly on chord tones.
                for step in 0..<4 {
                    let degree = random.next() < 0.6 ? [0, 2, 4][Int(random.next() * 3)] : Int(random.next() * 7)
                    let note = scale[degree % 7]
                    addTone(midi: tonicMidi + 12 + Double(note), start: start + Double(step) * beat, length: beat, level: 0.1)
                }
                bar += 1
            }
        }

        if drums {
            var hatNoise = Random(state: seed &+ 99)
            var snareNoise = Random(state: seed &+ 7)
            var lowpass = 0.0
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let sinceBeat = t.truncatingRemainder(dividingBy: beat)
                let beatNumber = Int(t / beat) % 4
                var value = 0.0
                if beatNumber == 0 || beatNumber == 2 {
                    value += sin(2 * .pi * (50 + 70 * exp(-sinceBeat * 25)) * sinceBeat) * exp(-sinceBeat * 8) * 0.6
                } else {
                    value += (snareNoise.next() * 2 - 1) * exp(-sinceBeat * 18) * 0.25
                    value += sin(2 * .pi * 190 * sinceBeat) * exp(-sinceBeat * 20) * 0.15
                }
                // Closed hi-hat on every eighth: high-passed noise.
                let sinceEighth = t.truncatingRemainder(dividingBy: beat / 2)
                let noise = hatNoise.next() * 2 - 1
                lowpass += (noise - lowpass) * 0.3
                value += (noise - lowpass) * exp(-sinceEighth * 60) * 0.12
                out[i] += Float(value)
            }
        }
        return out
    }

    /// Writes samples as a mono 16-bit WAV file.
    static func writeWAV(_ samples: [Float], named name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: "\(name).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let peak = max(1, samples.map(abs).max() ?? 1)
        for (i, sample) in samples.enumerated() { buffer.floatChannelData![0][i] = sample / peak * 0.9 }
        try file.write(from: buffer)
        return url
    }

    static func noise(seconds: Double, seed: UInt64 = 5) -> [Float] {
        var random = Random(state: seed)
        return (0..<Int(seconds * sampleRate)).map { _ in Float(random.next() * 2 - 1) * 0.3 }
    }
}

struct MusicAnalyzerTests {
    private func analyze(_ samples: [Float]) -> MusicAnalyzer.Result {
        MusicAnalyzer.analyze(samples: samples, sampleRate: TestMusic.sampleRate)
    }

    static let keys = [
        MusicalKey(tonic: 0, isMinor: false), MusicalKey(tonic: 9, isMinor: true), MusicalKey(tonic: 6, isMinor: true),
        MusicalKey(tonic: 3, isMinor: false), MusicalKey(tonic: 7, isMinor: false), MusicalKey(tonic: 2, isMinor: true),
    ]

    @Test(arguments: zip([84.0, 96, 120, 128, 140, 100], keys))
    func findsTheTempoAndKey(bpm: Double, key: MusicalKey) {
        let result = analyze(TestMusic.song(key: key, bpm: bpm, seconds: 24, seed: UInt64(bpm)))
        #expect(result.bpm == bpm)
        #expect(result.key == key)
    }

    @Test func aBalladWithBusyHiHatsMayReadAsDoubleTime() {
        // A known limitation: either answer is musically defensible.
        let result = analyze(TestMusic.song(key: MusicalKey(tonic: 0, isMinor: false), bpm: 72, seconds: 30))
        #expect(result.bpm == 72 || result.bpm == 144)
        #expect(result.key == MusicalKey(tonic: 0, isMinor: false))
    }

    @Test func allowsForTuning() {
        // A = 432 Hz, a third of a semitone flat, is still G major.
        let result = analyze(TestMusic.song(key: MusicalKey(tonic: 7, isMinor: false), bpm: 110, seconds: 30, concertA: 432))
        #expect(result.key == MusicalKey(tonic: 7, isMinor: false))
        #expect(result.bpm == 110)
    }

    @Test func leavesOutWhatTheMusicDoesntSay() {
        let noise = analyze(TestMusic.noise(seconds: 20))
        #expect(noise.bpm == nil)
        #expect(noise.key == nil)

        let silence = analyze([Float](repeating: 0, count: Int(TestMusic.sampleRate * 10)))
        #expect(silence == MusicAnalyzer.Result(bpm: nil, key: nil))

        // Drums alone have a tempo but no key.
        let drums = analyze(TestMusic.song(key: MusicalKey(tonic: 0, isMinor: false), bpm: 100, seconds: 20, harmony: false))
        #expect(drums.bpm == 100)
        #expect(drums.key == nil)

        // Too short to tell a tempo from.
        let snippet = analyze(TestMusic.song(key: MusicalKey(tonic: 0, isMinor: false), bpm: 100, seconds: 3))
        #expect(snippet.bpm == nil)
    }

    @Test func chordsWithoutDrumsStillHaveAKey() {
        let pad = analyze(TestMusic.song(key: MusicalKey(tonic: 0, isMinor: false), bpm: 90, seconds: 30, drums: false))
        #expect(pad.key == MusicalKey(tonic: 0, isMinor: false))
    }

    @Test func readsAudioFiles() async throws {
        // A stereo file at 44.1 kHz, mixed down and resampled on the way in.
        let directory = try TestAudio.temporaryDirectory()
        let url = directory.appending(path: "song.caf")
        let mono = TestMusic.song(key: MusicalKey(tonic: 5, isMinor: false), bpm: 124, seconds: 25)
        let resampled = MusicAnalyzer.resample(mono, from: TestMusic.sampleRate, to: 44_100)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(resampled.count))!
        buffer.frameLength = AVAudioFrameCount(resampled.count)
        for channel in 0..<2 {
            resampled.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: resampled.count) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)

        let result = try await MusicAnalyzer.analyze(url: url)
        #expect(result.bpm == 124)
        #expect(result.key == MusicalKey(tonic: 5, isMinor: false))
    }

    @Test func namesKeysTheWayTheAppSpellsThem() {
        #expect(MusicalKey(tonic: 6, isMinor: true).name == "F♯ minor")
        #expect(MusicalKey(tonic: 10, isMinor: false).name == "B♭ major")
        #expect(MusicalKey(tonic: -1, isMinor: false).name == "B major")
        #expect(MusicalKey.all.count == 24)
    }
}
