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
    @State private var showsArchived = false
    @State private var artTint: ArtworkTint?

    var body: some View {
        if let collection = store.collections[collectionID] {
            GeometryReader { geo in
                let wide = geo.size.width >= 920
                let coverSize = wide
                    ? min(440, max(260, (geo.size.width - 96 - 56) * 0.42))
                    : min(300, geo.size.width - 96)
                // One layout that switches between side by side and stacked, so
                // the cover keeps its identity (and state) across the breakpoint.
                let layout = wide
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 64))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 32))
                ScrollView {
                    layout {
                        cover(collection, size: coverSize)
                        trackPanel(collection)
                            .frame(maxWidth: wide ? 660 : .infinity)
                    }
                    .padding(.horizontal, 48)
                    .padding(.top, 36)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
                }
            }
            .pageEntrance()
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

    /// The cover, with the photographer credited below it when it's from Unsplash.
    private func cover(_ collection: TrackCollection, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CoverArt(store: store, collection: collection, size: size)
            if let credit = collection.artworkCredit {
                ArtworkCreditLine(credit: credit)
                    .frame(width: size, alignment: .leading)
            }
        }
    }

    private func trackPanel(_ collection: TrackCollection) -> some View {
        let tracks = store.tracks(in: collectionID)
        let pending = store.pendingImports.filter { $0.collectionID == collectionID }
        let isCurrent = player.contextCollectionID == collectionID && player.hasTrack
        let queue = tracks.map(\.id)
        let archived = store.tracks(in: collectionID, includingArchived: true).filter { $0.archivedAt != nil }
        let archivedRoot = model.archivedRoot(of: .collection(collectionID))
        return VStack(alignment: .leading, spacing: 0) {
            if let archivedRoot {
                ArchivedBanner(root: archivedRoot, isSelf: archivedRoot == .collection(collectionID))
                    .padding(.bottom, 20)
            }
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
                BigPlayButton(isPlaying: isCurrent && player.isPlaying, tint: artTint) {
                    isCurrent ? player.togglePlayPause() : player.play(collection: collectionID)
                }
                .disabled(tracks.isEmpty)
                .task(id: store.artworkURL(forCollection: collectionID) ?? URL(filePath: collectionID.uuidString)) {
                    artTint = await ArtworkTint.make(url: store.artworkURL(forCollection: collectionID), seed: collectionID)
                }
            }

            AddTracksButton(collectionID: collectionID)
                .padding(.top, 28)

            LazyVStack(spacing: 2) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        store: store,
                        track: track,
                        number: index + 1,
                        queue: queue,
                        collectionID: collectionID
                    )
                    .cascadeIn(index)
                }
                ForEach(pending) { item in
                    PendingImportRow(title: item.title)
                }
            }
            .padding(.top, 18)

            if !archived.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.25)) { showsArchived.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox")
                        Text("\(showsArchived ? "Hide" : "Show") \(archived.count) archived track\(archived.count == 1 ? "" : "s")")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(showsArchived ? 180 : 0))
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                if showsArchived {
                    LazyVStack(spacing: 2) {
                        ForEach(archived) { track in
                            TrackRow(store: store, track: track, queue: archived.map(\.id), collectionID: collectionID)
                        }
                    }
                    .transition(.opacity)
                }
            }

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
/// A cover without art offers to add some on hover and click; once there is
/// art, changing it lives in the right-click menu (like Rename) so the cover
/// stays clean.
private struct CoverArt: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    let collection: TrackCollection
    let size: CGFloat

    @State private var hovering = false
    @State private var isTargeted = false
    @State private var choosingArt = false
    /// The cover settles into place when the page opens, then (if this
    /// collection is playing) the record slides out of its sleeve.
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        let isCurrent = player.contextCollectionID == collection.id && player.hasTrack && settled
        let disc = player.currentTrackID.map { model.artwork(forTrack: $0, in: collection.id) }
        let offersArt = hovering && collection.artworkFileName == nil
        ZStack {
            DiscView(
                artworkURL: disc?.url ?? store.artworkURL(forCollection: collection.id),
                seed: disc?.seed ?? collection.id,
                spinning: isCurrent && player.isPlaying,
                speed: 24,
                scratch: isCurrent ? .record(player, secondsPerTurn: 6) : nil,
                grabbedByEdge: true
            )
            .frame(width: size * 0.94, height: size * 0.94)
            .allowsHitTesting(isCurrent)
            .opacity(isCurrent ? 1 : 0)
            .offset(x: isCurrent ? size * 0.17 : 0)

            ArtworkView(url: store.artworkURL(forCollection: collection.id), seed: collection.id, cornerRadius: 22, pixelSize: 1000)
                .frame(width: size, height: size)
                .overlay(alignment: .bottom) {
                    if offersArt, glass {
                        Label("Add Cover Art", systemImage: "photo")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .glassOr(true, in: Capsule(), tint: .black.opacity(0.2), clear: true, classic: Color.clear)
                            .padding(.bottom, 20)
                            .allowsHitTesting(false)
                    } else if offersArt {
                        ZStack(alignment: .bottom) {
                            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
                            Text("Add Cover Art")
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
                .onTapGesture {
                    if collection.artworkFileName == nil { choosingArt = true }
                }
                .popover(isPresented: $choosingArt, attachmentAnchor: .point(.bottom), arrowEdge: .bottom) {
                    ArtworkChoices(target: .collection(collection.id), hasArtwork: collection.artworkFileName != nil) {
                        choosingArt = false
                    }
                }
                .contextMenu { CollectionMenuItems(collectionID: collection.id) }
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
        .scaleEffect(settled ? 1 : 0.94)
        .opacity(settled ? 1 : 0)
        .rotation3DEffect(.degrees(settled ? 0 : 14), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .animation(.spring(duration: 0.7, bounce: 0.2), value: isCurrent)
        .onAppear {
            guard !settled else { return }
            if reduceMotion {
                settled = true
            } else {
                withAnimation(.spring(duration: 0.65, bounce: 0.18)) { settled = true }
            }
        }
    }
}

struct BigPlayButton: View {
    var isPlaying: Bool
    /// The colour of the artwork it plays (glass only); plain glass without.
    var tint: ArtworkTint?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        Button(action: action) {
            if glass {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(tint.map { $0.prefersLightContent ? Color.white : Color.black.opacity(0.8) } ?? .primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .glassOr(true, in: RoundedRectangle(cornerRadius: 13, style: .continuous),
                             tint: tint?.color.opacity(isEnabled ? 1 : 0.3), interactive: true, classic: Color.clear)
                    .animation(.easeInOut(duration: 0.4), value: tint)
            } else {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(isEnabled ? 1 : 0.3)))
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Pause" : "Play")
    }
}

/// The wide "+ Add tracks" button, with a menu for adding tracks already in the library.
struct AddTracksButton: View {
    @Environment(AppModel.self) private var model
    let collectionID: UUID
    @State private var hovering = false
    @Environment(\.liquidGlass) private var glass

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
        .glassOr(glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true,
                 classic: Color.primary.opacity(hovering ? 0.08 : 0.05))
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

/// In Liquid Glass mode, a big soft wash of artwork behind the page, so the
/// glass (player, buttons, toolbar) has some colour to bend.
struct AmbientArtwork: View {
    let url: URL?
    let seed: UUID

    var body: some View {
        GeometryReader { geo in
            ArtworkView(url: url, seed: seed, cornerRadius: 0, pixelSize: 160)
                .frame(width: geo.size.width * 1.3, height: geo.size.height * 1.3)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .blur(radius: 110)
                .saturation(1.4)
                .opacity(0.42)
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
