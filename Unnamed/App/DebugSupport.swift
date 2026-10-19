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
        let url = support.appending(path: "Demo Library", directoryHint: .isDirectory)
        if arguments.contains("-resetDemo") {
            try? FileManager.default.removeItem(at: url)
        }
        return url
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
        // Folders: two collections filed under "2026 Releases", and a
        // subfolder holding a collection of voice memos.
        let releases = store.createFolder(title: "2026 Releases")
        let demos = store.createFolder(title: "Demos for Sam", in: releases.id)
        for title in ["Pop/RnB", "Mainstream EDM"] {
            if let collection = store.collections.values.first(where: { $0.title == title }) {
                store.moveCollection(collection.id, toFolder: releases.id)
            }
        }
        seed &+= 0x9E37_79B9_7F4A_7C15
        let memo = scratch.appending(path: "phone voice memo.wav")
        let memoSeed = seed
        if (try? await Task.detached { try synthesize(seconds: 22, bpm: 70, seed: memoSeed, to: memo) }.value) != nil {
            let memos = store.createCollection(title: "Voice Memos", in: demos.id)
            await store.importAudio(from: [memo], into: memos.id)
        }

        // Versions: "late night chords" gets two newer takes, with comments on each.
        if let chords = store.tracks.values.first(where: { $0.title == "late night chords" }) {
            for (index, (name, seconds)) in [("with Rhodes", 52.0), ("extended", 64.0)].enumerated() {
                let url = scratch.appending(path: "v\(index + 2)/late night chords.wav")
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let versionSeed = seed &+ UInt64(index + 1) * 977
                guard (try? await Task.detached { try synthesize(seconds: seconds, bpm: 84, seed: versionSeed, to: url) }.value) != nil,
                      let version = await store.addVersion(to: chords.id, from: url) else { continue }
                store.renameVersion(version, of: chords.id, to: name)
                store.addComment(to: chords.id, at: 9, text: index == 0 ? "Rhodes is the move" : "the long outro works", author: model.authorName, version: version)
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
        if arguments.contains("-renderShaders") {
            Task { @MainActor in await renderShaders() }
            return
        }
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

        if arguments.contains("-showOnboarding") {
            await shootOnboarding(into: folder)
            return
        }

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
        if arguments.contains("-scratchProbe"), let snippets {
            await probeScratching(store: store, collectionID: snippets.id)
            NSApp.terminate(nil)
            return
        }
        if arguments.contains("-glassLab"), let snippets {
            await shootGlassLab(store: store, collectionID: snippets.id, folder: folder)
            return
        }
        model.selection = .home
        await shoot("1-home-empty-player")

        if let snippets {
            model.player.play(collection: snippets.id)
            model.player.seek(to: 14)
            model.selection = .home
            await shoot("2-home")
            withAnimation { model.addMenuOpen = true }
            await shoot("2b-home-add-menu")
            model.addMenuOpen = false

            model.selection = .collection(snippets.id)
            await shoot("3-collection-playing")

            if let first = snippets.trackIDs.first {
                model.showDetails(for: first, in: snippets.id)
                await shoot("4-details")
                model.detail?.pane = .comments
                await shoot("5-comments")
                model.detail?.pane = .versions
                await shoot("6-versions")
                model.detail = nil
            }
        }
        if let releases = store.folders.values.first(where: { $0.title == "2026 Releases" }) {
            model.revealInSidebar(.collection(store.collections(inFolder: releases.id).first?.id ?? UUID()))
            model.selection = .folder(releases.id)
            await shoot("6b-folder")
            model.selection = .home
            await shoot("6c-home-with-folder")
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
            if let releases = store.folders.values.first(where: { $0.title == "2026 Releases" }) {
                model.revealInSidebar(.folder(store.subfolders(of: releases.id).first?.id ?? releases.id))
                await renderStandalone(FolderView(store: store, folderID: releases.id), size: CGSize(width: 1200, height: 900), name: "15-folder", folder: folder)
                await renderStandalone(SidebarView(store: store), size: CGSize(width: 260, height: 700), name: "18-sidebar-folders", folder: folder)
            }
            if let chords = store.tracks.values.first(where: { $0.title == "late night chords" }) {
                model.detail = TrackDetailRoute(trackID: chords.id, collectionID: snippets.id, pane: .versions)
                await renderStandalone(TrackDetailsSheet(trackID: chords.id, collectionID: snippets.id), size: CGSize(width: 820, height: 580), name: "16-versions", folder: folder)
                model.detail?.pane = .comments
                await renderStandalone(TrackDetailsSheet(trackID: chords.id, collectionID: snippets.id), size: CGSize(width: 820, height: 580), name: "17-comments-per-version", folder: folder)
                model.detail = nil
            }
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
            .environment(\.liquidGlass, model.liquidGlass && LiquidGlassSupport.isAvailable)
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

    /// Liquid Glass pieces in an off-screen window, each captured by the
    /// handshake driver (glass only renders in a real window).
    @MainActor
    private static func shootGlassLab(store: LibraryStore, collectionID: UUID, folder: URL) async {
        let model = AppModel.shared
        model.selection = .home
        model.player.play(collection: collectionID)
        model.player.seek(to: 20)
        model.player.pause()
        func open(_ view: some View, size: CGSize) -> NSWindow {
            let host = NSHostingView(rootView: view
                .environment(model)
                .environment(model.player)
                .environment(\.liquidGlass, true)
                .frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            // On screen but behind everything (off-screen windows can't be captured).
            window.setFrameOrigin(NSScreen.main?.visibleFrame.origin ?? .zero)
            window.orderBack(nil)
            return window
        }
        func waitForCapture(_ name: String) async {
            let done = folder.appending(path: "\(name).done")
            for _ in 0..<120 where !FileManager.default.fileExists(atPath: done.path) {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        func show(_ view: some View, size: CGSize, name: String) async {
            let window = open(view, size: size)
            try? await Task.sleep(for: .milliseconds(1500))
            log("READY \(name)")
            await waitForCapture(name)
            window.orderOut(nil)
        }
        let art = store.artworkURL(forCollection: collectionID)
        let label = Label("Add Cover Art", systemImage: "photo")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .glassOr(true, in: Capsule(), tint: .black.opacity(0.2), clear: true, classic: Color.clear)
        let tint = await ArtworkTint.make(url: art, seed: collectionID)
        let backdrop = ZStack {
            Color(nsColor: .textBackgroundColor)
            AmbientArtwork(url: art, seed: collectionID)
        }
        model.addMenuOpen = true
        await show(
            ZStack {
                backdrop
                VStack(spacing: 30) {
                    HStack(spacing: 30) {
                        ArtworkView(url: art, seed: collectionID, cornerRadius: 22, pixelSize: 400)
                            .frame(width: 220, height: 220)
                            .overlay(alignment: .bottom) { label.padding(.bottom, 20) }
                            .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
                        BigPlayButton(isPlaying: false, tint: tint) {}
                        BigPlayButton(isPlaying: false) {}
                        PillButton(title: "New Collection", systemImage: "square.stack") {}
                    }
                    ToastView(toast: Toast(message: "Archived “Snippets”", systemImage: "archivebox", actionTitle: "Undo", action: {})) {}
                    Spacer()
                    PlayerDock(store: store)
                }
                .padding(.vertical, 24)
            },
            size: CGSize(width: 1100, height: 640),
            name: "glass-lab"
        )
        model.addMenuOpen = false

        // The "+" melting out of the player, in slow motion, a frame at a time.
        model.selection = .collection(collectionID)
        PlayerDock.animationSpeed = 0.1
        let melt = open(ZStack { backdrop; VStack { Spacer(); PlayerDock(store: store) }.padding(.bottom, 24) }, size: CGSize(width: 1000, height: 200))
        try? await Task.sleep(for: .milliseconds(1500))
        model.selection = .home
        for frame in 1...7 {
            try? await Task.sleep(for: .milliseconds(650))
            log("READY glass-melt-\(frame)")
        }
        await waitForCapture("glass-melt-7")
        // And back in.
        model.selection = .collection(collectionID)
        for frame in 1...5 {
            try? await Task.sleep(for: .milliseconds(450))
            log("READY glass-unmelt-\(frame)")
        }
        await waitForCapture("glass-unmelt-5")
        melt.orderOut(nil)
        PlayerDock.animationSpeed = 1
        await show(OnboardingView(), size: CGSize(width: 1100, height: 760), name: "glass-onboarding")
        model.player.stop()
        log("SNAPSHOTS: \(folder.path)")
        if arguments.contains("-quitAfterSnapshot") { NSApp.terminate(nil) }
    }

    /// Drags the discs with synthetic mouse events (sent straight to a hidden
    /// panel, so the real pointer doesn't move) and checks each one scratches.
    @MainActor
    private static func probeScratching(store: LibraryStore, collectionID: UUID) async {
        await probeScratchingOnce(store: store, collectionID: collectionID, label: "")
        // Photos are rarely square: cover art drawn to fill must not spill over the record.
        let wide = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for i in 0..<320 { for j in 0..<120 { wide.setColor(NSColor(red: Double(i) / 320, green: 0.3, blue: Double(j) / 120, alpha: 1), atX: i, y: j) } }
        await store.setArtwork(forCollection: collectionID, from: .data(wide.representation(using: .png, properties: [:])!))
        await probeScratchingOnce(store: store, collectionID: collectionID, label: " (wide art)")
        store.removeArtwork(forCollection: collectionID)
    }

    @MainActor
    private static func probeScratchingOnce(store: LibraryStore, collectionID: UUID, label: String) async {
        let model = AppModel.shared
        let player = model.player
        player.setVolume(0)
        player.play(collection: collectionID)
        try? await Task.sleep(for: .seconds(1))
        let size = CGSize(width: 1300, height: 900)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            CollectionView(store: store, collectionID: collectionID)
            HStack { PlayerBar(store: store).fixedSize(); Spacer() }
        }
        .environment(model)
        .environment(player)
        .environment(\.liquidGlass, model.liquidGlass && LiquidGlassSupport.isAvailable)
        .frame(width: size.width, height: size.height))
        panel.setFrameOrigin(NSScreen.main?.visibleFrame.origin ?? .zero)
        panel.orderBack(nil)
        try? await Task.sleep(for: .seconds(2))

        func drag(_ name: String, _ points: [CGPoint]) async {
            func send(_ type: NSEvent.EventType, _ point: CGPoint) {
                let location = CGPoint(x: point.x, y: size.height - point.y)
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    panel.sendEvent(event)
                }
            }
            let before = player.currentTime
            var scratched = false
            send(.leftMouseDown, points[0])
            for point in points.dropFirst() {
                try? await Task.sleep(for: .milliseconds(16))
                send(.leftMouseDragged, point)
                scratched = scratched || player.isScratching
            }
            send(.leftMouseUp, points[points.count - 1])
            try? await Task.sleep(for: .seconds(1.2))
            log("\(scratched ? "PASS" : "FAIL") scratch \(name)\(label) (moved \(String(format: "%.2f", player.currentTime - before)) s)")
        }
        // The big record, where it sticks out to the right of the cover
        // (440 pt cover at x 68...508, record centre 74 pt right of the cover's).
        for x in [520.0, 545] {
            await drag("big disc x\(Int(x)) down", (0...20).map { CGPoint(x: x, y: 230 + Double($0) * 4) })
            await drag("big disc x\(Int(x)) across", (0...20).map { CGPoint(x: x - 20 + Double($0) * 2, y: 256) })
        }
        // The small disc in the player (centre 29, 871): a quarter turn.
        await drag("mini disc", (0...20).map { step in
            let angle = Double(step) / 20 * .pi / 2
            return CGPoint(x: 29 + 15 * cos(angle), y: 871 + 15 * sin(angle))
        })
        panel.orderOut(nil)
        player.stop()
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

        // Drag a collection and a folder (in-app only).
        if let collection = store.collections.values.first, let folder = store.folders.values.first {
            let drops = await DropPayload.load(from: [
                NSItemProvider.forItem(.collection(collection.id), title: collection.title),
                NSItemProvider.forItem(.folder(folder.id), title: folder.title),
            ])
            check(drops.items == [.collection(collection.id), .folder(folder.id)], "collection and folder drags round-trip")
        }

        // Moving a folder into its own subfolder is refused.
        if let parent = store.folders.values.first(where: { !store.subfolders(of: $0.id).isEmpty }),
           let child = store.subfolders(of: parent.id).first {
            model.move([.folder(parent.id)], toFolder: child.id)
            check(store.parentFolder(of: child.id) == parent.id && store.parentFolder(of: parent.id) != child.id, "folder can't move into its own subfolder")
        }

        // Navigation direction follows depth: into folders and collections is
        // forward, back out is back, between top-level pages is lateral.
        if let releases = store.folders.values.first(where: { $0.title == "2026 Releases" }),
           let inside = store.collections(inFolder: releases.id).first {
            model.selection = .home
            model.selection = .folder(releases.id)
            let intoFolder = model.navigationDirection
            model.selection = .collection(inside.id)
            let intoCollection = model.navigationDirection
            model.selection = .folder(releases.id)
            let backOut = model.navigationDirection
            model.selection = .allTracks
            model.selection = .search
            let lateral = model.navigationDirection
            check(intoFolder == .forward && intoCollection == .forward && backOut == .back && lateral == .lateral, "page transitions follow depth")
            model.selection = .home
        }

        // Tracks dragged onto a folder stay where they are (folders hold collections).
        if let track = store.tracks.values.first, let folder = store.folders.values.first {
            let before = store.collections(containing: track.id).map(\.id)
            model.move([.track(track.id)], toFolder: folder.id)
            check(store.collections(containing: track.id).map(\.id) == before, "tracks aren't moved into folders")
        }

        // Collections made from loose files are named after their folder,
        // unless it's a system or temporary one.
        let home = LibraryLocation.realHomeDirectory
        check(AppModel.collectionName(forFiles: [home.appending(path: "Music/Ideas/a.wav"), home.appending(path: "Music/Ideas/b.wav")]) == "Ideas"
              && AppModel.collectionName(forFiles: [LibraryLocation.iCloudDriveDirectory.appending(path: "a.wav")]) == "New Collection"
              && AppModel.collectionName(forFiles: [home.appending(path: "A/a.wav"), home.appending(path: "B/b.wav")]) == "New Collection"
              && AppModel.collectionName(forFiles: [FileManager.default.temporaryDirectory.appending(path: "x/a.wav")]) == "New Collection",
              "collections from files get sensible names")

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

        check(NSApp.windows.contains { KeyboardShortcuts.isMainWindow($0) }, "the library window can be told apart (Escape closes the glass + menu)")

        log("SELFTEST \(failures == 0 ? "OK" : "FAILED (\(failures))")")
        NSApp.terminate(nil)
    }

    /// The launch screen and the welcome screen (run with -showOnboarding).
    @MainActor
    private static func shootOnboarding(into folder: URL) async {
        func shoot(_ name: String, after delay: Duration) async {
            try? await Task.sleep(for: delay)
            log("READY \(name)")
            let done = folder.appending(path: "\(name).done")
            for _ in 0..<120 where !FileManager.default.fileExists(atPath: done.path) {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        NSApp.activate()
        await shoot("0a-launch", after: .milliseconds(500))
        await shoot("0b-onboarding", after: .seconds(2))
        await shoot("0c-onboarding-later", after: .seconds(3))
        log("SNAPSHOTS: \(folder.path)")
        if arguments.contains("-quitAfterSnapshot") { NSApp.terminate(nil) }
    }

    /// Renders the CD shader screens off-screen (no window needed) to
    /// -snapshotDir, at two moments so the moving light shows, then quits.
    @MainActor
    private static func renderShaders() async {
        let folder = argument(after: "-snapshotDir").map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory.appending(path: "snapshots", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func render(_ view: some View, _ name: String) {
            let renderer = ImageRenderer(content: view.environment(AppModel.shared))
            renderer.scale = 2
            guard let image = renderer.cgImage else {
                log("FAIL render \(name)")
                return
            }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
            log("rendered \(name)")
        }
        render(OnboardingView().frame(width: 1320, height: 860), "shader-onboarding-a")
        render(OnboardingView(timeOffset: 6).frame(width: 1320, height: 860), "shader-onboarding-b")
        render(LaunchScreen(alwaysShowsStatus: true).frame(width: 1320, height: 860), "shader-launch")
        render(
            HStack(spacing: 40) {
                AddButton(isOpen: .constant(false))
                AddButton(isOpen: .constant(true))
            }
            .padding(40)
            .background(Color(nsColor: .textBackgroundColor)),
            "add-button"
        )
        render(ArtworkChoices(target: .collection(UUID()), hasArtwork: true).background(Color(nsColor: .windowBackgroundColor)), "artwork-choices")
        render(AddMenu().background(Color(nsColor: .windowBackgroundColor)), "add-menu")
        render(UnsplashPicker(target: .collection(UUID())).background(Color(nsColor: .windowBackgroundColor)), "unsplash-connect")
        log("SNAPSHOTS: \(folder.path)")
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
