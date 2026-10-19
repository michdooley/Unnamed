import Accelerate
import AVFoundation
import UniformTypeIdentifiers

/// Reads an audio file once to find its duration and a compact waveform
/// overview (one loudness value per bucket, 0...255).
public enum AudioAnalyzer {
    public struct Result: Sendable, Equatable {
        public var duration: TimeInterval
        public var peaks: [UInt8]
    }

    public static let defaultPeakCount = 800

    /// File types the importer accepts. Anything AVFoundation can decode works,
    /// these are just the ones offered in open panels.
    public static let supportedTypes: [UTType] = {
        var types: [UTType] = [.wav, .mp3, .aiff, .mpeg4Audio, .appleProtectedMPEG4Audio, .audio]
        for ext in ["flac", "caf", "aif", "aac", "m4a", "ogg", "opus"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    public static func isAudioFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio)
    }

    public static func analyze(url: URL, peakCount: Int = defaultPeakCount) async throws -> Result {
        do {
            return try analyzeWithAudioFile(url: url, peakCount: peakCount)
        } catch {
            // AVAudioFile can't open every container AVFoundation can play
            // (e.g. some AAC/ADTS files); fall back to AVAssetReader.
            return try await analyzeWithAssetReader(url: url, peakCount: peakCount)
        }
    }

    // MARK: - AVAudioFile path

    static func analyzeWithAudioFile(url: URL, peakCount: Int) throws -> Result {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, format.sampleRate > 0 else {
            return Result(duration: 0, peaks: [])
        }
        let duration = Double(totalFrames) / format.sampleRate
        var accumulator = PeakAccumulator(totalFrames: totalFrames, bucketCount: peakCount)

        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        while file.framePosition < totalFrames {
            try file.read(into: buffer, frameCount: chunk)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            let channelPointers = (0..<Int(format.channelCount)).map { UnsafePointer(channels[$0]) }
            accumulator.add(channels: channelPointers, frameCount: frames, stride: 1)
        }
        return Result(duration: duration, peaks: accumulator.normalizedPeaks())
    }

    // MARK: - AVAssetReader path

    static func analyzeWithAssetReader(url: URL, peakCount: Int) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let sampleRate: Double = 22_050
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadCorruptFile)
        }
        let estimatedFrames = Int64(max(1, duration * sampleRate))
        var accumulator = PeakAccumulator(totalFrames: estimatedFrames, bucketCount: peakCount)
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            // Block buffers can be non-contiguous, so copy rather than read in place.
            let length = CMBlockBufferGetDataLength(block)
            let frames = length / MemoryLayout<Float>.size
            guard frames > 0 else { continue }
            if samples.count < frames { samples = [Float](repeating: 0, count: frames) }
            let status = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * MemoryLayout<Float>.size, destination: raw.baseAddress!)
            }
            guard status == noErr else { continue }
            samples.withUnsafeBufferPointer { buffer in
                accumulator.add(channels: [buffer.baseAddress!], frameCount: frames, stride: 1)
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        return Result(duration: duration.isFinite ? duration : 0, peaks: accumulator.normalizedPeaks())
    }
}

/// Splits a stream of samples into `bucketCount` buckets and records the RMS
/// loudness of each one.
struct PeakAccumulator {
    let totalFrames: Int64
    let bucketCount: Int
    private var sumOfSquares: [Double]
    private var counts: [Int64]
    private var framesSeen: Int64 = 0

    init(totalFrames: Int64, bucketCount: Int) {
        self.bucketCount = max(1, bucketCount)
        self.totalFrames = max(1, totalFrames)
        sumOfSquares = Array(repeating: 0, count: self.bucketCount)
        counts = Array(repeating: 0, count: self.bucketCount)
    }

    mutating func add(channels: [UnsafePointer<Float>], frameCount: Int, stride: Int) {
        guard !channels.isEmpty else { return }
        let buckets = Int64(bucketCount)
        var offset = 0
        while offset < frameCount {
            // Frame f belongs to bucket floor(f * buckets / total). The last
            // bucket also absorbs any frames past an under-estimated total.
            let bucket = min(bucketCount - 1, Int(framesSeen * buckets / totalFrames))
            let bucketEnd = bucket == bucketCount - 1
                ? Int64.max
                : ((Int64(bucket) + 1) * totalFrames + buckets - 1) / buckets
            let n = Int(min(Int64(frameCount - offset), max(1, bucketEnd - framesSeen)))
            var total: Float = 0
            for channel in channels {
                var sumsq: Float = 0
                vDSP_svesq(channel + offset, vDSP_Stride(stride), &sumsq, vDSP_Length(n))
                total += sumsq
            }
            sumOfSquares[bucket] += Double(total) / Double(channels.count)
            counts[bucket] += Int64(n)
            offset += n
            framesSeen += Int64(n)
        }
    }

    func normalizedPeaks() -> [UInt8] {
        let rms = zip(sumOfSquares, counts).map { sum, count in count > 0 ? (sum / Double(count)).squareRoot() : 0 }
        // Trim buckets that never received samples (frame-count estimates can run long).
        let used = counts.lastIndex(where: { $0 > 0 }).map { $0 + 1 } ?? 0
        let values = Array(rms.prefix(used))
        guard let maxValue = values.max(), maxValue > 0 else {
            return Array(repeating: 0, count: values.count)
        }
        // A gentle curve keeps quiet passages visible next to loud ones.
        return values.map { value in
            let normalized = pow(value / maxValue, 0.7)
            return UInt8(clamping: Int((normalized * 255).rounded()))
        }
    }
}

public extension Array where Element == UInt8 {
    /// Resamples peaks to `count` values (taking the max of each bin) so a
    /// waveform can be drawn at any width.
    func resampled(to count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        guard !isEmpty else { return Array(repeating: 0, count: count) }
        if self.count == count { return self }
        var result = [UInt8](repeating: 0, count: count)
        let ratio = Double(self.count) / Double(count)
        for i in 0..<count {
            let start = Int(Double(i) * ratio)
            let end = Swift.max(start + 1, Swift.min(self.count, Int(Double(i + 1) * ratio)))
            if start >= self.count {
                result[i] = self[self.count - 1]
            } else {
                result[i] = self[start..<end].max() ?? 0
            }
        }
        return result
    }
}
