import SwiftUI
import UnnamedKit

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Collection") { model.promptNewCollection() }
                .keyboardShortcut("n")
                .disabled(model.store == nil)
            Button(model.selectedCollectionID == nil ? "New Collection from Files…" : "Add Tracks…") {
                if let collectionID = model.selectedCollectionID {
                    model.importAudio(into: collectionID)
                } else {
                    model.newCollectionFromFiles()
                }
            }
            .keyboardShortcut("o")
            .disabled(model.store == nil)
            Button("New Folder") { model.promptNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.store == nil)
            Divider()
            Button("Open Library…") { model.chooseExistingLibrary() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Create Library…") { model.createLibraryInICloud() }
            Button("Show Library in Finder") { model.revealLibraryInFinder() }
                .disabled(model.store == nil)
            Divider()
            Button("Find Missing Keys and Tempos") { model.detectMissingKeysAndTempos() }
                .disabled(model.store == nil)
        }

        CommandGroup(before: .windowArrangement) {
            // Brings the library window back after it's been closed.
            Button("Library") { openWindow(id: "main") }
                .keyboardShortcut("1")
            Divider()
        }

        CommandGroup(before: .sidebar) {
            Button(model.moodboardOpen ? "Show Track List" : "Show Moodboard") { model.setMoodboardOpen(!model.moodboardOpen) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.selectedCollectionID == nil)
            Divider()
        }

        CommandMenu("Find") {
            Button("Search Library") { model.focusSearch() }
                .keyboardShortcut("f")
                .disabled(model.store == nil)
        }

        CommandMenu("Playback") {
            let player = model.player
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .disabled(!player.hasTrack)
            Button("Next Track") { player.next() }
                .keyboardShortcut(.rightArrow)
                .disabled(!player.hasTrack)
            Button("Previous Track") { player.previous() }
                .keyboardShortcut(.leftArrow)
                .disabled(!player.hasTrack)
            Divider()
            Button("Skip Forward 10 Seconds") { player.skip(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(!player.hasTrack)
            Button("Skip Back 10 Seconds") { player.skip(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .disabled(!player.hasTrack)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { player.shuffle }, set: { _ in player.toggleShuffle() }))
            Picker("Repeat", selection: Binding(get: { player.repeatMode }, set: { mode in
                while player.repeatMode != mode { player.cycleRepeatMode() }
            })) {
                Text("Off").tag(RepeatMode.off)
                Text("All").tag(RepeatMode.all)
                Text("One").tag(RepeatMode.one)
            }
            Divider()
            Button("Increase Volume") { player.setVolume(player.volume + 0.1) }
                .keyboardShortcut(.upArrow)
            Button("Decrease Volume") { player.setVolume(player.volume - 0.1) }
                .keyboardShortcut(.downArrow)
            Divider()
            Button("Comment at Current Time…") { model.commentOnCurrentTrack() }
                .keyboardShortcut("k")
                .disabled(!player.hasTrack)
            Button("Go to Current Track") { model.revealNowPlaying() }
                .keyboardShortcut("l")
                .disabled(!player.hasTrack)
        }
    }
}
