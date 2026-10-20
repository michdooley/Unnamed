import UnnamedKit

/// How the app talks about what syncs the library.
extension LibrarySync {
    var systemImage: String {
        switch kind {
        case .iCloud: "icloud"
        case .cloudStorage: "cloud"
        case .folderSync: "arrow.triangle.2.circlepath"
        case .networkDrive: "externaldrive.connected.to.line.below"
        case .none: "internaldrive"
        }
    }

    /// Short, for the sidebar: "iCloud Drive", "Dropbox", "On this Mac".
    var label: String {
        syncs ? name : "On this Mac"
    }

    /// A sentence for Settings.
    var summary: String {
        switch kind {
        case .iCloud:
            "Syncs to your other Macs through your iCloud account. Audio stays in iCloud until you play it, so it doesn't fill up this Mac."
        case .cloudStorage:
            "Syncs through \(name), which keeps it on your other devices. Like iCloud Drive, audio can stay in the cloud until you play it."
        case .folderSync:
            "Syncs through \(name), which keeps a full copy on each device."
        case .networkDrive:
            "Lives on \(name), so every Mac that can reach it sees the same library."
        case .none:
            "Kept on this Mac only. To sync it, keep your library in iCloud Drive (or in a folder another sync service keeps)."
        }
    }

    /// Where audio waits when it isn't downloaded: "in iCloud", "in Dropbox".
    var cloudName: String {
        kind == .iCloud ? "iCloud" : name
    }
}
