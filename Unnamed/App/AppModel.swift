import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UnnamedKit

enum SidebarItem: Hashable {
    case home
    case allTracks
    case search
    case collection(UUID)
}

enum TrackDetailPane: Hashable {
    case actions
    case notes
    case comments
    case edit
    case addToCollection
    case moveToCollection
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
        case newCollection(trackIDs: [UUID])
        case renameCollection(UUID)
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

    var id: UUID {
        switch self {
        case .track(let id), .collection(let id): id
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
    var authorName: String {
        didSet { UserDefaults.standard.set(authorName, forKey: "comments.author") }
    }

    @ObservationIgnored private let location = LibraryLocation()
    @ObservationIgnored private var accessedRoot: URL?
    @ObservationIgnored private var pendingOpenURLs: [URL] = []

    init() {
        let defaults = UserDefaults.standard
        recentCollectionIDs = (defaults.stringArray(forKey: "collections.recent") ?? []).compactMap(UUID.init(uuidString:))
        authorName = defaults.string(forKey: "comments.author") ?? NSFullUserName()
    }

    // MARK: - Library lifecycle

    func start() async {
        guard store == nil, !isOpening else { return }
        #if DEBUG
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

    /// Collections in sidebar order: recently played first, then newest.
    var orderedCollections: [TrackCollection] {
        guard let store else { return [] }
        let rank = Dictionary(recentCollectionIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return store.collections.values.sorted { a, b in
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

    func promptNewCollection(with trackIDs: [UUID] = []) {
        namePrompt = NamePrompt(purpose: .newCollection(trackIDs: trackIDs), title: "New Collection", confirmLabel: "Create", text: "")
    }

    func promptRename(collectionID: UUID) {
        guard let collection = store?.collections[collectionID] else { return }
        namePrompt = NamePrompt(purpose: .renameCollection(collectionID), title: "Rename Collection", confirmLabel: "Rename", text: collection.title)
    }

    func commit(_ prompt: NamePrompt) {
        guard let store else { return }
        switch prompt.purpose {
        case .newCollection(let trackIDs):
            let collection = store.createCollection(title: prompt.text, trackIDs: trackIDs)
            selection = .collection(collection.id)
        case .renameCollection(let id):
            store.renameCollection(id, to: prompt.text)
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
            if selectedCollectionID == id { selection = .home }
            store.deleteCollection(id, deleteTracks: deleteTracks)
            player.libraryDidChange()
        }
    }

    // MARK: - Importing

    /// Asks for audio files (or folders of them) and imports them.
    func importAudio(into collectionID: UUID?) {
        let panel = NSOpenPanel()
        panel.title = "Add Tracks"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio, .folder]
        guard panel.runModal() == .OK else { return }
        let urls = DropPayload.expandFolders(panel.urls)
        Task { await importFiles(urls, into: collectionID) }
    }

    func importFiles(_ urls: [URL], into collectionID: UUID?, at index: Int? = nil) async {
        guard let store, !urls.isEmpty else { return }
        let imported = await store.importAudio(from: urls, into: collectionID, at: index)
        if collectionID == nil, !imported.isEmpty, selectedCollectionID == nil, selection != .allTracks {
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
        Task { await importFiles(audio, into: selectedCollectionID) }
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

    func replaceAudio(of trackID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Replace Audio"
        panel.prompt = "Replace"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await store?.replaceAudio(of: trackID, with: url)
            player.libraryDidChange()
        }
    }

    func exportAudio(of trackID: UUID) {
        guard let store, let track = store.tracks[trackID], let source = store.audioURL(for: trackID) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Audio"
        panel.nameFieldStringValue = "\(sanitized(track.title)).\(source.pathExtension)"
        if let type = UTType(filenameExtension: source.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                try await store.exportAudio(of: trackID, to: destination)
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
