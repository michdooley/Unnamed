import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UnnamedKit

enum SidebarItem: Hashable {
    case home
    case allTracks
    case search
    case collection(UUID)
    case folder(UUID)
}

enum TrackDetailPane: Hashable {
    case actions
    case notes
    case comments
    case edit
    case versions
    case addToCollection
    case moveToCollection
    case folder
}

struct TrackDetailRoute: Identifiable, Hashable {
    var trackID: UUID
    /// The collection the details were opened from, for Move / Remove.
    var collectionID: UUID?
    var pane: TrackDetailPane = .actions
    var id: UUID { trackID }
}

struct NamePrompt: Identifiable {
    enum Purpose {
        case newCollection(trackIDs: [UUID], folder: UUID?)
        case renameCollection(UUID)
        case newFolder(parent: UUID?, moving: [LibraryItemRef])
        case renameFolder(UUID)
    }

    let id = UUID()
    var purpose: Purpose
    var title: String
    var confirmLabel: String
    var text: String
}

enum PendingDeletion: Identifiable {
    case track(UUID)
    case collection(UUID)
    case folder(UUID)

    var id: UUID {
        switch self {
        case .track(let id), .collection(let id), .folder(let id): id
        }
    }
}

/// App-wide state: the open library, the player, navigation, and the
/// AppKit panels (open/save) the views trigger.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let player = PlayerController()
    private(set) var store: LibraryStore?
    private(set) var isOpening = false
    /// Set when the remembered library couldn't be reopened.
    private(set) var reconnectPath: String?

    var selection: SidebarItem? = .home
    var searchText = ""
    var searchFocused = false
    var detail: TrackDetailRoute?
    var namePrompt: NamePrompt?
    var pendingDeletion: PendingDeletion?
    /// Collection whose "Add from Library" picker is open.
    var pickerCollectionID: UUID?
    var alert: LibraryIssue?

    /// Collections most recently played first, like the original sidebar.
    private(set) var recentCollectionIDs: [UUID]
    /// Folders open in the sidebar.
    private(set) var expandedFolders: Set<UUID>
    var authorName: String {
        didSet { UserDefaults.standard.set(authorName, forKey: "comments.author") }
    }

    /// The launch screen shows once per launch, not every time the window reopens.
    var launchScreenFinished = false

    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private let location = LibraryLocation()
    @ObservationIgnored private var accessedRoot: URL?
    @ObservationIgnored private var pendingOpenURLs: [URL] = []

    init() {
        let defaults = UserDefaults.standard
        recentCollectionIDs = (defaults.stringArray(forKey: "collections.recent") ?? []).compactMap(UUID.init(uuidString:))
        expandedFolders = Set((defaults.stringArray(forKey: "folders.expanded") ?? []).compactMap(UUID.init(uuidString:)))
        authorName = defaults.string(forKey: "comments.author") ?? NSFullUserName()
    }

    // MARK: - Library lifecycle

    /// Opens the remembered library. Safe to call from several places: they
    /// all wait for the same startup.
    func start() async {
        if startup == nil {
            startup = Task { await performStart() }
        }
        await startup?.value
    }

    private func performStart() async {
        guard store == nil, !isOpening else { return }
        #if DEBUG
        if DebugSupport.arguments.contains("-showOnboarding") { return }
        if let demo = DebugSupport.demoLibraryURL() {
            await open(demo, remember: false)
            await DebugSupport.populateDemoLibraryIfEmpty(self)
            return
        }
        #endif
        switch location.resolve() {
        case .none:
            break
        case .found(let url):
            await open(url, remember: false)
        case .broken(let path):
            reconnectPath = path ?? "your library"
        }
    }

    func open(_ url: URL, remember: Bool) async {
        isOpening = true
        defer { isOpening = false }
        if let old = store {
            player.stop()
            await old.close()
            store = nil
        }
        if let accessedRoot {
            accessedRoot.stopAccessingSecurityScopedResource()
        }
        accessedRoot = url.startAccessingSecurityScopedResource() ? url : nil
        if remember {
            do {
                try location.save(url)
            } catch {
                alert = LibraryIssue(title: "Couldn't remember this folder", message: error.localizedDescription)
            }
        }
        let store = LibraryStore(root: url)
        player.library = store
        await store.load()
        store.startWatching()
        self.store = store
        reconnectPath = nil
        selection = .home
        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            importFromFinder(urls)
        }
    }

    // MARK: - Choosing a library

    func createLibraryInICloud() {
        let panel = NSSavePanel()
        panel.title = "Create Library"
        panel.message = "Choose where to keep your library. Put it in iCloud Drive to sync it to your other devices."
        panel.prompt = "Create"
        panel.nameFieldLabel = "Library name:"
        panel.nameFieldStringValue = "Unnamed Library"
        panel.canCreateDirectories = true
        panel.directoryURL = LibraryLocation.iCloudDriveDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            alert = LibraryIssue(title: "Couldn't create the library", message: error.localizedDescription)
            return
        }
        Task { await open(url, remember: true) }
    }

    func chooseExistingLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Open Library"
        panel.message = "Choose a library folder (or any folder to start a new library in it)."
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let reconnectPath {
            panel.directoryURL = URL(filePath: reconnectPath).deletingLastPathComponent()
        } else {
            panel.directoryURL = LibraryLocation.iCloudDriveDirectory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url, remember: true) }
    }

    func revealLibraryInFinder() {
        guard let root = store?.root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    // MARK: - Navigation

    var selectedCollectionID: UUID? {
        if case .collection(let id) = selection { return id }
        return nil
    }

    var selectedFolderID: UUID? {
        if case .folder(let id) = selection { return id }
        return nil
    }

    /// The folder new things go into: the open folder, or the folder of the
    /// open collection.
    var currentFolderID: UUID? {
        if let folder = selectedFolderID { return folder }
        return selectedCollectionID.flatMap { store?.folder(ofCollection: $0) }
    }

    /// Every collection: recently played first, then newest.
    var orderedCollections: [TrackCollection] {
        sortedByRecency(store.map { Array($0.collections.values) } ?? [])
    }

    /// The collections directly in a folder (top level when nil), recently played first.
    func orderedCollections(in folderID: UUID?) -> [TrackCollection] {
        sortedByRecency(store?.collections(inFolder: folderID) ?? [])
    }

    private func sortedByRecency(_ collections: [TrackCollection]) -> [TrackCollection] {
        let rank = Dictionary(recentCollectionIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return collections.sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil):
                a.createdAt != b.createdAt
                    ? a.createdAt > b.createdAt
                    : LibraryStore.titleOrder(a.title, a.id, b.title, b.id)
            }
        }
    }

    /// A track's artwork, else its collection's. Without any image, tracks
    /// borrow their collection's gradient so they visually belong together.
    func artwork(forTrack trackID: UUID, in collectionID: UUID?) -> (url: URL?, seed: UUID) {
        let own = store?.artworkURL(forTrack: trackID)
        let collection = collectionID ?? store?.collections(containing: trackID).first?.id
        let inherited = collection.flatMap { store?.artworkURL(forCollection: $0) }
        return (own ?? inherited, own == nil ? (collection ?? trackID) : trackID)
    }

    func notePlayed(collectionID: UUID?) {
        guard let collectionID else { return }
        recentCollectionIDs.removeAll { $0 == collectionID }
        recentCollectionIDs.insert(collectionID, at: 0)
        if recentCollectionIDs.count > 200 { recentCollectionIDs.removeLast(recentCollectionIDs.count - 200) }
        UserDefaults.standard.set(recentCollectionIDs.map(\.uuidString), forKey: "collections.recent")
    }

    func showDetails(for trackID: UUID, in collectionID: UUID?, pane: TrackDetailPane = .actions) {
        detail = TrackDetailRoute(trackID: trackID, collectionID: collectionID, pane: pane)
    }

    /// The collection the current track is playing from, if it's really in it
    /// (an "up next" track may not be).
    private var currentTrackCollectionID: UUID? {
        guard let trackID = player.currentTrackID, let id = player.contextCollectionID,
              store?.collections[id]?.trackIDs.contains(trackID) == true else { return nil }
        return id
    }

    /// Jumps to whatever is playing.
    func revealNowPlaying() {
        guard let trackID = player.currentTrackID else { return }
        let collectionID = currentTrackCollectionID
        selection = collectionID.map(SidebarItem.collection) ?? .allTracks
        showDetails(for: trackID, in: collectionID)
    }

    func commentOnCurrentTrack() {
        guard let trackID = player.currentTrackID else { return }
        showDetails(for: trackID, in: currentTrackCollectionID, pane: .comments)
    }

    func focusSearch() {
        selection = .search
        searchFocused = true
    }

    // MARK: - Collections

    /// New collection in `folder` (the current folder by default).
    func promptNewCollection(with trackIDs: [UUID] = [], in folder: UUID?? = .none) {
        let folder = folder ?? currentFolderID
        namePrompt = NamePrompt(purpose: .newCollection(trackIDs: trackIDs, folder: folder), title: "New Collection", confirmLabel: "Create", text: "")
    }

    /// New folder inside `parent` (the current folder by default), optionally
    /// moving some items into it.
    func promptNewFolder(in parent: UUID?? = .none, moving items: [LibraryItemRef] = []) {
        namePrompt = NamePrompt(purpose: .newFolder(parent: parent ?? currentFolderID, moving: items), title: "New Folder", confirmLabel: "Create", text: "")
    }

    func promptRename(folderID: UUID) {
        guard let folder = store?.folders[folderID] else { return }
        namePrompt = NamePrompt(purpose: .renameFolder(folderID), title: "Rename Folder", confirmLabel: "Rename", text: folder.title)
    }

    func promptRename(collectionID: UUID) {
        guard let collection = store?.collections[collectionID] else { return }
        namePrompt = NamePrompt(purpose: .renameCollection(collectionID), title: "Rename Collection", confirmLabel: "Rename", text: collection.title)
    }

    func commit(_ prompt: NamePrompt) {
        guard let store else { return }
        switch prompt.purpose {
        case .newCollection(let trackIDs, let folder):
            let collection = store.createCollection(title: prompt.text, trackIDs: trackIDs, in: folder)
            selection = .collection(collection.id)
        case .renameCollection(let id):
            store.renameCollection(id, to: prompt.text)
        case .newFolder(let parent, let items):
            let folder = store.createFolder(title: prompt.text, in: parent)
            move(items, toFolder: folder.id)
            selection = .folder(folder.id)
        case .renameFolder(let id):
            store.renameFolder(id, to: prompt.text)
        }
    }

    func confirmDeletion(_ deletion: PendingDeletion, deleteTracks: Bool = false) {
        guard let store else { return }
        switch deletion {
        case .track(let id):
            if detail?.trackID == id { detail = nil }
            store.deleteTrack(id)
            player.libraryDidChange()
        case .collection(let id):
            if selectedCollectionID == id {
                selection = store.folder(ofCollection: id).map(SidebarItem.folder) ?? .home
            }
            store.deleteCollection(id, deleteTracks: deleteTracks)
            player.libraryDidChange()
        case .folder(let id):
            if selectedFolderID == id {
                selection = store.parentFolder(of: id).map(SidebarItem.folder) ?? .home
            }
            store.deleteFolder(id)
        }
    }

    // MARK: - Folders

    func toggleExpanded(_ folderID: UUID) {
        if expandedFolders.contains(folderID) {
            expandedFolders.remove(folderID)
        } else {
            expandedFolders.insert(folderID)
        }
        UserDefaults.standard.set(expandedFolders.map(\.uuidString), forKey: "folders.expanded")
    }

    /// Opens the folders above a selected item so it's visible in the sidebar.
    func revealInSidebar(_ item: SidebarItem?) {
        guard let store else { return }
        let parent: UUID? = switch item {
        case .collection(let id): store.folder(ofCollection: id)
        case .folder(let id): store.parentFolder(of: id)
        default: nil
        }
        guard let parent else { return }
        let path = Set(store.folderPath(to: parent).map(\.id))
        guard !path.isSubset(of: expandedFolders) else { return }
        expandedFolders.formUnion(path)
        UserDefaults.standard.set(expandedFolders.map(\.uuidString), forKey: "folders.expanded")
    }

    /// Moves tracks, collections and folders into a folder (top level when nil).
    /// A track moved into a folder keeps its collections.
    func move(_ items: [LibraryItemRef], toFolder folderID: UUID?) {
        guard let store else { return }
        for item in items {
            switch item {
            case .track(let id): store.moveTrack(id, toFolder: folderID)
            case .collection(let id): store.moveCollection(id, toFolder: folderID)
            case .folder(let id):
                if id != folderID { store.moveFolder(id, into: folderID) }
            }
        }
    }

    /// Handles a drop onto a folder (or the top level when nil): moves
    /// dragged items in and imports dropped files into it.
    func handleDrop(_ payload: DropPayload, intoFolder folderID: UUID?) async {
        move(payload.items, toFolder: folderID)
        if !payload.fileURLs.isEmpty {
            await importFiles(payload.fileURLs, into: nil, folder: folderID)
        }
    }

    // MARK: - Importing

    /// Asks for audio files (or folders of them) and imports them into a
    /// collection and/or folder.
    func importAudio(into collectionID: UUID?, folder: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Add Tracks"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio, .folder]
        guard panel.runModal() == .OK else { return }
        let urls = DropPayload.expandFolders(panel.urls)
        Task { await importFiles(urls, into: collectionID, folder: folder) }
    }

    func importFiles(_ urls: [URL], into collectionID: UUID?, at index: Int? = nil, folder: UUID? = nil) async {
        guard let store, !urls.isEmpty else { return }
        let imported = await store.importAudio(from: urls, into: collectionID, at: index, folder: folder)
        // Show where loose imports went, unless they're visible already.
        if collectionID == nil, folder == nil, !imported.isEmpty, selectedCollectionID == nil, selectedFolderID == nil, selection != .allTracks {
            selection = .allTracks
        }
    }

    /// Files opened from Finder ("Open With", dropped on the Dock icon).
    func importFromFinder(_ urls: [URL]) {
        guard store != nil else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        let audio = DropPayload.expandFolders(urls).filter(AudioAnalyzer.isAudioFile)
        Task { await importFiles(audio, into: selectedCollectionID, folder: selectedFolderID) }
    }

    /// Handles a drop of files or tracks onto a collection (or the library when nil).
    func handleDrop(_ payload: DropPayload, into collectionID: UUID?, before targetTrackID: UUID? = nil) async {
        guard let store else { return }
        if let collectionID, !payload.trackIDs.isEmpty {
            let existing = store.collections[collectionID]?.trackIDs ?? []
            let reordering = payload.trackIDs.filter(existing.contains)
            let adding = payload.trackIDs.filter { !existing.contains($0) }
            // Dropping a track on a collection it's already in (sidebar, card,
            // empty space) leaves it where it is; only drops onto a row reorder.
            if !reordering.isEmpty, let targetTrackID {
                store.reorder(reordering, in: collectionID, before: targetTrackID)
            }
            if !adding.isEmpty {
                let index = targetTrackID.flatMap { store.collections[collectionID]?.trackIDs.firstIndex(of: $0) }
                store.addTracks(adding, to: collectionID, at: index)
            }
        }
        if !payload.fileURLs.isEmpty {
            let index = collectionID.flatMap { id in targetTrackID.flatMap { store.collections[id]?.trackIDs.firstIndex(of: $0) } }
            await importFiles(payload.fileURLs, into: collectionID, at: index)
        }
    }

    // MARK: - Artwork

    func chooseArtwork(forCollection collectionID: UUID) {
        guard let url = pickImage() else { return }
        Task { await store?.setArtwork(forCollection: collectionID, from: .file(url)) }
    }

    func chooseArtwork(forTrack trackID: UUID) {
        guard let url = pickImage() else { return }
        Task { await store?.setArtwork(forTrack: trackID, from: .file(url)) }
    }

    private func pickImage() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Artwork"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Track actions

    /// Asks for a file and adds it as the track's newest version.
    func uploadNewVersion(of trackID: UUID) {
        guard let title = store?.tracks[trackID]?.title else { return }
        let panel = NSOpenPanel()
        panel.title = "New Version of “\(title)”"
        panel.message = "The new version becomes the one that plays. Earlier versions stay in the version history."
        panel.prompt = "Add Version"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addVersion(to: trackID, from: url) }
    }

    func addVersion(to trackID: UUID, from url: URL) async {
        await store?.addVersion(to: trackID, from: url)
        player.libraryDidChange()
    }

    func exportAudio(of trackID: UUID, version: UUID? = nil) {
        guard let store, let track = store.tracks[trackID], let source = store.audioURL(for: trackID, version: version) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Audio"
        let suffix = version.map { " \(track.versionLabel(of: $0))" } ?? ""
        panel.nameFieldStringValue = "\(sanitized(track.title + suffix)).\(source.pathExtension)"
        if let type = UTType(filenameExtension: source.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                try await store.exportAudio(of: trackID, version: version, to: destination)
            } catch {
                alert = LibraryIssue(title: "Couldn't export “\(track.title)”", message: error.localizedDescription)
            }
        }
    }

    /// Exports every track in a collection as numbered files in a new folder.
    func exportCollection(_ collectionID: UUID) {
        guard let store, let collection = store.collections[collectionID] else { return }
        let panel = NSOpenPanel()
        panel.title = "Export “\(collection.title)”"
        panel.message = "A folder named “\(sanitized(collection.title))” will be created here."
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        Task {
            let folder = parent.appending(path: sanitized(collection.title), directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (index, track) in store.tracks(in: collectionID).enumerated() {
                    guard let source = store.audioURL(for: track.id) else { continue }
                    let name = String(format: "%02d %@.%@", index + 1, sanitized(track.title), source.pathExtension)
                    try await store.exportAudio(of: track.id, to: folder.appending(path: name))
                }
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch {
                alert = LibraryIssue(title: "Couldn't export “\(collection.title)”", message: error.localizedDescription)
            }
        }
    }

    func revealInFinder(trackID: UUID) {
        guard let url = store?.audioURL(for: trackID) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func duplicate(trackID: UUID, in collectionID: UUID?) {
        Task {
            guard let newID = await store?.duplicateTrack(trackID, in: collectionID) else { return }
            if detail?.trackID == trackID {
                detail = TrackDetailRoute(trackID: newID, collectionID: collectionID)
            }
        }
    }

    private func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
