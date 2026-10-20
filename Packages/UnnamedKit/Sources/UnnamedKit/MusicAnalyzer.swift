import Accelerate
import AVFoundation

/// A key, like "F♯ minor".
public struct MusicalKey: Hashable, Sendable, CustomStringConvertible {
    /// The tonic as a pitch class: 0 is C, 1 is C♯, … 11 is B.
    public var tonic: Int
    public var isMinor: Bool

    public init(tonic: Int, isMinor: Bool) {
        self.tonic = ((tonic % 12) + 12) % 12
        self.isMinor = isMinor
    }

    /// How the app spells the twelve notes.
    public static let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    /// Every key, majors first.
    public static let all: [MusicalKey] = (0..<12).map { MusicalKey(tonic: $0, isMinor: false) } + (0..<12).map { MusicalKey(tonic: $0, isMinor: true) }

    /// "F♯ minor": the form stored in a track's `key`.
    public var name: String { "\(Self.noteNames[tonic]) \(isMinor ? "minor" : "major")" }
    public var description: String { name }
}

/// Listens to a recording for its tempo and key, the way most tempo and key
/// finders do (aubio, librosa, libKeyFinder, Essentia), with nothing but
/// Accelerate.
///
/// Tempo: a spectral-flux onset envelope (how much new sound arrives in each
/// 12 ms), whose autocorrelation is searched for the beat period. Each
/// candidate is scored by the beat and its next three multiples, gently
/// preferring tempos near 110 BPM, which settles most double/half-time
/// ambiguity (not all: a ballad with busy hi-hats can read as double time).
///
/// Key: spectral peaks between 40 Hz and 2 kHz, less the overtones of lower
/// notes (which would otherwise sound like a fifth and a major third above
/// every note), are gathered into a pitch-class histogram at 10-cent
/// resolution, so the recording's tuning can be found and allowed for
/// (A = 432 Hz still reads as A). The twelve pitch classes are then matched
/// against major and minor key profiles: what this detector hears in music
/// whose key is known, steadied by Krumhansl and Kessler's ratings.
///
/// Measured with the Apple Loops that come with GarageBand, whose files say
/// their tempo and key (see `LoopEvaluation`). On 254 whole-band mixes of
/// loops that belong together: tempo exactly right 78% of the time, and
/// double, half or another multiple of it another 10%; key exactly right
/// 54% of the time, and a fifth away or the relative major or minor another
/// 19%. On the 1,725 loops one at a time (a single instrument is harder):
/// tempo 60% (+11%), key 46% (+24%).
///
/// Either answer is left out when the music doesn't make it clear (no steady
/// beat; no tonal centre), rather than guessed.
public enum MusicAnalyzer {
    public struct Result: Sendable, Equatable {
        /// Beats per minute, rounded to a whole number.
        public var bpm: Double?
        public var key: MusicalKey?
    }

    /// Everything is analysed at this rate (mono).
    static let sampleRate = 22_050.0
    /// Long recordings are judged by their first eight minutes.
    static let maxSeconds = 8 * 60.0

    public static func analyze(url: URL) async throws -> Result {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Reading blocks while AVFoundation decodes, so it happens on a queue
        // of its own: blocking Swift's shared threads (several recordings at
        // once) can starve the very work the reads are waiting for.
        let loaded = LoadedTrack(track: track)
        return try await withCheckedThrowingContinuation { continuation in
            readingQueue.async {
                continuation.resume(with: Swift.Result { try listen(to: asset, track: loaded.track) })
            }
        }
    }

    /// One recording at a time.
    private static let readingQueue = DispatchQueue(label: "MusicAnalyzer.reading", qos: .utility)

    /// A track that's been loaded is only read from, so it can cross to the reading queue.
    private struct LoadedTrack: @unchecked Sendable {
        let track: AVAssetTrack
    }

    private static func listen(to asset: AVURLAsset, track: AVAssetTrack) throws -> Result {
        // Two channels, mixed down here: a mono source is simply doubled.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }

        let listener = Listener(sampleRate: sampleRate)
        var interleaved: [Float] = []
        var mono: [Float] = []
        let limit = Int(maxSeconds * sampleRate)
        while listener.samplesHeard < limit, let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frames = length / (2 * MemoryLayout<Float>.size)
            guard frames > 0 else { continue }
            if interleaved.count < frames * 2 { interleaved = [Float](repeating: 0, count: frames * 2) }
            if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
            let status = interleaved.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 2 * MemoryLayout<Float>.size, destination: raw.baseAddress!)
            }
            guard status == noErr else { continue }
            interleaved.withUnsafeBufferPointer { source in
                mono.withUnsafeMutableBufferPointer { target in
                    // (left + right) / 2
                    vDSP_vadd(source.baseAddress!, 2, source.baseAddress! + 1, 2, target.baseAddress!, 1, vDSP_Length(frames))
                    var half: Float = 0.5
                    vDSP_vsmul(target.baseAddress!, 1, &half, target.baseAddress!, 1, vDSP_Length(frames))
                }
            }
            mono.withUnsafeBufferPointer { listener.listen(to: UnsafeBufferPointer(rebasing: $0.prefix(frames))) }
        }
        reader.cancelReading()
        return listener.conclude()
    }

    /// Analyses mono samples (at any rate; resampled to 22,050 Hz first).
    public static func analyze(samples: [Float], sampleRate rate: Double) -> Result {
        let listener = Listener(sampleRate: sampleRate)
        let input = rate == sampleRate ? samples : resample(samples, from: rate, to: sampleRate)
        input.withUnsafeBufferPointer { listener.listen(to: $0) }
        return listener.conclude()
    }

    /// Linear interpolation; plenty for analysis.
    static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float] {
        guard source > 0, !samples.isEmpty else { return [] }
        let count = Int(Double(samples.count) * target / source)
        let step = source / target
        return (0..<count).map { i in
            let position = Double(i) * step
            let index = Int(position)
            let fraction = Float(position - Double(index))
            let a = samples[min(index, samples.count - 1)], b = samples[min(index + 1, samples.count - 1)]
            return a + (b - a) * fraction
        }
    }
}

// MARK: - Listening

/// Takes in mono audio a buffer at a time and keeps what the tempo and key
/// estimates need: one onset strength per 256 samples, and a fine pitch-class
/// histogram.
final class Listener {
    struct Settings: Sendable {
        /// The range searched for notes.
        var lowestNote = 40.0
        var highestNote = 2_000.0
        /// How far above its surroundings a spectral peak must stand.
        var prominence: Float = 2
        /// Take away a note's overtones (its 3rd, 5th… harmonics would
        /// otherwise read as a fifth and a major third above it).
        var removesOvertones = true
        /// Count quiet notes more nearly as much as loud ones.
        var compresses = true
    }

    let sampleRate: Double
    let settings: Settings
    private(set) var samplesHeard = 0

    // Onsets: 1024-sample frames every 256 samples (46 ms frames, 86 a second).
    static let onsetSize = 1024
    static let onsetHop = 256
    private let onsetSpectrum = PowerSpectrum(size: onsetSize)
    private let onsetBands: [Range<Int>]
    private var previousBandLevels: [Float]?
    private(set) var onsets: [Float] = []

    // Pitch: 8192-sample frames (2.7 Hz per bin, to tell low notes apart) every 4096.
    static let pitchSize = 8192
    static let pitchHop = 4096
    private let pitchSpectrum = PowerSpectrum(size: pitchSize)
    /// Ten bins per semitone, from C (bin 0) up to just below the next C.
    private(set) var pitchHistogram = [Double](repeating: 0, count: 120)

    private var pending: [Float] = []
    private var onsetPosition = 0
    private var pitchPosition = 0

    init(sampleRate: Double, settings: Settings = Settings()) {
        self.sampleRate = sampleRate
        self.settings = settings
        // 24 bands, evenly spaced in log frequency from 40 Hz to 10 kHz.
        let binHz = sampleRate / Double(Self.onsetSize)
        let edges = (0...24).map { i in 40 * pow(10_000 / 40, Double(i) / 24) }
        var bands: [Range<Int>] = []
        for i in 0..<24 {
            let low = max(1, Int((edges[i] / binHz).rounded()))
            let high = max(low + 1, Int((edges[i + 1] / binHz).rounded()))
            bands.append(low..<min(high, Self.onsetSize / 2))
        }
        onsetBands = bands
    }

    func listen(to samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        pending.append(contentsOf: samples)
        samplesHeard += samples.count
        pending.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            while onsetPosition + Self.onsetSize <= buffer.count {
                hearOnset(base + onsetPosition)
                onsetPosition += Self.onsetHop
            }
            while pitchPosition + Self.pitchSize <= buffer.count {
                hearPitches(base + pitchPosition)
                pitchPosition += Self.pitchHop
            }
        }
        let used = min(onsetPosition, pitchPosition)
        if used > 1 << 16 {
            pending.removeFirst(used)
            onsetPosition -= used
            pitchPosition -= used
        }
    }

    /// Spectral flux: how much louder each band got since the last frame, in
    /// decibels (so it doesn't matter how loud the recording is), summed.
    private func hearOnset(_ frame: UnsafePointer<Float>) {
        onsetSpectrum.compute(frame)
        let power = onsetSpectrum.power
        let levels = onsetBands.map { band -> Float in
            var sum: Float = 0
            for bin in band { sum += power[bin] }
            return 10 * log10(max(sum, 1e-10))
        }
        if let previous = previousBandLevels {
            var flux: Float = 0
            for (now, before) in zip(levels, previous) where now > before { flux += now - before }
            onsets.append(flux)
        } else {
            onsets.append(0)
        }
        previousBandLevels = levels
    }

    /// Adds the frame's prominent spectral peaks to the pitch histogram.
    private func hearPitches(_ frame: UnsafePointer<Float>) {
        pitchSpectrum.compute(frame)
        let power = pitchSpectrum.power
        let binHz = sampleRate / Double(Self.pitchSize)
        let low = max(2, Int(settings.lowestNote / binHz)), high = min(power.count - 2, Int(settings.highestNote / binHz))
        guard high > low + 32 else { return }
        let size = min(power.count, high + 18)
        var magnitude = [Float](repeating: 0, count: size)
        for bin in max(0, low - 16)..<size { magnitude[bin] = power[bin].squareRoot() }
        // A running sum, for the average level around each bin.
        var running = [Float](repeating: 0, count: size + 1)
        for i in 0..<size { running[i + 1] = running[i] + magnitude[i] }
        var peaks: [(frequency: Double, magnitude: Double)] = []
        for bin in low...high {
            let m = magnitude[bin]
            guard m > magnitude[bin - 1], m >= magnitude[bin + 1] else { continue }
            // Stands well clear of what's around it (not noise, or a drum).
            let from = max(0, bin - 16), to = min(size, bin + 17)
            let average = (running[to] - running[from]) / Float(to - from)
            guard m > average * settings.prominence, m > 1e-6 else { continue }
            // Where the peak really is, between bins.
            let a = log(max(magnitude[bin - 1], 1e-12)), b = log(m), c = log(max(magnitude[bin + 1], 1e-12))
            let denominator = a - 2 * b + c
            let offset = denominator == 0 ? 0 : max(-0.5, min(0.5, 0.5 * (a - c) / denominator))
            peaks.append(((Double(bin) + Double(offset)) * binHz, Double(m)))
        }
        var weights = peaks.map(\.magnitude)
        if settings.removesOvertones {
            // Peaks are in rising order. A peak sitting on the 3rd, 5th, 6th
            // or 7th harmonic of a lower one loses what that note would put there.
            for upper in peaks.indices {
                for lower in 0..<upper {
                    let ratio = peaks[upper].frequency / peaks[lower].frequency
                    let harmonic = ratio.rounded()
                    guard [3.0, 5, 6, 7].contains(harmonic), abs(ratio - harmonic) / harmonic < 0.025 else { continue }
                    weights[upper] -= peaks[lower].magnitude / harmonic
                }
            }
        }
        for (peak, weight) in zip(peaks, weights) where weight > 0 {
            let pitch = 69 + 12 * log2(peak.frequency / 440)
            let pitchClass = pitch.truncatingRemainder(dividingBy: 12) + (pitch < 0 ? 12 : 0)
            let slot = Int((pitchClass * 10).rounded()) % 120
            pitchHistogram[slot] += settings.compresses ? weight.squareRoot() : weight
        }
    }

    func conclude() -> MusicAnalyzer.Result {
        let frameRate = sampleRate / Double(Self.onsetHop)
        return MusicAnalyzer.Result(
            bpm: TempoEstimator.estimate(onsets: onsets, frameRate: frameRate)?.rounded(),
            key: KeyEstimator.estimate(histogram: pitchHistogram)
        )
    }
}

// MARK: - Tempo

enum TempoEstimator {
    struct Settings: Sendable {
        var range = 55.0...215.0
        /// How much each multiple of a candidate beat counts (the beat itself first).
        var multiples: [Double] = [1, 1, 1, 1]
        /// The log-normal preference for some tempos over others.
        var preferredBPM = 110.0
        var spreadOctaves = 0.7
        /// How clearly the music has to pulse at its beat to be given a tempo.
        /// (Below this, guesses were wrong as often as right: better none.)
        var minimumClarity = 0.1
    }

    static let standard = Settings()

    /// The tempo, if the music has a clear enough beat.
    static func estimate(onsets: [Float], frameRate: Double, settings: Settings = standard) -> Double? {
        guard let beat = strongestBeat(onsets: onsets, frameRate: frameRate, settings: settings),
              beat.clarity >= settings.minimumClarity else { return nil }
        return beat.bpm
    }

    /// The most likely beat in an onset envelope, with how clearly the music
    /// pulses at it (the envelope's autocorrelation one beat apart, 0...1).
    static func strongestBeat(onsets: [Float], frameRate: Double, settings: Settings = standard) -> (bpm: Double, clarity: Double)? {
        // Needs a few seconds of music, and some onsets in it.
        guard onsets.count > Int(frameRate * 6) else { return nil }
        var envelope = onsets
        var mean: Float = 0
        vDSP_meanv(envelope, 1, &mean, vDSP_Length(envelope.count))
        var negativeMean = -mean
        vDSP_vsadd(envelope, 1, &negativeMean, &envelope, 1, vDSP_Length(envelope.count))

        let maxLag = Int((Double(settings.multiples.count) * 60 * frameRate / settings.range.lowerBound).rounded(.up)) + 2
        guard envelope.count > maxLag * 2 else { return nil }
        var correlation = [Double](repeating: 0, count: maxLag + 1)
        envelope.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            for lag in 0...maxLag {
                var sum: Float = 0
                let count = buffer.count - lag
                vDSP_dotpr(base, 1, base + lag, 1, &sum, vDSP_Length(count))
                correlation[lag] = Double(sum) / Double(count)
            }
        }
        guard correlation[0] > 1e-9 else { return nil }
        let energy = correlation[0]
        for lag in correlation.indices { correlation[lag] /= energy }

        func at(_ lag: Double) -> Double {
            let index = Int(lag)
            guard index + 1 < correlation.count, index >= 0 else { return 0 }
            let fraction = lag - Double(index)
            return correlation[index] * (1 - fraction) + correlation[index + 1] * fraction
        }
        let totalWeight = max(settings.multiples.reduce(0, +), 1e-9)
        var best: (bpm: Double, score: Double)?
        var bpm = settings.range.lowerBound
        while bpm <= settings.range.upperBound {
            let period = 60 * frameRate / bpm
            var score = 0.0
            for (index, weight) in settings.multiples.enumerated() {
                score += weight * at(period * Double(index + 1))
            }
            score /= totalWeight
            let octaves = log2(bpm / settings.preferredBPM) / settings.spreadOctaves
            score *= exp(-0.5 * octaves * octaves)
            if score > (best?.score ?? -.infinity) { best = (bpm, score) }
            bpm += 0.05
        }
        guard let best else { return nil }
        return (best.bpm, at(60 * frameRate / best.bpm))
    }
}

// MARK: - Key

enum KeyEstimator {
    /// Krumhansl & Kessler's probe-tone ratings, from the tonic up.
    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// What this detector actually hears in music in each mode: the average
    /// tonic-aligned pitch-class profile of 872 Apple Loops whose keys are
    /// known (187 major, 685 minor).
    static let heardMajor: [Double] = [0.2092, 0.0286, 0.0967, 0.0404, 0.1185, 0.0855, 0.0386, 0.1653, 0.0229, 0.0810, 0.0513, 0.0620]
    static let heardMinor: [Double] = [0.2003, 0.0357, 0.0700, 0.1303, 0.0405, 0.0884, 0.0394, 0.1405, 0.0752, 0.0390, 0.1056, 0.0350]
    /// Mostly what's heard, steadied by Krumhansl and Kessler's ratings:
    /// the best mix when tried on loops it wasn't learned from.
    static let blendedMajor = blend(heardMajor, majorProfile)
    static let blendedMinor = blend(heardMinor, minorProfile)

    static func blend(_ heard: [Double], _ rated: [Double]) -> [Double] {
        let total = rated.reduce(0, +)
        return zip(heard, rated).map { 0.7 * $0 + 0.3 * $1 / total }
    }

    enum Profiles: Sendable { case krumhansl, heard, blended }

    struct Settings: Sendable {
        var profiles = Profiles.blended
        /// How unevenly the pitch classes must be used (their spread over
        /// their mean) for the music to count as having a key, and how well a
        /// key profile must fit (a correlation).
        var minimumTonality = 0.25
        var minimumMatch = 0.5
    }

    static let standard = Settings()

    /// The key, if the music makes it clear enough.
    static func estimate(histogram: [Double], settings: Settings = standard) -> MusicalKey? {
        guard let guess = bestKey(histogram: histogram, settings: settings),
              guess.tonality >= settings.minimumTonality, guess.match >= settings.minimumMatch else { return nil }
        return guess.key
    }

    /// The twelve pitch classes' share of the music (C first), once the
    /// recording's tuning (in semitones from A = 440) is allowed for.
    static func chroma(histogram: [Double]) -> (chroma: [Double], tuning: Double)? {
        guard histogram.count == 120, histogram.reduce(0, +) > 0 else { return nil }
        // The tuning: the average position of the energy within a semitone.
        var x = 0.0, y = 0.0
        for (slot, weight) in histogram.enumerated() {
            let angle = 2 * Double.pi * Double(slot % 10) / 10
            x += weight * cos(angle)
            y += weight * sin(angle)
        }
        let tuning = atan2(y, x) / (2 * .pi)
        var chroma = [Double](repeating: 0, count: 12)
        for (slot, weight) in histogram.enumerated() {
            let semitone = Int((Double(slot) / 10 - tuning).rounded())
            chroma[((semitone % 12) + 12) % 12] += weight
        }
        return (chroma, tuning)
    }

    /// The key whose profile best matches the music's pitch classes, how well
    /// it matches (a correlation), how unevenly the pitch classes are used,
    /// and the recording's tuning.
    static func bestKey(histogram: [Double], settings: Settings = standard) -> (key: MusicalKey, match: Double, tonality: Double, tuning: Double)? {
        guard let (chroma, tuning) = chroma(histogram: histogram) else { return nil }
        // Music with a tonal centre leans on a few pitch classes; noise and
        // drums spread evenly over all twelve.
        let mean = chroma.reduce(0, +) / 12
        guard mean > 0 else { return nil }
        let tonality = (chroma.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 12).squareRoot() / mean

        var best: (key: MusicalKey, match: Double)?
        func fit(_ major: [Double], _ minor: [Double], _ key: MusicalKey) -> Double {
            let profile = key.isMinor ? minor : major
            return correlation(chroma, (0..<12).map { profile[((($0 - key.tonic) % 12) + 12) % 12] })
        }
        for key in MusicalKey.all {
            let match: Double
            switch settings.profiles {
            case .krumhansl: match = fit(majorProfile, minorProfile, key)
            case .heard: match = fit(heardMajor, heardMinor, key)
            case .blended: match = fit(blendedMajor, blendedMinor, key)
            }
            if match > (best?.match ?? -.infinity) { best = (key, match) }
        }
        guard let best else { return nil }
        return (best.key, best.match, tonality, tuning)
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let meanA = a.reduce(0, +) / Double(a.count), meanB = b.reduce(0, +) / Double(b.count)
        var product = 0.0, squaresA = 0.0, squaresB = 0.0
        for (u, v) in zip(a, b) {
            product += (u - meanA) * (v - meanB)
            squaresA += (u - meanA) * (u - meanA)
            squaresB += (v - meanB) * (v - meanB)
        }
        let denominator = (squaresA * squaresB).squareRoot()
        return denominator > 0 ? product / denominator : 0
    }
}

// MARK: - Spectra

/// Power spectra of fixed-size, Hann-windowed frames (a real FFT).
final class PowerSpectrum {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    /// Bins 0..<size/2, scaled so a full-scale sine peaks near 1.
    private(set) var power: [Float]

    init(size: Int) {
        self.size = size
        log2n = vDSP_Length(log2(Double(size)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
        power = [Float](repeating: 0, count: size / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func compute(_ frame: UnsafePointer<Float>) {
        let half = size / 2
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(size))
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { pairs in
                        vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // The packed Nyquist term sits in imaginary[0]; leave just DC there.
                im[0] = 0
                power.withUnsafeMutableBufferPointer { out in
                    vDSP_zvmags(&split, 1, out.baseAddress!, 1, vDSP_Length(half))
                    var scale = 1 / Float(size * size)
                    vDSP_vsmul(out.baseAddress!, 1, &scale, out.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
    }
}
