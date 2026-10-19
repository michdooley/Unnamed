import SwiftUI
import UnnamedKit

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore

    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    PlayerDock(store: store)
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
                    Menu {
                        CollectionMenuItems(collectionID: collectionID)
                    } label: {
                        Label("Collection", systemImage: "ellipsis.circle")
                    }
                    .help("Collection actions")
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
                Button("Delete Collection and Its Tracks", role: .destructive) { model.confirmDeletion(deletion, deleteTracks: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            switch deletion {
            case .track:
                Text("The track, its notes and comments move to the Trash, and it's removed from every collection.")
            case .collection:
                Text("Deleting just the collection keeps its tracks in All Tracks. Deleting its tracks too only removes tracks that aren't in another collection.")
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

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .home {
        case .home:
            HomeView(store: store)
        case .allTracks:
            AllTracksView(store: store)
        case .search:
            SearchView(store: store)
        case .collection(let id):
            if store.collections[id] != nil {
                CollectionView(store: store, collectionID: id)
                    .id(id)
            } else {
                HomeView(store: store)
            }
        }
    }

    private var deletionTitle: String {
        switch model.pendingDeletion {
        case .track(let id): "Delete “\(store.tracks[id]?.title ?? "track")”?"
        case .collection(let id): "Delete “\(store.collections[id]?.title ?? "collection")”?"
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

/// "Unnamed / Snippets" in the toolbar.
private struct Breadcrumb: View {
    @Environment(AppModel.self) private var model
    let store: LibraryStore

    var body: some View {
        HStack(spacing: 6) {
            Button("Unnamed") { model.selection = .home }
                .buttonStyle(.plain)
                .foregroundStyle(currentTitle == nil ? .primary : .secondary)
            if let currentTitle {
                Text("/").foregroundStyle(.tertiary)
                Text(currentTitle).lineLimit(1)
            }
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 6)
    }

    private var currentTitle: String? {
        switch model.selection ?? .home {
        case .home: nil
        case .allTracks: "All Tracks"
        case .search: "Search"
        case .collection(let id): store.collections[id]?.title
        }
    }
}

/// The floating player and the "+" button at the bottom of the window.
private struct PlayerDock: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    @State private var showingAddMenu = false

    var body: some View {
        // Falls back to a slimmer player so a narrow window never overflows.
        ViewThatFits(in: .horizontal) {
            dock(.full)
            dock(.compact)
            dock(.minimal)
        }
        .padding(.horizontal, 16)
        .animation(.spring(duration: 0.4), value: player.hasTrack)
    }

    private func dock(_ density: PlayerBar.Density) -> some View {
        HStack(spacing: 14) {
            if player.hasTrack {
                PlayerBar(store: store, density: density)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showsAddButton {
                Button {
                    showingAddMenu = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Color(white: 0.1)))
                        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("New collection or add tracks")
                .popover(isPresented: $showingAddMenu, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        PopoverRow(title: "New Collection", systemImage: "square.stack") {
                            showingAddMenu = false
                            model.promptNewCollection()
                        }
                        PopoverRow(title: "Add Tracks…", systemImage: "waveform.badge.plus") {
                            showingAddMenu = false
                            model.importAudio(into: model.selectedCollectionID)
                        }
                    }
                    .padding(6)
                    .frame(width: 220)
                }
            }
        }
    }

    private var showsAddButton: Bool {
        switch model.selection ?? .home {
        case .home, .allTracks: true
        default: false
        }
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
