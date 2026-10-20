import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UnnamedKit

enum SidebarItem: Hashable {
    case home
    case allTracks
    case search
    case archive
    case collection(UUID)
    case folder(UUID)
}

/// A short message at the bottom of the window, optionally with an action ("Undo").
struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?
}

enum NavigationDirection {
    case forward, back, lateral
}

enum TrackDetailPane: Hashable {
    case actions
    case notes
    case comments
    case edit
    case versions
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

    var selection: SidebarItem? = .home {
        didSet {
            guard oldValue != selection else { return }
            moodboardOpen = false
            let from = depth(of: oldValue), to = depth(of: selection)
            navigationDirection = to > from ? .forward : to < from ? .back : .lateral
        }
    }
    /// Which way the last navigation went, for the page transition.
    private(set) var navigationDirection: NavigationDirection = .lateral
    var searchText = ""
    var searchFocused = false
    var detail: TrackDetailRoute?
    var namePrompt: NamePrompt?
    var pendingDeletion: PendingDeletion?
    var toast: Toast?
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
    /// Draw the interface with Liquid Glass (macOS 26+).
    var liquidGlass: Bool {
        didSet { UserDefaults.standard.set(liquidGlass, forKey: "appearance.liquidGlass") }
    }
    /// When to tone things down to save energy (see `lowPower`).
    var lowPowerSetting: LowPowerSetting {
        didSet {
            UserDefaults.standard.set(lowPowerSetting.rawValue, forKey: "performance.lowPower")
            player.lowPower = lowPower
        }
    }
    /// The Mac is in Low Power Mode.
    private(set) var systemLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled {
        didSet { player.lowPower = lowPower }
    }
    /// Low Power Mode: discs stand still, the moodboard does without glass
    /// and redraws less, and the player's clock and waveform update less
    /// often, so the app uses less energy.
    var lowPower: Bool {
        switch lowPowerSetting {
        case .automatic: systemLowPower
        case .on: true
        case .off: false
        }
    }
    /// Whether the "+" menu is open (it spans the dock and the page behind it).
    var addMenuOpen = false
    /// The selected collection is showing its moodboard instead of its track list.
    var moodboardOpen = false

    /// Switches the selected collection between its tracks and its moodboard,
    /// zooming out to the board (or back in to the list).
    func setMoodboardOpen(_ open: Bool) {
        guard selectedCollectionID != nil, open != moodboardOpen else { return }
        withAnimation(.spring(duration: 0.6, bounce: 0.12)) { moodboardOpen = open }
    }
    /// The Unsplash picker's target, while it's open.
    var unsplashTarget: ArtworkTarget?
    /// An Unsplash Access Key pasted in by the user (stored on this Mac only).
    var unsplashAccessKey: String {
        didSet { UserDefaults.standard.set(unsplashAccessKey, forKey: "unsplash.accessKey") }
    }

    /// The user's key, else one built into the app (UNSPLASH_ACCESS_KEY).
    var unsplashKey: String {
        let own = unsplashAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        let builtIn = (Bundle.main.object(forInfoDictionaryKey: "UnsplashAccessKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return builtIn.hasPrefix("$(") ? "" : builtIn
    }

    /// The launch screen shows once per launch, not every time the window reopens.
    var launchScreenFinished = false

    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private let location = LibraryLocation()
    @ObservationIgnored private var accessedRoot: URL?
    @ObservationIgnored private var pendingOpenURLs: [URL] = []
    @ObservationIgnored private var powerObserver: (any NSObjectProtocol)?

    init() {
        let defaults = UserDefaults.standard
        recentCollectionIDs = (defaults.stringArray(forKey: "collections.recent") ?? []).compactMap(UUID.init(uuidString:))
        expandedFolders = Set((defaults.stringArray(forKey: "folders.expanded") ?? []).compactMap(UUID.init(uuidString:)))
        authorName = defaults.string(forKey: "comments.author") ?? NSFullUserName()
        unsplashAccessKey = defaults.string(forKey: "unsplash.accessKey") ?? ""
        liquidGlass = defaults.object(forKey: "appearance.liquidGlass") as? Bool ?? true
        lowPowerSetting = defaults.string(forKey: "performance.lowPower").flatMap(LowPowerSetting.init(rawValue:)) ?? .automatic
        player.lowPower = lowPower
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
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

    /// How deep a page is: Home 0, a top-level folder 1, a collection in it 2…
    func depth(of item: SidebarItem?) -> Int {
        guard let store else { return 0 }
        switch item ?? .home {
        case .home, .allTracks, .search, .archive:
            return 0
        case .folder(let id):
            return store.folderPath(to: id).count
        case .collection(let id):
            return (store.folder(ofCollection: id).map { store.folderPath(to: $0).count } ?? 0) + 1
        }
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
    func orderedCollections(in folderID: UUID?, includingArchived: Bool = false) -> [TrackCollection] {
        sortedByRecency(store?.collections(inFolder: folderID, includingArchived: includingArchived) ?? [])
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

    func confirmDeletion(_ deletion: PendingDeletion) {
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
            Task {
                await store.deleteCollection(id)
                player.libraryDidChange()
            }
        case .folder(let id):
            if selectedFolderID == id {
                selection = store.parentFolder(of: id).map(SidebarItem.folder) ?? .home
            }
            store.deleteFolder(id)
        }
    }

    // MARK: - Archive

    /// Hides something from the library without deleting it. If it's the page
    /// being viewed, goes up a level. Offers Undo.
    func archive(_ item: LibraryItemRef) {
        // Already archived (e.g. dragged around the Archive page): nothing to undo.
        guard let store, !isArchived(item) else { return }
        let name = title(of: item)
        switch item {
        case .track(let id):
            store.setArchived(true, track: id)
        case .collection(let id):
            if selectedCollectionID == id {
                selection = store.folder(ofCollection: id).map(SidebarItem.folder) ?? .home
            }
            store.setArchived(true, collection: id)
        case .folder(let id):
            if let current = selectedFolderID ?? selectedCollectionID.flatMap({ store.folder(ofCollection: $0) }),
               store.isFolder(current, within: id) {
                selection = store.parentFolder(of: id).map(SidebarItem.folder) ?? .home
            }
            store.setArchived(true, folder: id)
        }
        showToast(Toast(message: "Archived “\(name)”", systemImage: "archivebox", actionTitle: "Undo") { [weak self] in
            self?.restore(item, announce: false)
        })
    }

    /// Puts an archived item back exactly where it was.
    func restore(_ item: LibraryItemRef, announce: Bool = true) {
        guard let store else { return }
        switch item {
        case .track(let id): store.setArchived(false, track: id)
        case .collection(let id): store.setArchived(false, collection: id)
        case .folder(let id): store.setArchived(false, folder: id)
        }
        if announce {
            showToast(Toast(message: "Restored “\(title(of: item))”", systemImage: "arrow.uturn.backward"))
        }
    }

    /// Whether the item itself (not just something it's in) is archived.
    func isArchived(_ item: LibraryItemRef) -> Bool {
        guard let store else { return false }
        switch item {
        case .track(let id): return store.tracks[id]?.archivedAt != nil
        case .collection(let id): return store.collections[id]?.archivedAt != nil
        case .folder(let id): return store.folders[id]?.archivedAt != nil
        }
    }

    /// The archived thing that hides a page: the collection or folder itself,
    /// or the archived folder it's inside.
    func archivedRoot(of item: SidebarItem?) -> LibraryItemRef? {
        guard let store else { return nil }
        let folderChain: (UUID?) -> LibraryItemRef? = { folder in
            guard let folder else { return nil }
            return store.folderPath(to: folder).first { $0.archivedAt != nil }.map { .folder($0.id) }
        }
        switch item {
        case .collection(let id):
            if store.collections[id]?.archivedAt != nil { return .collection(id) }
            return folderChain(store.folder(ofCollection: id))
        case .folder(let id):
            return folderChain(id)
        default:
            return nil
        }
    }

    func title(of item: LibraryItemRef) -> String {
        switch item {
        case .track(let id): store?.tracks[id]?.title ?? "track"
        case .collection(let id): store?.collections[id]?.title ?? "collection"
        case .folder(let id): store?.folders[id]?.title ?? "folder"
        }
    }

    /// Collections you can add tracks to: everything not archived.
    var activeCollections: [TrackCollection] {
        orderedCollections.filter { !(store?.isArchived(collection: $0.id) ?? false) }
    }

    func showToast(_ toast: Toast) {
        withAnimation(.spring(duration: 0.35)) { self.toast = toast }
        let id = toast.id
        Task {
            try? await Task.sleep(for: .seconds(5))
            if self.toast?.id == id {
                withAnimation(.easeOut(duration: 0.3)) { self.toast = nil }
            }
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

    /// Moves collections and folders into a folder (top level when nil).
    /// Tracks live in collections, so dragged tracks are ignored here.
    func move(_ items: [LibraryItemRef], toFolder folderID: UUID?) {
        guard let store else { return }
        for item in items {
            switch item {
            case .track: continue
            case .collection(let id): store.moveCollection(id, toFolder: folderID)
            case .folder(let id):
                if id != folderID { store.moveFolder(id, into: folderID) }
            }
        }
    }

    /// Handles a drop onto a folder (or the top level when nil): moves
    /// dragged collections and folders in; dropped Finder items become
    /// collections there. Load the payload without expanding folders.
    func handleDrop(_ payload: DropPayload, intoFolder folderID: UUID?) async {
        move(payload.items, toFolder: folderID)
        if !payload.fileURLs.isEmpty {
            await createCollections(from: payload.fileURLs, in: folderID)
        }
    }

    // MARK: - Importing

    /// Asks for audio files (or folders of them) and adds them to a collection.
    func importAudio(into collectionID: UUID) {
        guard let urls = pickAudioFiles(title: "Add Tracks") else { return }
        Task { await importFiles(urls, into: collectionID) }
    }

    /// Asks for audio files or folders and makes collections of them in
    /// `folder` (the current folder by default). Tracks always live in a collection.
    func newCollectionFromFiles(in folder: UUID?? = .none) {
        let panel = audioPanel(title: "New Collection from Files")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let folder = folder ?? currentFolderID
        let urls = panel.urls
        Task { await createCollections(from: urls, in: folder) }
    }

    /// Turns Finder items into collections: each folder becomes a collection
    /// named after it, and loose audio files become one more. Opens the
    /// collection when there's just one.
    func createCollections(from urls: [URL], in folder: UUID?) async {
        guard let store else { return }
        var batches: [(title: String, files: [URL])] = []
        var loose: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let files = DropPayload.expandFolders([url])
                if !files.isEmpty { batches.append((url.lastPathComponent, files)) }
            } else if AudioAnalyzer.isAudioFile(url) {
                loose.append(url)
            }
        }
        if !loose.isEmpty {
            batches.append((Self.collectionName(forFiles: loose), loose))
        }
        let created = batches.map { (store.createCollection(title: $0.title, in: folder).id, $0.files) }
        if created.count == 1 {
            selection = .collection(created[0].0)
        }
        for (collectionID, files) in created {
            await importFiles(files, into: collectionID)
        }
    }

    /// The files' folder name, unless it's a system or temporary folder
    /// (iCloud Drive's root, a Mail or browser drag) that would make a poor title.
    static func collectionName(forFiles urls: [URL]) -> String {
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL })
        guard parents.count == 1, let parent = parents.first else { return "New Collection" }
        let name = parent.lastPathComponent
        let generic: Set<String> = ["Desktop", "Downloads", "Documents", "tmp", "T", "TemporaryItems", "Caches", "/"]
        let isTemporary = parent.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path)
            || parent.path.contains("/private/var/folders/")
        if name.isEmpty || name.contains("~") || name.hasPrefix(".") || generic.contains(name) || isTemporary {
            return "New Collection"
        }
        return name
    }

    func importFiles(_ urls: [URL], into collectionID: UUID, at index: Int? = nil) async {
        guard let store, !urls.isEmpty else { return }
        await store.importAudio(from: urls, into: collectionID, at: index)
    }

    private func pickAudioFiles(title: String) -> [URL]? {
        let panel = audioPanel(title: title)
        guard panel.runModal() == .OK else { return nil }
        let urls = DropPayload.expandFolders(panel.urls)
        return urls.isEmpty ? nil : urls
    }

    private func audioPanel(title: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio, .folder]
        return panel
    }

    /// Files opened from Finder ("Open With", dropped on the Dock icon).
    func importFromFinder(_ urls: [URL]) {
        guard store != nil else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        Task {
            if let collectionID = selectedCollectionID {
                await importFiles(DropPayload.expandFolders(urls).filter(AudioAnalyzer.isAudioFile), into: collectionID)
            } else {
                await createCollections(from: urls, in: currentFolderID)
            }
        }
    }

    /// Handles a drop of files or tracks onto a collection.
    func handleDrop(_ payload: DropPayload, into collectionID: UUID, before targetTrackID: UUID? = nil) async {
        guard let store else { return }
        if !payload.trackIDs.isEmpty {
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
            let index = targetTrackID.flatMap { store.collections[collectionID]?.trackIDs.firstIndex(of: $0) }
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

    func uploadArtwork(for target: ArtworkTarget) {
        switch target {
        case .collection(let id): chooseArtwork(forCollection: id)
        case .track(let id): chooseArtwork(forTrack: id)
        }
    }

    func removeArtwork(for target: ArtworkTarget) {
        switch target {
        case .collection(let id): store?.removeArtwork(forCollection: id)
        case .track(let id): store?.removeArtwork(forTrack: id)
        }
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

/// When the app tones things down to save energy.
enum LowPowerSetting: String, CaseIterable, Identifiable {
    /// Whenever the Mac is in Low Power Mode.
    case automatic
    case on
    case off

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .on: "On"
        case .off: "Off"
        }
    }
}
