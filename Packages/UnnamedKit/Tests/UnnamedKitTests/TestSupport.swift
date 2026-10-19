import AVFoundation
import Foundation

enum TestAudio {
    /// Writes a sine-wave WAV whose loudness ramps up, so peaks are predictable.
    static func makeWAV(named name: String = "idea", seconds: Double = 2, in directory: URL) throws -> URL {
        let url = directory.appending(path: "\(name).wav")
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                let t = Double(i) / sampleRate
                let envelope = Double(i) / Double(frames)
                data[i] = Float(sin(2 * .pi * 440 * t) * envelope * 0.8)
            }
        }
        try file.write(from: buffer)
        return url
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "UnnamedKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
