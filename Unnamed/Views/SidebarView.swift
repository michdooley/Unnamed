import SwiftUI
import UnnamedKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    @State private var libraryHeaderTargeted = false

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Label("Home", systemImage: "house").tag(SidebarItem.home)
            Label("All Tracks", systemImage: "music.note.list").tag(SidebarItem.allTracks)
            Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)

            Section {
                ForEach(libraryRows) { row in
                    switch row.item {
                    case .folder(let id):
                        if let folder = store.folders[id] {
                            SidebarFolderRow(store: store, folder: folder, depth: row.depth)
                                .tag(row.item)
                        }
                    case .collection(let id):
                        if let collection = store.collections[id] {
                            SidebarCollectionRow(store: store, collection: collection)
                                .padding(.leading, CGFloat(row.depth) * 16)
                                .tag(row.item)
                        }
                    default:
                        EmptyView()
                    }
                }
            } header: {
                // Dropping on the header moves things back to the top level.
                Text("Library")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .dropHighlight(libraryHeaderTargeted, cornerRadius: 4)
                    .onDrop(of: DropPayload.acceptedTypes, isTargeted: $libraryHeaderTargeted) { providers in
                        Task { await model.handleDrop(await DropPayload.load(from: providers), intoFolder: nil) }
                        return true
                    }
                    .contextMenu {
                        Button("New Folder…") { model.promptNewFolder(in: .some(nil)) }
                        Button("New Collection…") { model.promptNewCollection(in: .some(nil)) }
                    }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SyncFooter(store: store)
        }
        .onChange(of: model.selection) { _, selection in
            model.revealInSidebar(selection)
        }
    }

    private struct Row: Identifiable {
        var item: SidebarItem
        var depth: Int
        var id: SidebarItem { item }
    }

    /// The folder tree flattened into rows: folders first, then collections,
    /// with expanded folders' contents indented beneath them.
    private var libraryRows: [Row] {
        var rows: [Row] = []
        func visit(_ parent: UUID?, depth: Int) {
            for folder in store.subfolders(of: parent) {
                rows.append(Row(item: .folder(folder.id), depth: depth))
                if model.expandedFolders.contains(folder.id) {
                    visit(folder.id, depth: depth + 1)
                }
            }
            for collection in model.orderedCollections(in: parent) {
                rows.append(Row(item: .collection(collection.id), depth: depth))
            }
        }
        visit(nil, depth: 0)
        return rows
    }
}

private struct SidebarFolderRow: View {
    @Environment(AppModel.self) private var model
    let store: LibraryStore
    let folder: LibraryFolder
    let depth: Int
    @State private var isTargeted = false

    var body: some View {
        let expanded = model.expandedFolders.contains(folder.id)
        let isEmpty = store.subfolders(of: folder.id).isEmpty && store.collections(inFolder: folder.id).isEmpty
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.toggleExpanded(folder.id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12, height: 20)
                    .contentShape(Rectangle())
                    .opacity(isEmpty ? 0.25 : 0.7)
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            Image(systemName: expanded ? "folder" : "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(folder.title)
                .lineLimit(1)
        }
        .padding(.leading, CGFloat(depth) * 16 - 4)
        .contentShape(Rectangle())
        .dropHighlight(isTargeted, cornerRadius: 6)
        .onDrop(of: DropPayload.acceptedTypes, isTargeted: $isTargeted) { providers in
            Task { await model.handleDrop(await DropPayload.load(from: providers), intoFolder: folder.id) }
            return true
        }
        .onDrag { NSItemProvider.forItem(.folder(folder.id), title: folder.title) }
        .contextMenu {
            FolderMenuItems(folderID: folder.id)
        }
    }
}

private struct SidebarCollectionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    let collection: TrackCollection
    @State private var isTargeted = false

    var body: some View {
        let isPlayingHere = player.contextCollectionID == collection.id && player.hasTrack
        HStack(spacing: 8) {
            ArtworkView(url: store.artworkURL(forCollection: collection.id), seed: collection.id, cornerRadius: 4, pixelSize: 64)
                .frame(width: 20, height: 20)
            if isPlayingHere {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
            }
            Text(collection.title)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onDrag { NSItemProvider.forItem(.collection(collection.id), title: collection.title) }
        .dropHighlight(isTargeted, cornerRadius: 6)
        .onDrop(of: DropPayload.acceptedTypes, isTargeted: $isTargeted) { providers in
            Task {
                let payload = await DropPayload.load(from: providers)
                await model.handleDrop(payload, into: collection.id)
            }
            return true
        }
        .contextMenu {
            CollectionMenuItems(collectionID: collection.id)
        }
    }
}

/// Shows where the library lives and whether anything is still importing.
private struct SyncFooter: View {
    let store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.pendingImports.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Importing \(store.pendingImports.count) track\(store.pendingImports.count == 1 ? "" : "s")…")
                }
            }
            Label(store.isInCloud ? "iCloud Drive" : "On this Mac", systemImage: store.isInCloud ? "icloud" : "internaldrive")
                .help(store.root.path)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Actions for a collection, shared by the sidebar, Home cards and the toolbar.
struct CollectionMenuItems: View {
    @Environment(AppModel.self) private var model
    let collectionID: UUID

    var body: some View {
        let player = model.player
        let collection = model.store?.collections[collectionID]
        Button("Play") { player.play(collection: collectionID) }
            .disabled(collection?.trackIDs.isEmpty ?? true)
        Divider()
        Button("Add Tracks…") { model.importAudio(into: collectionID) }
        Button("Add from Library…") { model.pickerCollectionID = collectionID }
        Divider()
        Button("Rename…") { model.promptRename(collectionID: collectionID) }
        FolderPickerMenu(
            title: "Move to Folder",
            current: model.store?.folder(ofCollection: collectionID)
        ) { model.move([.collection(collectionID)], toFolder: $0) }
        Button("New Folder with Collection…") {
            // Created where the collection is now, then the collection moves in.
            model.promptNewFolder(in: .some(model.store?.folder(ofCollection: collectionID)), moving: [.collection(collectionID)])
        }
        Button("Change Cover Art…") { model.chooseArtwork(forCollection: collectionID) }
        if collection?.artworkFileName != nil {
            Button("Remove Cover Art") { model.store?.removeArtwork(forCollection: collectionID) }
        }
        Divider()
        Button("Export Audio…") { model.exportCollection(collectionID) }
            .disabled(collection?.trackIDs.isEmpty ?? true)
        Divider()
        Button("Delete Collection…", role: .destructive) { model.pendingDeletion = .collection(collectionID) }
    }
}

/// Actions for a folder, shared by the sidebar, folder cards and the toolbar.
struct FolderMenuItems: View {
    @Environment(AppModel.self) private var model
    let folderID: UUID

    var body: some View {
        let store = model.store
        Button("Open") { model.selection = .folder(folderID) }
        Divider()
        Button("New Collection in Folder…") { model.promptNewCollection(in: .some(folderID)) }
        Button("New Folder Inside…") { model.promptNewFolder(in: .some(folderID)) }
        Button("Add Tracks…") { model.importAudio(into: nil, folder: folderID) }
        Divider()
        Button("Rename…") { model.promptRename(folderID: folderID) }
        FolderPickerMenu(
            title: "Move to",
            current: store?.parentFolder(of: folderID),
            excluding: folderID
        ) { model.move([.folder(folderID)], toFolder: $0) }
        Divider()
        Button("Delete Folder…", role: .destructive) { model.pendingDeletion = .folder(folderID) }
    }
}

/// A submenu listing every folder (indented by depth), plus the top level.
struct FolderPickerMenu: View {
    @Environment(AppModel.self) private var model
    let title: String
    /// The item's current folder, shown with a checkmark.
    var current: UUID?
    /// A folder to leave out along with everything inside it (can't move a folder into itself).
    var excluding: UUID?
    let choose: (UUID?) -> Void

    var body: some View {
        Menu(title) {
            Toggle("Top Level", isOn: Binding(get: { current == nil }, set: { _ in choose(nil) }))
            Divider()
            ForEach(entries, id: \.folder.id) { entry in
                Toggle(isOn: Binding(get: { current == entry.folder.id }, set: { _ in choose(entry.folder.id) })) {
                    Text(String(repeating: "    ", count: entry.depth) + entry.folder.title)
                }
            }
        }
    }

    private var entries: [(folder: LibraryFolder, depth: Int)] {
        guard let store = model.store else { return [] }
        var result: [(LibraryFolder, Int)] = []
        func visit(_ parent: UUID?, depth: Int) {
            for folder in store.subfolders(of: parent) where folder.id != excluding {
                result.append((folder, depth))
                visit(folder.id, depth: depth + 1)
            }
        }
        visit(nil, depth: 0)
        return result
    }
}
