import SwiftUI
import UnnamedKit

@main
struct UnnamedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Unnamed", id: "main") {
            RootView()
                .environment(model)
                .environment(model.player)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1320, height: 860)
        .defaultLaunchBehavior(.presented)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            KeyboardShortcuts.handle(event)
        }
        // Open the library even if no window is showing yet (e.g. restored closed).
        Task { await AppModel.shared.start() }
        #if DEBUG
        DebugSupport.scheduleSnapshotIfRequested()
        #endif
    }

    /// Keep playing when the window is closed, like Music.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.importFromFinder(urls)
    }

    /// Lets pending writes (like notes still being typed) reach the disk.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.store?.waitForWrites(timeout: 5)
        return .terminateNow
    }
}

/// Space to play/pause anywhere except while typing, and making sure
/// playback shortcuts that collide with text editing (⌘← / ⌘→) still edit text.
enum KeyboardShortcuts {
    static func handle(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let textView = event.window?.firstResponder as? NSTextView
        let isEditingText = textView?.isEditable == true

        if event.keyCode == 49, modifiers.isEmpty, !isEditingText {
            AppModel.shared.player.togglePlayPause()
            return nil
        }
        // ⌘← ⌘→ ⌘↑ ⌘↓ are playback menu shortcuts; while typing they should move the cursor.
        let arrows: Set<UInt16> = [123, 124, 125, 126]
        if isEditingText, modifiers == .command || modifiers == [.command, .shift], arrows.contains(event.keyCode), let textView {
            textView.keyDown(with: event)
            return nil
        }
        return event
    }
}
