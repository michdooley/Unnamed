import Foundation

/// Remembers which folder is the library across launches, using a
/// security-scoped bookmark so the sandboxed app can reopen it.
struct LibraryLocation {
    enum Resolution {
        case none
        case found(URL)
        /// The bookmark exists but can't be resolved (folder moved, deleted, or
        /// the app was re-signed). Holds the last known path for the UI.
        case broken(lastKnownPath: String?)
    }

    private let defaults = UserDefaults.standard
    private let bookmarkKey = "library.bookmark"
    private let pathKey = "library.path"

    var lastKnownPath: String? { defaults.string(forKey: pathKey) }

    func save(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: bookmarkKey)
        defaults.set(url.path, forKey: pathKey)
    }

    func resolve() -> Resolution {
        guard let data = defaults.data(forKey: bookmarkKey) else { return .none }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return .broken(lastKnownPath: lastKnownPath)
        }
        if isStale {
            let accessing = url.startAccessingSecurityScopedResource()
            try? save(url)
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return .found(url)
    }

    func forget() {
        defaults.removeObject(forKey: bookmarkKey)
    }

    /// The user's real home folder (inside the sandbox, `homeDirectory` points at the container).
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(filePath: String(cString: dir), directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var iCloudDriveDirectory: URL {
        realHomeDirectory.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    }

    static var iCloudDriveIsAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
            || FileManager.default.fileExists(atPath: iCloudDriveDirectory.path)
    }
}
