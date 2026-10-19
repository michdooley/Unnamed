#if DEBUG
import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UnnamedKit

/// Development helpers, compiled into Debug builds only.
///
/// - `-demoLibrary` opens a throwaway library (inside the app's container)
///   filled with synthesized ideas, so the app can be tried without real files.
/// - `-snapshot` (with `-demoLibrary`) walks through the main screens, saves a
///   PNG of each to the container's tmp/snapshots folder, then quits.
enum DebugSupport {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static func demoLibraryURL() -> URL? {
        guard arguments.contains("-demoLibrary") else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Demo Library", directoryHint: .isDirectory)
    }

    // MARK: Demo library

    private struct DemoTrack {
        var title: String
        var seconds: Double
        var bpm: Double
        var notes: String?
        var comments: [(TimeInterval, String)] = []
    }

    static func populateDemoLibraryIfEmpty(_ model: AppModel) async {
        guard let store = model.store, store.tracks.isEmpty else { return }
        let plan: [(String, [DemoTrack])] = [
            ("Snippets", [
                DemoTrack(title: "late night chords", seconds: 48, bpm: 84, notes: "Fmaj7 – Em7 – Dm7 – Cmaj7\nTry a Rhodes instead of the pad.",
                          comments: [(6, "love this intro"), (21, "bass too loud here"), (37, "cut this section?")]),
                DemoTrack(title: "bounce idea 2", seconds: 34, bpm: 96, comments: [(12, "this groove!!")]),
                DemoTrack(title: "voice memo melody", seconds: 41, bpm: 72, notes: "hum the top line again, higher"),
                DemoTrack(title: "drum sketch 120", seconds: 29, bpm: 120),
            ]),
            ("Pop/RnB", [
                DemoTrack(title: "hook v3", seconds: 55, bpm: 100, notes: "Verse 1:\nsomething about the city lights\n\nHook:\n(don't let me fall)",
                          comments: [(18, "hook should come in earlier")]),
                DemoTrack(title: "verse ideas", seconds: 44, bpm: 92),
                DemoTrack(title: "bridge (rough)", seconds: 26, bpm: 92),
            ]),
            ("Mainstream EDM", [
                DemoTrack(title: "drop test", seconds: 62, bpm: 128, comments: [(30, "DROP"), (46, "needs more sidechain")]),
                DemoTrack(title: "build 128", seconds: 38, bpm: 128),
            ]),
            ("Field Recordings", [
                DemoTrack(title: "rain on the window", seconds: 33, bpm: 60),
            ]),
        ]

        let scratch = FileManager.default.temporaryDirectory.appending(path: "demo-audio-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var seed: UInt64 = 7
        for (title, tracks) in plan.reversed() {
            let collection = store.createCollection(title: title)
            for demo in tracks {
                seed &+= 0x9E37_79B9_7F4A_7C15
                let url = scratch.appending(path: "\(demo.title).wav")
                let currentSeed = seed
                let seconds = demo.seconds
                let bpm = demo.bpm
                do {
                    try await Task.detached {
                        try synthesize(seconds: seconds, bpm: bpm, seed: currentSeed, to: url)
                    }.value
                } catch {
                    continue
                }
                guard let id = await store.importAudio(from: [url], into: collection.id).first else { continue }
                store.updateTrack(id) { $0.bpm = demo.bpm }
                if let notes = demo.notes { store.setNotes(notes, for: id) }
                for (time, text) in demo.comments {
                    store.addComment(to: id, at: time, text: text, author: model.authorName)
                }
            }
        }
        store.flushNotes()
        await store.flush()
    }

    /// Synthesizes something with the shape of a song: sections of varying
    /// loudness, a pulse on the beat, and a chord pad.
    nonisolated static func synthesize(seconds: Double, bpm: Double, seed: UInt64, to url: URL) throws {
        var rng = SplitMix64(seed: seed)
        let sampleRate = 22_050.0
        let frames = Int(seconds * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]

        let roots: [Double] = [110, 123.47, 130.81, 146.83, 164.81, 174.61, 196]
        let sectionCount = 4 + Int(rng.next() % 4)
        let levels = (0..<sectionCount).map { _ in 0.25 + Double(rng.next() % 750) / 1000 }
        let chords = (0..<sectionCount).map { _ in roots[Int(rng.next() % UInt64(roots.count))] }
        let beat = 60 / bpm
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let section = min(sectionCount - 1, Int(t / seconds * Double(sectionCount)))
            let level = levels[section]
            let root = chords[section]
            let pad = (sin(2 * .pi * root * t) + 0.6 * sin(2 * .pi * root * 1.26 * t) + 0.5 * sin(2 * .pi * root * 1.5 * t)) * 0.18
            let sinceBeat = t.truncatingRemainder(dividingBy: beat)
            let kick = sin(2 * .pi * (50 + 60 * exp(-sinceBeat * 30)) * sinceBeat) * exp(-sinceBeat * 9) * 0.55
            let swell = 0.75 + 0.25 * sin(2 * .pi * t / (beat * 8))
            let fade = min(1, t / 1.5, (seconds - t) / 2)
            out[i] = Float((pad * swell + kick) * level * max(0, fade))
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    // MARK: Snapshots

    static func scheduleSnapshotIfRequested() {
        if arguments.contains("-selfTest") {
            Task { @MainActor in await runSelfTests() }
            return
        }
        guard arguments.contains("-snapshot") else { return }
        Task { @MainActor in
            await runSnapshots()
        }
    }

    @MainActor
    private static func runSnapshots() async {
        let model = AppModel.shared
        let folder = argument(after: "-snapshotDir").map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory.appending(path: "snapshots", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Wait for the demo library to be ready.
        for second in 0..<120 {
            if let store = model.store, store.tracks.count >= 10, store.pendingImports.isEmpty { break }
            if second % 5 == 0 { log("waiting for demo library: \(model.store?.tracks.count ?? -1) tracks") }
            try? await Task.sleep(for: .seconds(1))
        }
        guard let store = model.store else {
            log("no library open")
            return
        }
        let previousVolume = model.player.volume
        model.player.setVolume(0)
        NSApp.activate()
        if let size = argument(after: "-windowSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
           let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            window.setFrame(CGRect(origin: window.frame.origin, size: CGSize(width: size[0], height: size[1])), display: true)
        }

        func shoot(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(1400))
            if arguments.contains("-handshake") {
                // An external tool takes the screenshot, then creates <name>.done.
                log("READY \(name)")
                let done = folder.appending(path: "\(name).done")
                for _ in 0..<120 where !FileManager.default.fileExists(atPath: done.path) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                return
            }
            let window = NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
            guard let window else {
                log("no window for \(name); windows: " + NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) titled=\($0.styleMask.contains(.titled)) frame=\($0.frame)" }.joined(separator: ", "))
                return
            }
            log("capturing \(name)")
            capture(window, to: folder.appending(path: "\(name).png"))
            if let sheet = window.attachedSheet {
                capture(sheet, to: folder.appending(path: "\(name)-sheet.png"))
            }
        }

        let snippets = store.collections.values.first { $0.title == "Snippets" }
        model.selection = .home
        await shoot("1-home-empty-player")

        if let snippets {
            model.player.play(collection: snippets.id)
            model.player.seek(to: 14)
            model.selection = .home
            await shoot("2-home")

            model.selection = .collection(snippets.id)
            await shoot("3-collection-playing")

            if let first = snippets.trackIDs.first {
                model.showDetails(for: first, in: snippets.id)
                await shoot("4-details")
                model.detail?.pane = .comments
                await shoot("5-comments")
                model.detail?.pane = .notes
                await shoot("6-notes")
                model.detail = nil
            }
        }
        model.selection = .allTracks
        await shoot("7-all-tracks")
        model.searchText = "bass"
        await shoot("8-search")
        model.searchText = ""

        // The main window's scroll views draw through toolbar "scroll edge"
        // layers that in-process capture can't read, so also render the main
        // views on their own in plain windows.
        if let snippets {
            model.player.play(collection: snippets.id)
            model.player.seek(to: 20)
            await renderStandalone(SidebarView(store: store), size: CGSize(width: 260, height: 700), name: "9-sidebar", folder: folder)
            await renderStandalone(HomeView(store: store), size: CGSize(width: 1200, height: 760), name: "10-home", folder: folder)
            await renderStandalone(CollectionView(store: store, collectionID: snippets.id), size: CGSize(width: 1300, height: 900), name: "11-collection", folder: folder)
            await renderStandalone(CollectionView(store: store, collectionID: snippets.id), size: CGSize(width: 820, height: 900), name: "12-collection-narrow", folder: folder)
            await renderStandalone(AllTracksView(store: store), size: CGSize(width: 1100, height: 800), name: "13-all-tracks", folder: folder)
            model.searchText = "bass"
            await renderStandalone(SearchView(store: store), size: CGSize(width: 1100, height: 700), name: "14-search", folder: folder)
            model.searchText = ""
        }

        model.player.pause()
        model.player.setVolume(previousVolume)
        log("SNAPSHOTS: \(folder.path)")
        if arguments.contains("-quitAfterSnapshot") {
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func renderStandalone(_ view: some View, size: CGSize, name: String, folder: URL) async {
        let model = AppModel.shared
        let host = NSHostingView(rootView: view
            .environment(model)
            .environment(model.player)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .textBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(1500))
        log("rendering \(name)")
        capture(window, to: folder.appending(path: "\(name).png"))
        window.orderOut(nil)
    }

    /// Exercises code paths whose callbacks arrive on background threads.
    @MainActor
    private static func runSelfTests() async {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            log("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        let model = AppModel.shared
        for _ in 0..<120 {
            if let store = model.store, store.tracks.count >= 10 { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let store = model.store, let track = store.tracksNewestFirst.first else {
            log("FAIL no demo library")
            NSApp.terminate(nil)
            return
        }

        // Drag a track: in-app identity plus its audio file.
        let trackDrag = NSItemProvider.forTrack(track.id, audioURL: store.audioURL(for: track.id), title: track.title)
        let fromTrack = await DropPayload.load(from: [trackDrag])
        check(fromTrack.trackIDs == [track.id] && fromTrack.fileURLs.isEmpty, "track drag round-trips as a track")

        // Drop a file from "Finder".
        if let audio = store.audioURL(for: track.id), let fileDrag = NSItemProvider(contentsOf: audio) {
            let fromFile = await DropPayload.load(from: [fileDrag])
            check(fromFile.fileURLs.map(\.lastPathComponent) == [audio.lastPathComponent] && fromFile.trackIDs.isEmpty, "file drop loads the file URL")
        }

        // Drop image data onto cover art.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let imageDrag = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        if case .data(let data)? = await DropPayload.loadArtwork(from: [imageDrag]) {
            check(data == png, "image drop loads image data")
        } else {
            check(false, "image drop loads image data")
        }

        // Artwork on a playing track feeds Now Playing (rendered off the main thread).
        if let collection = store.collections(containing: track.id).first {
            await store.setArtwork(forCollection: collection.id, from: .data(png))
            model.player.setVolume(0)
            model.player.play(collection: collection.id, startingAt: track.id)
            try? await Task.sleep(for: .seconds(2))
            check(model.player.isPlaying, "plays a track whose collection has artwork")
            model.player.stop()
            store.removeArtwork(forCollection: collection.id)
        }

        log("SELFTEST \(failures == 0 ? "OK" : "FAILED (\(failures))")")
        NSApp.terminate(nil)
    }

    static func argument(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[debug] \(message)\n".utf8))
    }

    @MainActor
    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)

    }
}

private nonisolated struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
