import SwiftUI
import UniformTypeIdentifiers
import UnnamedKit

/// A collection's page: big cover art on the left, tracks on the right.
struct CollectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    let collectionID: UUID

    @State private var isTargeted = false

    var body: some View {
        if let collection = store.collections[collectionID] {
            GeometryReader { geo in
                let wide = geo.size.width >= 920
                let coverSize = wide
                    ? min(440, max(260, (geo.size.width - 96 - 56) * 0.42))
                    : min(300, geo.size.width - 96)
                ScrollView {
                    Group {
                        if wide {
                            HStack(alignment: .top, spacing: 64) {
                                CoverArt(store: store, collection: collection, size: coverSize)
                                trackPanel(collection)
                                    .frame(maxWidth: 660)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 32) {
                                CoverArt(store: store, collection: collection, size: coverSize)
                                trackPanel(collection)
                            }
                        }
                    }
                    .padding(.horizontal, 48)
                    .padding(.top, 36)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
                }
            }
            .dropHighlight(isTargeted, cornerRadius: 0)
            .onDrop(of: DropPayload.acceptedTypes, isTargeted: $isTargeted) { providers in
                Task {
                    let payload = await DropPayload.load(from: providers)
                    await model.handleDrop(payload, into: collectionID)
                }
                return true
            }
        }
    }

    private func trackPanel(_ collection: TrackCollection) -> some View {
        let tracks = store.tracks(in: collectionID)
        let pending = store.pendingImports.filter { $0.collectionID == collectionID }
        let isCurrent = player.contextCollectionID == collectionID && player.hasTrack
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(collection.title)
                        .font(.system(size: 30, weight: .semibold))
                        .lineLimit(2)
                        .onTapGesture(count: 2) { model.promptRename(collectionID: collectionID) }
                        .help("Double-click to rename")
                    HStack(spacing: 5) {
                        Image(systemName: store.isInCloud ? "icloud" : "internaldrive")
                            .font(.system(size: 12))
                        Text("\(Format.trackCount(tracks.count)) · \(Format.length(store.totalDuration(of: collectionID)))")
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                BigPlayButton(isPlaying: isCurrent && player.isPlaying) {
                    isCurrent ? player.togglePlayPause() : player.play(collection: collectionID)
                }
                .disabled(tracks.isEmpty)
            }

            AddTracksButton(collectionID: collectionID)
                .padding(.top, 28)

            LazyVStack(spacing: 2) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        store: store,
                        track: track,
                        number: index + 1,
                        queue: collection.trackIDs,
                        collectionID: collectionID
                    )
                }
                ForEach(pending) { item in
                    PendingImportRow(title: item.title)
                }
            }
            .padding(.top, 18)

            if tracks.isEmpty && pending.isEmpty {
                VStack(spacing: 6) {
                    Text("No tracks yet")
                        .font(.system(size: 15, weight: .medium))
                    Text("Drop audio files here, or add tracks you've already uploaded.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        }
    }
}

/// The cover, with a disc that slides out and spins while the collection plays.
private struct CoverArt: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    let collection: TrackCollection
    let size: CGFloat

    @State private var hovering = false
    @State private var isTargeted = false

    var body: some View {
        let isCurrent = player.contextCollectionID == collection.id && player.hasTrack
        let disc = player.currentTrackID.map { model.artwork(forTrack: $0, in: collection.id) }
        ZStack {
            DiscView(
                artworkURL: disc?.url ?? store.artworkURL(forCollection: collection.id),
                seed: disc?.seed ?? collection.id,
                spinning: isCurrent && player.isPlaying,
                speed: 24
            )
            .frame(width: size * 0.94, height: size * 0.94)
            .opacity(isCurrent ? 1 : 0)
            .offset(x: isCurrent ? size * 0.17 : 0)

            ArtworkView(url: store.artworkURL(forCollection: collection.id), seed: collection.id, cornerRadius: 22, pixelSize: 1000)
                .frame(width: size, height: size)
                .overlay(alignment: .bottom) {
                    if hovering {
                        ZStack(alignment: .bottom) {
                            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
                            Text("Change Cover Art")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.bottom, 24)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .allowsHitTesting(false)
                    }
                }
                .dropHighlight(isTargeted, cornerRadius: 22)
                .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
                .offset(x: isCurrent ? -size * 0.05 : 0)
                .onHover { hovering = $0 }
                .onTapGesture { model.chooseArtwork(forCollection: collection.id) }
                .contextMenu {
                    Button("Change Cover Art…") { model.chooseArtwork(forCollection: collection.id) }
                    if collection.artworkFileName != nil {
                        Button("Remove Cover Art") { store.removeArtwork(forCollection: collection.id) }
                    }
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
                    Task {
                        if let source = await DropPayload.loadArtwork(from: providers) {
                            await store.setArtwork(forCollection: collection.id, from: source)
                        }
                    }
                    return true
                }
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.7, bounce: 0.2), value: isCurrent)
    }
}

struct BigPlayButton: View {
    var isPlaying: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color(nsColor: .textBackgroundColor))
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(isEnabled ? 1 : 0.3)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Pause" : "Play")
    }
}

/// The wide "+ Add tracks" button, with a menu for adding tracks already in the library.
struct AddTracksButton: View {
    @Environment(AppModel.self) private var model
    let collectionID: UUID?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.importAudio(into: collectionID)
            } label: {
                Label("Add tracks", systemImage: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let collectionID {
                Divider().frame(height: 24)
                Menu {
                    Button("Add Files…") { model.importAudio(into: collectionID) }
                    Button("Add from Library…") { model.pickerCollectionID = collectionID }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 48, height: 50)
                .help("More ways to add")
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0.05)))
        .onHover { hovering = $0 }
    }
}

struct PendingImportRow: View {
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16)).lineLimit(1)
                Text("Importing…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
        .opacity(0.7)
    }
}
