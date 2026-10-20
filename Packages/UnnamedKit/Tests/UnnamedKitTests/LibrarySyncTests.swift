import Foundation
import Testing
@testable import UnnamedKit

/// A library can live in any synced folder: iCloud Drive first, but also
/// Dropbox, Google Drive, OneDrive, Syncthing, Nextcloud…
struct LibrarySyncTests {
    @Test(arguments: [
        ("/Users/sam/Library/Mobile Documents/com~apple~CloudDocs/Music Ideas", LibrarySync.Kind.iCloud, "iCloud Drive"),
        ("/Users/sam/Library/CloudStorage/Dropbox/Music Ideas", .cloudStorage, "Dropbox"),
        ("/Users/sam/Library/CloudStorage/GoogleDrive-sam@example.com/My Drive/Ideas", .cloudStorage, "Google Drive"),
        ("/Users/sam/Library/CloudStorage/OneDrive-Personal/Ideas", .cloudStorage, "OneDrive"),
        ("/Users/sam/Library/CloudStorage/Box-Box/Ideas", .cloudStorage, "Box"),
        ("/Users/sam/Library/CloudStorage/ProtonDrive-sam@proton.me-folder/Ideas", .cloudStorage, "Proton Drive"),
        ("/Users/sam/Library/CloudStorage/SomeNewService-sam/Ideas", .cloudStorage, "Some New Service"),
        ("/Users/sam/Nextcloud/Ideas", .folderSync, "Nextcloud"),
        ("/Users/sam/OneDrive - Contoso/Ideas", .folderSync, "OneDrive"),
        ("/Users/sam/Music/Ideas", .none, "This Mac"),
    ])
    func recognisesServicesByWhereTheFolderIs(path: String, kind: LibrarySync.Kind, name: String) {
        let sync = LibrarySync.detect(URL(filePath: path, directoryHint: .isDirectory))
        #expect(sync.kind == kind)
        #expect(sync.name == name)
    }

    @Test func recognisesSyncToolsByTheirMarkers() throws {
        let root = try TestAudio.temporaryDirectory()
        let syncthing = root.appending(path: "Shared")
        try FileManager.default.createDirectory(at: syncthing.appending(path: ".stfolder"), withIntermediateDirectories: true)
        let library = syncthing.appending(path: "Music/Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        #expect(LibrarySync.detect(library) == LibrarySync(kind: .folderSync, name: "Syncthing"))

        let nextcloud = root.appending(path: "Work")
        try FileManager.default.createDirectory(at: nextcloud, withIntermediateDirectories: true)
        try Data().write(to: nextcloud.appending(path: "._sync_3f9e1a.db"))
        #expect(LibrarySync.detect(nextcloud.appending(path: "Ideas")).name == "Nextcloud")

        let plain = root.appending(path: "Plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(LibrarySync.detect(plain) == .thisMac)
        #expect(!LibrarySync.thisMac.syncs)
        #expect(LibrarySync.iCloudDrive.downloadsOnDemand)
    }

    @Test(arguments: [
        "track (Sam's conflicted copy 2026-10-19).json",   // Dropbox
        "track (conflicted copy 2026-10-19 153012).json",  // Nextcloud
        "track.sync-conflict-20261019-153012-ABC1234.json", // Syncthing
        "track-MacBook Pro.json",                           // OneDrive
        "track 2.json",                                     // iCloud Drive
        "track (1).json",                                   // Google Drive
    ])
    func spotsConflictCopies(name: String) {
        #expect(ConflictCopies.isCopy(name, of: "track.json"))
    }

    @Test func leavesOtherNamesAlone() {
        #expect(!ConflictCopies.isCopy("track.json", of: "track.json"))
        #expect(!ConflictCopies.isCopy("tracks.json", of: "track.json"))
        #expect(!ConflictCopies.isCopy("track 2.md", of: "track.json"))
        #expect(!ConflictCopies.isCopy("track.json.sb-1234", of: "track.json"))
        #expect(!ConflictCopies.isCopy("notes.md", of: "track.json"))
    }

    /// A scan settles conflict copies: the newest edit wins.
    @Test func newestEditWinsOverAConflictCopy() async throws {
        let root = try TestAudio.temporaryDirectory()
        let layout = LibraryLayout(root: root)
        let disk = LibraryDisk(layout: layout) { try FileManager.default.removeItem(at: $0) }
        try await disk.prepare()
        let trackID = UUID()
        let dir = layout.trackDir(trackID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func track(_ title: String, updated: String) -> Data {
            Data(#"{"id": "\#(trackID.uuidString)", "title": "\#(title)", "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "\#(updated)"}"#.utf8)
        }
        try track("Before", updated: "2026-10-19T10:00:00Z").write(to: dir.appending(path: "track.json"))
        try track("After, on the other Mac", updated: "2026-10-19T11:00:00Z").write(to: dir.appending(path: "track (Sam's conflicted copy 2026-10-19).json"))
        // A comment edited on both sides, the original being the newer one.
        let commentID = UUID()
        let comments = layout.commentsDir(trackID)
        try FileManager.default.createDirectory(at: comments, withIntermediateDirectories: true)
        func comment(_ text: String, updated: String) -> Data {
            Data(#"{"id": "\#(commentID.uuidString)", "timestamp": 3, "text": "\#(text)", "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "\#(updated)"}"#.utf8)
        }
        try comment("newer", updated: "2026-10-19T12:00:00Z").write(to: comments.appending(path: "\(commentID.uuidString).json"))
        try comment("older", updated: "2026-10-19T09:00:00Z").write(to: comments.appending(path: "\(commentID.uuidString).sync-conflict-20261019-090000-ABC1234.json"))
        // Notes that only arrived as a copy.
        try Data("lyrics".utf8).write(to: dir.appending(path: "notes 2.md"))

        let snapshot = await disk.scan()
        #expect(snapshot.tracks[trackID]?.title == "After, on the other Mac")
        #expect(snapshot.comments[trackID]?.first?.text == "newer")
        #expect(snapshot.notes[trackID] == "lyrics")
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(!left.contains { $0.contains("conflicted copy") || $0 == "notes 2.md" })
        #expect(try FileManager.default.contentsOfDirectory(atPath: comments.path) == ["\(commentID.uuidString).json"])
    }
}
