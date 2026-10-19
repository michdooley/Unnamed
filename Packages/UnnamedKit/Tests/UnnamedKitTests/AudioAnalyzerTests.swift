import Foundation
import Testing
@testable import UnnamedKit

struct AudioAnalyzerTests {
    @Test func measuresDurationAndPeaks() async throws {
        let dir = try TestAudio.temporaryDirectory()
        let wav = try TestAudio.makeWAV(seconds: 2, in: dir)

        let result = try await AudioAnalyzer.analyze(url: wav, peakCount: 100)

        #expect(abs(result.duration - 2) < 0.01)
        #expect(result.peaks.count == 100)
        #expect(result.peaks.max() == 255)
        // The test tone fades in, so the end is louder than the start.
        #expect(result.peaks[5] < result.peaks[95])
    }

    @Test func assetReaderFallbackAgrees() async throws {
        let dir = try TestAudio.temporaryDirectory()
        let wav = try TestAudio.makeWAV(seconds: 1, in: dir)

        let result = try await AudioAnalyzer.analyzeWithAssetReader(url: wav, peakCount: 50)

        #expect(abs(result.duration - 1) < 0.05)
        #expect(result.peaks.count >= 45)
        #expect(result.peaks[2] < result.peaks[40])
    }

    @Test func resamplesPeaksToAnyWidth() {
        let peaks: [UInt8] = [0, 10, 20, 30, 40, 50, 60, 70]
        #expect(peaks.resampled(to: 4) == [10, 30, 50, 70])
        #expect(peaks.resampled(to: 8) == peaks)
        #expect(peaks.resampled(to: 16).count == 16)
        #expect([UInt8]().resampled(to: 3) == [0, 0, 0])
    }

    @Test func recognisesAudioFiles() {
        #expect(AudioAnalyzer.isAudioFile(URL(filePath: "/a/b.wav")))
        #expect(AudioAnalyzer.isAudioFile(URL(filePath: "/a/b.MP3")))
        #expect(AudioAnalyzer.isAudioFile(URL(filePath: "/a/b.flac")))
        #expect(AudioAnalyzer.isAudioFile(URL(filePath: "/a/b.m4a")))
        #expect(!AudioAnalyzer.isAudioFile(URL(filePath: "/a/b.png")))
        #expect(!AudioAnalyzer.isAudioFile(URL(filePath: "/a/b.txt")))
    }
}
