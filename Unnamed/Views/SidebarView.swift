import SwiftUI
import UnnamedKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Label("Home", systemImage: "house").tag(SidebarItem.home)
            Label("All Tracks", systemImage: "music.note.list").tag(SidebarItem.allTracks)
            Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)

            Section("Library") {
                ForEach(model.orderedCollections) { collection in
                    SidebarCollectionRow(store: store, collection: collection)
                        .tag(SidebarItem.collection(collection.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SyncFooter(store: store)
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
