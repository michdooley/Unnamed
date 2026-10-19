import SwiftUI
import UnnamedKit

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore

    @FocusState private var searchFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { ambience }
                .background(Color(nsColor: .textBackgroundColor))
                // Clicking anywhere else closes the glass "+" menu.
                .overlay {
                    if model.addMenuOpen, glass {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.spring(duration: 0.5, bounce: 0.32)) { model.addMenuOpen = false } }
                    }
                }
                .onChange(of: presentsSheet) { _, presents in
                    if presents { model.addMenuOpen = false }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 12) {
                        if let toast = model.toast {
                            ToastView(toast: toast) { model.toast = nil }
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        PlayerDock(store: store)
                    }
                    .padding(.bottom, 18)
                    .padding(.top, 6)
                }
        }
        .navigationTitle("Unnamed")
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Breadcrumb(store: store)
            }
            if let collectionID = model.selectedCollectionID, store.collections[collectionID] != nil {
                ToolbarItem(placement: .primaryAction) {
                    Picker("View", selection: Binding(get: { model.moodboardOpen }, set: { model.setMoodboardOpen($0) })) {
                        Label("Tracks", systemImage: "list.bullet").tag(false)
                        Label("Moodboard", systemImage: "point.3.filled.connected.trianglepath.dotted").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                    .help("Switch between the track list and the moodboard (⇧⌘M)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        CollectionMenuItems(collectionID: collectionID)
                    } label: {
                        Label("Collection", systemImage: "ellipsis.circle")
                    }
                    .help("Collection actions")
                }
            }
            if let folderID = model.selectedFolderID, store.folders[folderID] != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        FolderMenuItems(folderID: folderID)
                    } label: {
                        Label("Folder", systemImage: "ellipsis.circle")
                    }
                    .help("Folder actions")
                }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .searchFocused($searchFieldFocused)
        .onChange(of: model.searchFocused) { _, focus in
            if focus {
                searchFieldFocused = true
                model.searchFocused = false
            }
        }
        .onChange(of: model.searchText) { _, text in
            if !text.isEmpty, model.selection != .search { model.selection = .search }
        }
        .onChange(of: model.selection) { _, selection in
            model.addMenuOpen = false
            if selection == .search { searchFieldFocused = true }
        }
        .onChange(of: player.contextCollectionID) { _, id in
            model.notePlayed(collectionID: id)
        }
        .onChange(of: store.tracks) {
            player.libraryDidChange()
        }
        .sheet(item: $model.detail) { route in
            TrackDetailsSheet(trackID: route.trackID, collectionID: route.collectionID)
                .environment(model)
                .environment(player)
        }
        .sheet(item: $model.unsplashTarget) { target in
            UnsplashPicker(target: target)
                .environment(model)
        }
        .sheet(item: $model.namePrompt) { prompt in
            NamePromptSheet(prompt: prompt)
                .environment(model)
        }
        .sheet(item: Binding(
            get: { model.pickerCollectionID.map(IdentifiedID.init) },
            set: { model.pickerCollectionID = $0?.id }
        )) { item in
            TrackPickerSheet(store: store, collectionID: item.id)
                .environment(model)
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }),
            presenting: model.pendingDeletion
        ) { deletion in
            switch deletion {
            case .track:
                Button("Delete Track", role: .destructive) { model.confirmDeletion(deletion) }
            case .collection:
                Button("Delete Collection", role: .destructive) { model.confirmDeletion(deletion) }
            case .folder:
                Button("Delete Folder", role: .destructive) { model.confirmDeletion(deletion) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            switch deletion {
            case .track:
                Text("The track, its notes and comments move to the Trash, and it's removed from every collection.")
            case .collection(let id):
                let count = store.tracksOnlyIn(id).count
                let shared = (store.collections[id]?.trackIDs.count ?? 0) - count
                Text(count == 0
                     ? (store.collections[id]?.trackIDs.isEmpty ?? true
                        ? "The collection moves to the Trash."
                        : "The collection moves to the Trash. Its tracks are kept, since they're also in other collections.")
                     : "The collection and its \(Format.trackCount(count)) (with every version, note and comment) move to the Trash.\(shared > 0 ? " \(Format.trackCount(shared)) also in other collections will be kept." : "")")
            case .folder(let id):
                Text("Nothing inside is deleted: its contents move to \(store.parentFolder(of: id).flatMap { store.folders[$0]?.title }.map { "“\($0)”" } ?? "the top level").")
            }
        }
        .alert(
            currentIssue?.title ?? "",
            isPresented: Binding(get: { currentIssue != nil }, set: { if !$0 { clearIssue() } }),
            presenting: currentIssue
        ) { _ in
            Button("OK") { clearIssue() }
        } message: { issue in
            Text(issue.message)
        }
    }

    /// The current page, pushed in from the right when going deeper (into a
    /// folder or collection) and from the left when coming back out.
    private var detail: some View {
        ZStack {
            page
                .id(model.selection ?? .home)
                .transition(.asymmetric(insertion: insertion, removal: .opacity))
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.08), value: model.selection)
    }

    private var presentsSheet: Bool {
        model.detail != nil || model.namePrompt != nil || model.unsplashTarget != nil
            || model.pickerCollectionID != nil || model.pendingDeletion != nil
    }

    /// Liquid Glass mode washes the window in the cover of the collection
    /// you're looking at, or of whatever's playing, and crossfades as it changes.
    private var ambience: some View {
        let art: (url: URL?, seed: UUID)? = {
            guard glass else { return nil }
            if case .collection(let id) = model.selection, store.collections[id] != nil {
                return (store.artworkURL(forCollection: id), id)
            }
            return player.currentTrackID.map { model.artwork(forTrack: $0, in: player.contextCollectionID) }
        }()
        let key = art.map { "\($0.seed)\($0.url?.lastPathComponent ?? "")" }
        return ZStack {
            if let art {
                AmbientArtwork(url: art.url, seed: art.seed)
                    .id(key)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.9), value: key)
    }

    private var insertion: AnyTransition {
        switch model.navigationDirection {
        case .forward: .offset(x: 80).combined(with: .opacity)
        case .back: .offset(x: -80).combined(with: .opacity)
        case .lateral: .opacity
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.selection ?? .home {
        case .home:
            HomeView(store: store)
        case .allTracks:
            AllTracksView(store: store)
        case .search:
            SearchView(store: store)
        case .archive:
            ArchiveView(store: store)
        case .collection(let id):
            if store.collections[id] != nil {
                CollectionPage(store: store, collectionID: id)
            } else {
                HomeView(store: store)
            }
        case .folder(let id):
            if store.folders[id] != nil {
                FolderView(store: store, folderID: id)
            } else {
                HomeView(store: store)
            }
        }
    }

    private var deletionTitle: String {
        switch model.pendingDeletion {
        case .track(let id): "Delete “\(store.tracks[id]?.title ?? "track")”?"
        case .collection(let id): "Delete “\(store.collections[id]?.title ?? "collection")”?"
        case .folder(let id): "Delete the folder “\(store.folders[id]?.title ?? "folder")”?"
        case nil: ""
        }
    }

    private var currentIssue: LibraryIssue? {
        if let issue = model.alert ?? store.issue { return issue }
        if let problem = player.problem { return LibraryIssue(title: "Playback problem", message: problem) }
        return nil
    }

    private func clearIssue() {
        if model.alert != nil {
            model.alert = nil
        } else if store.issue != nil {
            store.issue = nil
        } else {
            player.problem = nil
        }
    }
}

/// "Unnamed / 2026 / Snippets" in the toolbar; every step is clickable.
private struct Breadcrumb: View {
    @Environment(AppModel.self) private var model
    let store: LibraryStore

    var body: some View {
        let steps = self.steps
        HStack(spacing: 6) {
            Button("Unnamed") { model.selection = .home }
                .buttonStyle(.plain)
                .foregroundStyle(steps.isEmpty ? .primary : .secondary)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Text("/").foregroundStyle(.tertiary)
                if let destination = step.destination, index < steps.count - 1 {
                    Button(step.title) {
                        if model.selection == destination {
                            model.setMoodboardOpen(false)
                        } else {
                            model.selection = destination
                        }
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(step.title).lineLimit(1)
                }
            }
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 6)
    }

    private var steps: [(title: String, destination: SidebarItem?)] {
        func path(_ folderID: UUID?) -> [(String, SidebarItem?)] {
            guard let folderID else { return [] }
            return store.folderPath(to: folderID).map { ($0.title, .folder($0.id)) }
        }
        switch model.selection ?? .home {
        case .home: return []
        case .allTracks: return [("All Tracks", nil)]
        case .search: return [("Search", nil)]
        case .archive: return [("Archived", nil)]
        case .collection(let id):
            return archivedPrefix(.collection(id)) + path(store.folder(ofCollection: id)) + [(store.collections[id]?.title ?? "", .collection(id))]
                + (model.moodboardOpen ? [("Moodboard", nil)] : [])
        case .folder(let id):
            return archivedPrefix(.folder(id)) + path(id)
        }
    }

    /// Archived pages are reached through Archived, so the path starts there.
    private func archivedPrefix(_ item: SidebarItem) -> [(title: String, destination: SidebarItem?)] {
        model.archivedRoot(of: item) == nil ? [] : [("Archived", .archive)]
    }
}

/// The floating player and the "+" button at the bottom of the window.
struct PlayerDock: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    @Environment(\.liquidGlass) private var glass
    /// The player, the "+" and its options share one glass container, so
    /// they melt into and out of each other.
    @Namespace private var glassSpace
    /// Slow motion, for looking at the melt frame by frame (debug).
    static var animationSpeed = 1.0

    var body: some View {
        // Falls back to a slimmer player so a narrow window never overflows.
        ViewThatFits(in: .horizontal) {
            dock(.full)
            dock(.compact)
            dock(.minimal)
        }
        .padding(.horizontal, 16)
        .animation(.spring(duration: 0.4), value: player.hasTrack)
        // Coming back out of a collection, the "+" oozes out of the player
        // as the player slides over to make room.
        .animation(.spring(duration: 0.6, bounce: 0.28).speed(Self.animationSpeed), value: showsAddButton)
    }

    private func dock(_ density: PlayerBar.Density) -> some View {
        GlassGroup(enabled: glass, spacing: 10) {
            HStack(spacing: 0) {
                if player.hasTrack {
                    PlayerBar(store: store, density: density)
                        .glassID("player", in: glassSpace, enabled: glass)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if #available(macOS 26, *), glass, player.hasTrack {
                    // Always there, tucked into the player's end when it isn't
                    // wanted, so it melts in and out of the bar.
                    GlassAddButton(space: glassSpace, tucked: !showsAddButton)
                        .frame(width: showsAddButton ? Self.gap + 58 : 0, alignment: .trailing)
                        .help("New collection or folder")
                } else if showsAddButton {
                    addButton
                        .padding(.leading, player.hasTrack ? Self.gap : 0)
                }
            }
        }
    }

    private static let gap: CGFloat = 14

    @ViewBuilder
    private var addButton: some View {
        if #available(macOS 26, *), glass {
            GlassAddButton(space: glassSpace)
                .help("New collection or folder")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        } else {
            @Bindable var model = model
            AddButton(isOpen: $model.addMenuOpen)
                .help("New collection or folder")
                .popover(isPresented: $model.addMenuOpen, arrowEdge: .top) {
                    AddMenu { model.addMenuOpen = false }
                }
        }
    }

    private var showsAddButton: Bool {
        switch model.selection ?? .home {
        case .home, .allTracks, .folder: true
        default: false
        }
    }
}

/// What the "+" offers: a collection, a folder, or a collection made from files.
struct AddMenu: View {
    @Environment(AppModel.self) private var model
    var dismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AddOption.allCases) { option in
                PopoverRow(title: option.title, systemImage: option.systemImage) {
                    dismiss()
                    option.perform(model)
                }
            }
        }
        .padding(6)
        .frame(minWidth: 220)
        // Wide enough for the longest label, never truncated.
        .fixedSize()
    }
}

struct PopoverRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A collection's page: its track list, or (zoomed out) its moodboard.
struct CollectionPage: View {
    @Environment(AppModel.self) private var model
    let store: LibraryStore
    let collectionID: UUID

    var body: some View {
        ZStack {
            if model.moodboardOpen {
                MoodboardView(store: store, collectionID: collectionID)
                    .transition(.scale(scale: 1.18).combined(with: .opacity))
            } else {
                CollectionView(store: store, collectionID: collectionID)
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
            }
        }
    }
}
