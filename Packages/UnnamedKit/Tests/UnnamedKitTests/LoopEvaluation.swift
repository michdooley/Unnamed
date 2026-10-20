import AVFoundation
import Foundation
import Testing
@testable import UnnamedKit

/// Measures the key and tempo detector against real recordings: the Apple
/// Loops that GarageBand and Logic install, whose files say their tempo and
/// key. Each loop is repeated to half a minute, as it would be in a song.
///
/// Only runs on request, given a JSON-lines list of loops (`path`, `key`,
/// `keyType`, `beats`):
///
///     UNNAMED_LOOPS=loops.jsonl swift test -c release --filter LoopEvaluation
@Suite(.enabled(if: ProcessInfo.processInfo.environment["UNNAMED_LOOPS"] != nil))
struct LoopEvaluation {
    struct Loop: Decodable {
        var path: String
        var key: String?
        var keyType: String?
        var beats: String?
        var category: String?
    }

    static let tonics: [String: Int] = [
        "C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6,
        "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11,
    ]

    static func decode(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: MusicAnalyzer.sampleRate, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: count)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }

    struct Tally {
        var exact = 0, octave = 0, fifth = 0, relative = 0, parallel = 0, wrong = 0, none = 0, total = 0
        var weighted: Double { (Double(exact) + 0.5 * Double(fifth) + 0.3 * Double(relative) + 0.2 * Double(parallel)) / Double(max(1, total)) }
    }

    static func judge(tempo bpm: Double?, truth: Double, into tally: inout Tally) {
        tally.total += 1
        guard let bpm else { tally.none += 1; return }
        if abs(bpm - truth) <= 1.5 {
            tally.exact += 1
        } else if [2.0, 0.5, 3.0, 1.0 / 3, 1.5, 2.0 / 3].contains(where: { abs(bpm - truth * $0) <= 1.5 }) {
            tally.octave += 1
        } else {
            tally.wrong += 1
        }
    }

    static func judge(key: MusicalKey?, truth: MusicalKey, into tally: inout Tally) {
        tally.total += 1
        guard let key else { tally.none += 1; return }
        let relative = truth.isMinor ? MusicalKey(tonic: truth.tonic + 3, isMinor: false) : MusicalKey(tonic: truth.tonic + 9, isMinor: true)
        if key == truth {
            tally.exact += 1
        } else if key.isMinor == truth.isMinor, [(truth.tonic + 7) % 12, (truth.tonic + 5) % 12].contains(key.tonic) {
            tally.fifth += 1
        } else if key == relative {
            tally.relative += 1
        } else if key.tonic == truth.tonic {
            tally.parallel += 1
        } else {
            tally.wrong += 1
        }
    }

    @Test func loops() async throws {
        let list = URL(filePath: ProcessInfo.processInfo.environment["UNNAMED_LOOPS"]!)
        let decoder = JSONDecoder()
        let loops = try String(contentsOf: list, encoding: .utf8).split(separator: "\n").compactMap { try? decoder.decode(Loop.self, from: Data($0.utf8)) }
        let limit = Int(ProcessInfo.processInfo.environment["UNNAMED_LOOP_LIMIT"] ?? "") ?? loops.count
        let only = ProcessInfo.processInfo.environment["UNNAMED_LOOP_CATEGORY"]

        // Alternatives to compare can be added to these lists.
        let tempoSettings: [(String, TempoEstimator.Settings)] = [("standard", TempoEstimator.standard)]
        let listenerSettings: [(String, Listener.Settings)] = [("standard", Listener.Settings())]
        let keySettings: [(String, KeyEstimator.Settings)] = [("standard", KeyEstimator.standard), ("Krumhansl–Kessler only", KeyEstimator.Settings(profiles: .krumhansl))]
        var tempoTallies = [Tally](repeating: Tally(), count: tempoSettings.count)
        var keyTallies = [[Tally]](repeating: [Tally](repeating: Tally(), count: keySettings.count), count: listenerSettings.count)

        for loop in loops.prefix(limit) where only == nil || loop.category == only {
            let audio = try await Self.decode(URL(filePath: loop.path))
            guard !audio.isEmpty, let beats = loop.beats.flatMap(Double.init), beats > 0 else { continue }
            let truthBPM = 60 * beats / (Double(audio.count) / MusicAnalyzer.sampleRate)
            var song: [Float] = []
            while Double(song.count) < 30 * MusicAnalyzer.sampleRate { song += audio }
            var truthKey: MusicalKey?
            if let name = loop.key, let tonic = Self.tonics[name], let type = loop.keyType, type == "major" || type == "minor" {
                truthKey = MusicalKey(tonic: tonic, isMinor: type == "minor")
            }
            for (index, (_, settings)) in listenerSettings.enumerated() {
                let listener = Listener(sampleRate: MusicAnalyzer.sampleRate, settings: settings)
                song.withUnsafeBufferPointer { listener.listen(to: $0) }
                if index == 0 {
                    for (t, (_, tempo)) in tempoSettings.enumerated() {
                        Self.judge(tempo: TempoEstimator.estimate(onsets: listener.onsets, frameRate: MusicAnalyzer.sampleRate / 256, settings: tempo)?.rounded(),
                                   truth: truthBPM, into: &tempoTallies[t])
                    }
                }
                if let truthKey {
                    for (k, (_, key)) in keySettings.enumerated() {
                        Self.judge(key: KeyEstimator.estimate(histogram: listener.pitchHistogram, settings: key), truth: truthKey, into: &keyTallies[index][k])
                    }
                }
            }
        }
        for (t, (name, _)) in tempoSettings.enumerated() {
            let tally = tempoTallies[t]
            print("SUMMARY tempo [\(name)]: \(tally.exact)/\(tally.total) exact, \(tally.octave) octave, \(tally.wrong) wrong, \(tally.none) none")
        }
        for (l, (listenerName, _)) in listenerSettings.enumerated() {
            for (k, (keyName, _)) in keySettings.enumerated() {
                let tally = keyTallies[l][k]
                print("SUMMARY key [\(listenerName) / \(keyName)]: \(tally.exact)/\(tally.total) exact, \(tally.fifth) fifth, \(tally.relative) relative, \(tally.parallel) parallel, \(tally.wrong) wrong, \(tally.none) none; score \(String(format: "%.3f", tally.weighted))")
            }
        }
    }

    /// Whole-band "songs": loops from the same pack, at the same tempo and in
    /// the same key (a drum loop, a bass line, keys, guitar…), played together.
    @Test func mixes() async throws {
        let list = URL(filePath: ProcessInfo.processInfo.environment["UNNAMED_LOOPS"]!)
        let decoder = JSONDecoder()
        let loops = try String(contentsOf: list, encoding: .utf8).split(separator: "\n").compactMap { try? decoder.decode(Loop.self, from: Data($0.utf8)) }
        struct Part { var loop: Loop; var audio: [Float]; var bpm: Double }
        var parts: [Part] = []
        for loop in loops {
            guard let beats = loop.beats.flatMap(Double.init), beats > 0 else { continue }
            let audio = try await Self.decode(URL(filePath: loop.path))
            guard !audio.isEmpty else { continue }
            parts.append(Part(loop: loop, audio: audio, bpm: (60 * beats / (Double(audio.count) / MusicAnalyzer.sampleRate)).rounded()))
        }
        // By pack and tempo; then each pitched key with whatever drums fit.
        let groups = Dictionary(grouping: parts) { "\(URL(filePath: $0.loop.path).deletingLastPathComponent().path)|\($0.bpm)" }
        var tempo = Tally(), key = Tally()
        for (_, group) in groups.sorted(by: { $0.key < $1.key }) {
            let drums = group.filter { $0.loop.category == "Drums" || $0.loop.category == "Percussion" }
            let pitched = group.filter { $0.loop.keyType == "major" || $0.loop.keyType == "minor" }
            let byKey = Dictionary(grouping: pitched) { "\($0.loop.key ?? "")|\($0.loop.keyType ?? "")" }
            for (_, sameKey) in byKey.sorted(by: { $0.key < $1.key }) {
                guard let first = sameKey.first, let name = first.loop.key, let tonic = Self.tonics[name] else { continue }
                // Up to three pitched parts of different kinds, and a drum loop.
                var chosen: [Part] = []
                for part in sameKey where !chosen.contains(where: { $0.loop.category == part.loop.category }) && chosen.count < 3 {
                    chosen.append(part)
                }
                if let drum = drums.first { chosen.append(drum) }
                guard chosen.count >= 2 else { continue }
                let length = Int(30 * MusicAnalyzer.sampleRate)
                var song = [Float](repeating: 0, count: length)
                for part in chosen {
                    for i in 0..<length { song[i] += part.audio[i % part.audio.count] / Float(chosen.count) }
                }
                let result = MusicAnalyzer.analyze(samples: song, sampleRate: MusicAnalyzer.sampleRate)
                let truthKey = MusicalKey(tonic: tonic, isMinor: first.loop.keyType == "minor")
                Self.judge(tempo: result.bpm, truth: first.bpm, into: &tempo)
                Self.judge(key: result.key, truth: truthKey, into: &key)
                print("MIX \(truthKey.name) @ \(first.bpm): got \(result.key?.name ?? "-") @ \(result.bpm.map { "\($0)" } ?? "-") [\(chosen.map { $0.loop.category ?? "" }.joined(separator: ", "))]")
            }
        }
        print("SUMMARY mixes tempo: \(tempo.exact)/\(tempo.total) exact, \(tempo.octave) octave, \(tempo.wrong) wrong, \(tempo.none) none")
        print("SUMMARY mixes key: \(key.exact)/\(key.total) exact, \(key.fifth) fifth, \(key.relative) relative, \(key.parallel) parallel, \(key.wrong) wrong, \(key.none) none; score \(String(format: "%.3f", key.weighted))")
    }

    /// Prints what's heard in a folder of songs (`UNNAMED_SONGS`): the answer,
    /// and the runners-up, for comparing with what the songs really are.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["UNNAMED_SONGS"] != nil))
    func songs() async throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["UNNAMED_SONGS"]!, directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter(AudioAnalyzer.isAudioFile).sorted { $0.path < $1.path }
        for file in files {
            let result = try await MusicAnalyzer.analyze(url: file)
            let audio = try await Self.decode(file)
            let listener = Listener(sampleRate: MusicAnalyzer.sampleRate)
            audio.withUnsafeBufferPointer { listener.listen(to: $0) }
            let beat = TempoEstimator.strongestBeat(onsets: listener.onsets, frameRate: MusicAnalyzer.sampleRate / 256)
            var ranked: [(String, Double)] = []
            if let (chroma, _) = KeyEstimator.chroma(histogram: listener.pitchHistogram) {
                for key in MusicalKey.all {
                    let profile = key.isMinor ? KeyEstimator.blendedMinor : KeyEstimator.blendedMajor
                    ranked.append((key.name, KeyEstimator.correlation(chroma, (0..<12).map { profile[((($0 - key.tonic) % 12) + 12) % 12] })))
                }
                ranked.sort { $0.1 > $1.1 }
            }
            let seconds = Double(audio.count) / MusicAnalyzer.sampleRate
            print("SONG \(file.lastPathComponent) [\(String(format: "%.2f", seconds)) s]: \(result.bpm.map { "\($0)" } ?? "-") BPM, \(result.key?.name ?? "-")  raw \(beat.map { String(format: "%.2f clarity %.2f", $0.bpm, $0.clarity) } ?? "-")  keys \(ranked.prefix(4).map { "\($0.0) \(String(format: "%.2f", $0.1))" }.joined(separator: ", "))")
        }
    }
}
