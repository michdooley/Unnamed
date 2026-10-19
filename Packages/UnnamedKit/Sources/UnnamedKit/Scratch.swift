import Accelerate
import AVFoundation
import Synchronization

// DJ-style scratching. While a disc (or the scrub bar) is held, the track
// plays from a decoded copy through a small AVAudioEngine instead of
// AVPlayer: a "needle" chases wherever the hand puts the record, so moving
// slowly drops the pitch, moving backwards plays backwards, and holding still
// is silent. Letting go spins the platter back up to speed and hands playback
// back to AVPlayer, lined up to the sample clock so there's no jump.

/// A whole track decoded to mono floats, for the needle to read from.
final class DecodedTrack: @unchecked Sendable {
    let url: URL
    let sampleRate: Double
    let samples: UnsafeMutableBufferPointer<Float>

    /// Number of frames.
    var count: Int { samples.count }
    var duration: Double { Double(count) / sampleRate }

    init(url: URL, sampleRate: Double, samples: UnsafeMutableBufferPointer<Float>) {
        self.url = url
        self.sampleRate = sampleRate
        self.samples = samples
    }

    deinit { samples.deallocate() }

    /// Decodes any format AVAudioFile reads, mixing channels down to mono.
    static func decode(_ url: URL) throws -> DecodedTrack {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let chunk: AVAudioFrameCount = 1 << 16
        guard channels > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // The length can be an estimate for compressed formats, so grow as needed.
        var storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(Int(file.length), Int(chunk)))
        var written = 0
        var scale = 1 / Float(channels)
        while true {
            do {
                try file.read(into: buffer, frameCount: chunk)
            } catch {
                if written > 0 { break }
                storage.deallocate()
                throw error
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            if written + frames > storage.count {
                let bigger = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(storage.count * 2, written + frames))
                _ = bigger.update(fromContentsOf: storage[0..<written])
                storage.deallocate()
                storage = bigger
            }
            let destination = storage.baseAddress! + written
            destination.update(from: data[0], count: frames)
            for channel in 1..<max(1, channels) {
                vDSP_vadd(destination, 1, data[channel], 1, destination, 1, vDSP_Length(frames))
            }
            if channels > 1 {
                vDSP_vsmul(destination, 1, &scale, destination, 1, vDSP_Length(frames))
            }
            written += frames
        }
        guard written > 1 else {
            storage.deallocate()
            throw CocoaError(.fileReadCorruptFile)
        }
        let samples = UnsafeMutableBufferPointer(rebasing: storage[0..<written])
        // Keep the original allocation's base address so deallocate() is valid.
        return DecodedTrack(url: url, sampleRate: format.sampleRate, samples: samples)
    }
}

/// The mach clock that audio timestamps (and AVPlayer's host time) use.
enum HostClock {
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()

    static var now: UInt64 { mach_absolute_time() }

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * timebase.numer / timebase.denom / 1e9
    }

    static func ticks(_ seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1e9 * timebase.denom / timebase.numer)
    }
}

/// The record under the needle. The render thread owns the needle; the main
/// thread steers it only through atomics.
final class ScratchVoice: @unchecked Sendable {
    /// How the needle follows the hand.
    enum Feel: Sendable {
        /// A disc: tight, so quick back-and-forth scratches stay sharp.
        case disc
        /// The scrub bar: each point of it is a lot of music, so pointer
        /// updates come in coarse steps. Following the hand's average speed
        /// (and predicting between steps) keeps a melody playable.
        case bar
    }

    let track: DecodedTrack
    let feel: Feel

    /// Fastest the needle moves, in times normal speed.
    static let topSpeed = 8.0
    /// Letting go: the motor takes this long to get the record back to speed.
    static let spinUpTime = 0.28
    /// Grabbing a spinning record: the hand stops it in this long.
    static let brakeTime = 0.12

    // Main thread → render thread.
    /// How far the hand has moved the record since it was grabbed, in frames.
    private let hand: Atomic<UInt64>
    private let motor = Atomic<UInt64>(Double.nan.bitPattern)
    private let fadeAt = Atomic<UInt64>(0)

    // Render thread → main thread.
    private let published: Atomic<UInt64>
    private let publishedAt = Atomic<UInt64>(0)
    private let publishedVelocity: Atomic<UInt64>
    private let locked = Atomic<Bool>(false)
    private let resting: Atomic<Bool>
    private let silent = Atomic<Bool>(false)

    // Render thread only.
    private var needle: Double
    private var target: Double
    private var velocity: Double
    private var braking: Bool
    private var lastHand: Double
    /// Host time to start making sound at (0: straight away).
    private var startAt: UInt64
    private var gain = 0.0
    private var lastIn = 0.0
    private var lastOut = 0.0
    // The scrub bar's hand tracking.
    private var clock = 0.0
    private var lastStep = 0.0
    private var stepInterval = 0.0
    private var handSpeed = 0.0
    private var predicted: Double

    /// - Parameters:
    ///   - velocity: how fast the record is already turning (1 if it was playing).
    ///   - braking: a hand just grabbed it; slow it to a stop unless the hand moves it first.
    ///   - startAt: a host time to start at, so AVPlayer can stop at that same instant.
    ///   - hand: the hand's position so far, in seconds (moves from here on count).
    init(track: DecodedTrack, at seconds: Double, feel: Feel, velocity: Double = 0, braking: Bool = false,
         startAt: UInt64 = 0, hand: Double = 0) {
        self.track = track
        self.feel = feel
        let frame = min(max(0, seconds * track.sampleRate), Double(track.count - 1))
        needle = frame
        target = frame
        predicted = frame
        self.velocity = velocity
        self.braking = braking && velocity != 0
        self.startAt = startAt
        lastHand = hand * track.sampleRate
        self.hand = Atomic(lastHand.bitPattern)
        published = Atomic(frame.bitPattern)
        publishedVelocity = Atomic(velocity.bitPattern)
        resting = Atomic(velocity == 0)
        stepInterval = 0.05 * track.sampleRate
    }

    // MARK: Steering (main thread)

    /// The hand's position since the grab, in seconds of music.
    func setHand(seconds: Double) {
        hand.store((seconds * track.sampleRate).bitPattern, ordering: .relaxed)
    }

    /// Lets go: the platter's motor pulls it to `speed` (1 = normal, 0 = stopped).
    func release(toSpeed speed: Double) {
        motor.store(speed.bitPattern, ordering: .relaxed)
    }

    /// Fades out from the given host time (now, if it's already passed).
    func fadeOut(atHostTime hostTime: UInt64 = 1) {
        fadeAt.store(max(1, hostTime), ordering: .relaxed)
    }

    /// The needle's position and the host time it's heard at.
    var position: (seconds: Double, hostTime: UInt64) {
        while true {
            let at = publishedAt.load(ordering: .acquiring)
            let frame = Double(bitPattern: published.load(ordering: .acquiring))
            if publishedAt.load(ordering: .acquiring) == at {
                return (frame / track.sampleRate, at)
            }
        }
    }

    /// How fast the record is turning (1 = normal speed).
    var speed: Double { Double(bitPattern: publishedVelocity.load(ordering: .relaxed)) }
    /// The motor has the record at exactly normal speed.
    var isLocked: Bool { locked.load(ordering: .relaxed) }
    /// The record has stopped turning.
    var isResting: Bool { resting.load(ordering: .relaxed) }
    /// Faded out completely.
    var isSilent: Bool { silent.load(ordering: .relaxed) }

    // MARK: Rendering (audio thread)

    func render(frames: Int, hostTime: UInt64, into output: UnsafeMutablePointer<Float>) {
        let rate = track.sampleRate
        let motor = Double(bitPattern: self.motor.load(ordering: .relaxed))
        let hand = Double(bitPattern: self.hand.load(ordering: .relaxed))
        let fadeAt = self.fadeAt.load(ordering: .relaxed)
        let fadeIndex: Int
        if fadeAt == 0 {
            fadeIndex = .max
        } else if fadeAt <= hostTime {
            fadeIndex = 0
        } else {
            fadeIndex = Int(HostClock.seconds(fadeAt - hostTime) * rate)
        }
        var startIndex = 0
        if startAt > hostTime {
            startIndex = min(frames, Int(HostClock.seconds(startAt - hostTime) * rate))
        }

        var needle = self.needle
        var target = self.target
        var velocity = self.velocity
        var braking = self.braking
        var gain = self.gain
        var lastIn = self.lastIn
        var lastOut = self.lastOut
        var clock = self.clock
        var handSpeed = self.handSpeed
        var predicted = self.predicted

        // The hand moved: it takes over from a braking record, and the bar
        // learns how fast it's going.
        let moved = hand - lastHand
        lastHand = hand
        if motor.isNaN, moved != 0 {
            if braking {
                braking = false
                target = needle
                predicted = needle
            }
            target += moved
            if feel == .bar {
                let interval = max(1, clock - lastStep)
                let speed = moved / interval
                handSpeed = interval > 0.3 * rate ? speed : handSpeed * 0.5 + speed * 0.5
                stepInterval = stepInterval * 0.7 + interval * 0.3
                lastStep = clock
                predicted = target
            }
        }

        // Disc: aim to close the gap in ~16 ms, smoothing speed over ~5 ms.
        let chase = 1 / (0.016 * rate)
        let smoothing = 1 - exp(-1 / (0.005 * rate))
        // Bar: steer by the hand's speed, correcting position over ~80 ms.
        let barCorrection = 1 / (0.08 * rate)
        let barSmoothing = 1 - exp(-1 / (0.02 * rate))
        let handStopped = max(1.6 * stepInterval, 0.06 * rate)
        let handDecay = exp(-1 / (0.03 * rate))
        let spinUp = 1 / (Self.spinUpTime * rate)
        let brake = 1 / (Self.brakeTime * rate)
        let fade = 1 - exp(-1 / (0.003 * rate))
        let last = Double(track.count - 1)
        let samples = track.samples

        for i in 0..<frames {
            if i < startIndex {
                output[i] = 0
                continue
            }
            clock += 1
            if !motor.isNaN {
                if velocity < motor {
                    velocity = min(motor, velocity + spinUp)
                } else if velocity > motor {
                    velocity = max(motor, velocity - spinUp * 2)
                }
            } else if braking {
                velocity = velocity > 0 ? max(0, velocity - brake) : min(0, velocity + brake)
                target = needle
                if velocity == 0 { braking = false }
            } else if feel == .disc {
                let wanted = min(Self.topSpeed, max(-Self.topSpeed, (target - needle) * chase))
                velocity += (wanted - velocity) * smoothing
            } else {
                if clock - lastStep > handStopped { handSpeed *= handDecay }
                predicted += handSpeed
                let wanted = min(Self.topSpeed, max(-Self.topSpeed, handSpeed + (predicted - needle) * barCorrection))
                velocity += (wanted - velocity) * barSmoothing
            }
            needle += velocity
            if needle <= 0 {
                needle = 0
                velocity = max(0, velocity)
            } else if needle >= last {
                needle = last
                velocity = min(0, velocity)
            }

            // 4-point Hermite interpolation between samples.
            let index = Int(needle)
            let t = needle - Double(index)
            let xm1 = Double(samples[max(index - 1, 0)])
            let x0 = Double(samples[index])
            let x1 = Double(samples[min(index + 1, track.count - 1)])
            let x2 = Double(samples[min(index + 2, track.count - 1)])
            let c1 = 0.5 * (x1 - xm1)
            let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
            let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
            let x = ((c3 * t + c2) * t + c1) * t + x0

            // A held record is a constant sample value; block that DC so stillness is silence.
            let y = x - lastIn + 0.997 * lastOut
            lastIn = x
            lastOut = y

            gain += ((i >= fadeIndex ? 0 : 1) - gain) * fade
            output[i] = Float(y * gain)
        }
        if startIndex < frames { startAt = 0 }

        self.needle = needle
        self.target = target
        self.velocity = velocity
        self.braking = braking
        self.gain = gain
        self.lastIn = lastIn
        self.lastOut = lastOut
        self.clock = clock
        self.handSpeed = handSpeed
        self.predicted = predicted
        published.store(needle.bitPattern, ordering: .releasing)
        publishedAt.store(hostTime + HostClock.ticks(Double(frames) / rate), ordering: .releasing)
        publishedVelocity.store(velocity.bitPattern, ordering: .relaxed)
        locked.store(!motor.isNaN && velocity == motor && motor != 0, ordering: .relaxed)
        resting.store(velocity == 0, ordering: .relaxed)
        if fadeIndex < frames, gain < 1e-4 {
            silent.store(true, ordering: .relaxed)
        }
    }
}

/// Owns the decoded track and the audio engine a scratch plays through.
@MainActor
final class ScratchDeck {
    private var decoded: DecodedTrack?
    private var decoding: (url: URL, task: Task<DecodedTrack?, Never>)?
    private var engine: AVAudioEngine?
    private(set) var voice: ScratchVoice?

    /// Starts decoding `url` in the background, if it isn't already.
    func prepare(_ url: URL) {
        if decoded?.url == url || decoding?.url == url { return }
        decoding?.task.cancel()
        let task = Task.detached(priority: .userInitiated) {
            try? DecodedTrack.decode(url)
        }
        decoding = (url, task)
        Task { [weak self] in
            let track = await task.value
            guard let self, self.decoding?.url == url else { return }
            self.decoded = track
            self.decoding = nil
        }
    }

    /// The decoded track for `url` (decoding it if need be).
    func track(for url: URL) async -> DecodedTrack? {
        if let decoded, decoded.url == url { return decoded }
        prepare(url)
        guard let decoding, decoding.url == url else { return nil }
        return await decoding.task.value
    }

    /// Frees the decoded audio (e.g. when the track changes).
    func forget() {
        stop()
        decoding?.task.cancel()
        decoding = nil
        decoded = nil
    }

    func start(_ voice: ScratchVoice, volume: Float) throws {
        stop()
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: voice.track.sampleRate, channels: 1) else {
            throw CocoaError(.featureUnsupported)
        }
        let node = Self.makeSource(for: voice, format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.voice = voice
    }

    /// The decoded track for `url` if it's ready now.
    func readyTrack(for url: URL) -> DecodedTrack? {
        decoded?.url == url ? decoded : nil
    }

    func setVolume(_ volume: Float) {
        engine?.mainMixerNode.outputVolume = volume
    }

    func stop() {
        engine?.stop()
        engine = nil
        voice = nil
    }

    /// Built outside the main actor: the render block runs on the audio thread.
    nonisolated private static func makeSource(for voice: ScratchVoice, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, timestamp, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let stamp = timestamp.pointee
            let hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : HostClock.now
            for (index, buffer) in buffers.enumerated() {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                if index == 0 {
                    voice.render(frames: Int(frameCount), hostTime: hostTime, into: data)
                } else if let first = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                    data.update(from: first, count: Int(frameCount))
                }
            }
            return noErr
        }
    }
}
