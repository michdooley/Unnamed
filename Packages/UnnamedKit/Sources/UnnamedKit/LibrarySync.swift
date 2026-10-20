import Foundation

/// What keeps a library folder in step with other devices, as far as the app
/// can tell from where the folder is.
///
/// iCloud Drive is what the app is built around, but the library is only
/// files, so any service that syncs a folder works:
/// - Cloud services built on Apple's File Provider (Dropbox, Google Drive,
///   OneDrive, Box, Proton Drive…) keep their folders in ~/Library/CloudStorage,
///   and like iCloud Drive leave files in the cloud until they're needed.
/// - Tools that keep a full copy on every device (Syncthing, Nextcloud's
///   desktop client, Resilio Sync, Synology Drive…).
/// - A folder on a network drive.
public struct LibrarySync: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case iCloud
        /// A File Provider service in ~/Library/CloudStorage.
        case cloudStorage
        /// A tool keeping full copies in step.
        case folderSync
        case networkDrive
        /// Only on this Mac.
        case none
    }

    public var kind: Kind
    /// The service's name ("iCloud Drive", "Dropbox"), or "This Mac".
    public var name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    public static let iCloudDrive = LibrarySync(kind: .iCloud, name: "iCloud Drive")
    public static let thisMac = LibrarySync(kind: .none, name: "This Mac")

    /// Files can be in the cloud only, downloading when they're needed.
    public var downloadsOnDemand: Bool { kind == .iCloud || kind == .cloudStorage }
    public var syncs: Bool { kind != .none }
}

public extension LibrarySync {
    /// Works out what syncs the folder at `url`. Works from the path alone
    /// where it can (a sandboxed app can't look outside its library), then
    /// from what the system says about the folder, then from the marker files
    /// sync tools leave in the folders they keep.
    static func detect(_ url: URL) -> LibrarySync {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path

        if path.contains("/Library/Mobile Documents/") { return .iCloudDrive }
        if let range = path.range(of: "/Library/CloudStorage/") {
            let folder = path[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            return LibrarySync(kind: .cloudStorage, name: cloudStorageName(folder))
        }

        let values = try? resolved.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemContainerDisplayNameKey,
                                                             .volumeIsLocalKey, .volumeLocalizedNameKey])
        if values?.isUbiquitousItem == true {
            // iCloud names its containers; other File Provider services don't.
            return values?.ubiquitousItemContainerDisplayName != nil ? .iCloudDrive : LibrarySync(kind: .cloudStorage, name: "cloud storage")
        }

        var directory = resolved
        while true {
            if let tool = folderSyncTool(markedIn: directory) {
                return LibrarySync(kind: .folderSync, name: tool)
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path, parent.path != "/" else { break }
            directory = parent
        }
        if let tool = folderSyncTool(named: resolved) {
            return LibrarySync(kind: .folderSync, name: tool)
        }

        if values?.volumeIsLocal == false {
            return LibrarySync(kind: .networkDrive, name: values?.volumeLocalizedName ?? "a network drive")
        }
        return .thisMac
    }

    /// "GoogleDrive-name@example.com" → "Google Drive".
    internal static func cloudStorageName(_ folder: String) -> String {
        let service = folder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folder
        let known = [
            "Dropbox": "Dropbox", "GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Box": "Box",
            "ProtonDrive": "Proton Drive", "pCloud": "pCloud", "pCloudDrive": "pCloud", "Nextcloud": "Nextcloud",
            "ownCloud": "ownCloud", "SynologyDrive": "Synology Drive", "Egnyte": "Egnyte", "MEGA": "MEGA",
            "Tresorit": "Tresorit", "SharePoint": "SharePoint",
        ]
        if let name = known[service] { return name }
        // "SomeService" → "Some Service"
        var spaced = ""
        for character in service {
            if character.isUppercase, let last = spaced.last, last.isLowercase { spaced.append(" ") }
            spaced.append(character)
        }
        return spaced.isEmpty ? "cloud storage" : spaced
    }

    /// A sync tool's own marker in a folder it keeps (the root of what it syncs).
    internal static func folderSyncTool(markedIn directory: URL) -> String? {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: directory.appending(path: name).path) }
        if exists(".stfolder") { return "Syncthing" }
        if exists(".SynologyWorkingDirectory") { return "Synology Drive" }
        if exists(".sync/ID") { return "Resilio Sync" }
        if exists(".dropbox") { return "Dropbox" }
        // Nextcloud's (and ownCloud's) client keeps its journal in the folder's
        // root: ".sync_<hash>.db", or "._sync_<hash>.db" from older clients.
        if allNames(in: directory).contains(where: { ($0.hasPrefix(".sync_") || $0.hasPrefix("._sync_")) && $0.hasSuffix(".db") }) {
            return "Nextcloud"
        }
        return nil
    }

    /// Every name in a folder. (FileManager leaves out names starting "._".)
    private static func allNames(in directory: URL) -> [String] {
        guard let stream = opendir(directory.path) else { return [] }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            names.append(name)
        }
        return names
    }

    /// Sync tools' usual folder names along the path (for when the sandbox
    /// keeps their marker files out of reach).
    internal static func folderSyncTool(named url: URL) -> String? {
        let names: [String: String] = [
            "dropbox": "Dropbox", "google drive": "Google Drive", "my drive": "Google Drive", "onedrive": "OneDrive",
            "nextcloud": "Nextcloud", "owncloud": "ownCloud", "syncthing": "Syncthing", "resilio sync": "Resilio Sync",
            "synologydrive": "Synology Drive", "synology drive": "Synology Drive", "mega": "MEGA", "megasync": "MEGA",
            "pcloud drive": "pCloud", "box sync": "Box", "proton drive": "Proton Drive",
        ]
        for component in url.pathComponents {
            let lowered = component.lowercased()
            if let name = names[lowered] { return name }
            // OneDrive for work names its folder "OneDrive - Company".
            if lowered.hasPrefix("onedrive - ") { return "OneDrive" }
        }
        return nil
    }
}

/// The copies sync services leave beside a file both sides changed:
/// Dropbox's "name (Sam's conflicted copy 2026-10-19).json", Syncthing's
/// "name.sync-conflict-20261019-153012-ABC1234.json", OneDrive's
/// "name-MacBook.json", Nextcloud's "name (conflicted copy 2026-10-19
/// 153012).json", iCloud Drive's "name 2.json"… Only the library's own
/// metadata files are looked at this way (never audio, artwork or media,
/// whose names can legitimately look like this).
enum ConflictCopies {
    /// Whether `name` is a sync service's copy of the file `original`.
    static func isCopy(_ name: String, of original: String) -> Bool {
        let fileExtension = (original as NSString).pathExtension
        let stem = (original as NSString).deletingPathExtension
        guard name != original, name.count > original.count + 1,
              name.hasPrefix(stem), name.hasSuffix("." + fileExtension) else { return false }
        let separator = name[name.index(name.startIndex, offsetBy: stem.count)]
        return " -_.(".contains(separator)
    }
}
