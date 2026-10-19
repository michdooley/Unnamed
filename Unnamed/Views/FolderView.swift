import SwiftUI
import UnnamedKit

/// A folder's page: its subfolders and collections.
struct FolderView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    let folderID: UUID

    @State private var isTargeted = false

    var body: some View {
        if let folder = store.folders[folderID] {
            // Inside an archived folder everything is shown, including things
            // archived on their own, so they can still be reached and restored.
            let inArchive = model.archivedRoot(of: .folder(folderID)) != nil
            let subfolders = store.subfolders(of: folderID, includingArchived: inArchive)
            let collections = model.orderedCollections(in: folderID, includingArchived: inArchive)
            let queue = store.trackIDs(inFolder: folderID)
            let isCurrent = player.hasTrack && player.contextCollectionID == nil && queue.contains(player.currentTrackID ?? UUID())
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let root = model.archivedRoot(of: .folder(folderID)) {
                        ArchivedBanner(root: root, isSelf: root == .folder(folderID))
                            .padding(.bottom, 20)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(folder.title)
                                .font(.system(size: 30, weight: .semibold))
                                .lineLimit(2)
                                .onTapGesture(count: 2) { model.promptRename(folderID: folderID) }
                                .help("Double-click to rename")
                            Text(summary(subfolders.count, collections.count, queue.count))
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        BigPlayButton(isPlaying: isCurrent && player.isPlaying) {
                            isCurrent ? player.togglePlayPause() : player.play(trackIDs: queue)
                        }
                        .disabled(queue.isEmpty)
                        .help("Play everything in this folder")
                    }

                    HStack(spacing: 10) {
                        PillButton(title: "New Collection", systemImage: "square.stack") {
                            model.promptNewCollection(in: .some(folderID))
                        }
                        PillButton(title: "New Folder", systemImage: "folder.badge.plus") {
                            model.promptNewFolder(in: .some(folderID))
                        }
                        PillButton(title: "From Files…", systemImage: "waveform.badge.plus") {
                            model.newCollectionFromFiles(in: .some(folderID))
                        }
                    }
                    .padding(.top, 24)

                    if !subfolders.isEmpty || !collections.isEmpty {
                        CenteredFlowLayout(spacing: 32, rowSpacing: 32, centered: false) {
                            ForEach(Array(subfolders.enumerated()), id: \.element.id) { index, subfolder in
                                FolderCard(store: store, folder: subfolder, size: 170)
                                    .overlay(alignment: .topLeading) {
                                        if subfolder.archivedAt != nil { RestoreBadge(item: .folder(subfolder.id)) }
                                    }
                                    .cascadeIn(index)
                            }
                            ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
                                CollectionCard(store: store, collection: collection, size: 170)
                                    .overlay(alignment: .topLeading) {
                                        if collection.archivedAt != nil { RestoreBadge(item: .collection(collection.id)) }
                                    }
                                    .cascadeIn(subfolders.count + index)
                            }
                        }
                        .padding(.top, 32)
                    }

                    if subfolders.isEmpty && collections.isEmpty {
                        VStack(spacing: 6) {
                            Text("This folder is empty")
                                .font(.system(size: 15, weight: .medium))
                            Text("Drag collections or other folders here, or drop audio files from Finder to start a new collection.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 48)
                .padding(.top, 36)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .pageEntrance()
            .dropHighlight(isTargeted, cornerRadius: 0)
            .onDrop(of: DropPayload.acceptedTypes, isTargeted: $isTargeted) { providers in
                Task { await model.handleDrop(await DropPayload.load(from: providers, expandingFolders: false), intoFolder: folderID) }
                return true
            }
        }
    }

    /// "1 folder · 2 collections · 9 tracks" (tracks counted across subfolders too).
    private func summary(_ folders: Int, _ collections: Int, _ tracks: Int) -> String {
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        if collections > 0 { parts.append(collections == 1 ? "1 collection" : "\(collections) collections") }
        if tracks > 0 { parts.append(Format.trackCount(tracks)) }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }
}

/// A folder tile: a 2×2 mosaic of what's inside.
struct FolderCard: View {
    @Environment(AppModel.self) private var model
    let store: LibraryStore
    let folder: LibraryFolder
    var size: CGFloat = 200

    @State private var hovering = false
    @State private var isTargeted = false

    var body: some View {
        let collections = model.orderedCollections(in: folder.id)
        let count = store.contentCount(ofFolder: folder.id)
        VStack(alignment: .leading, spacing: 0) {
            mosaic(collections: Array(collections.prefix(4)), subfolders: count.folders)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.09, style: .continuous).fill(Color.primary.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                )
                .shadow(color: .black.opacity(hovering ? 0.14 : 0.04), radius: hovering ? 14 : 6, y: hovering ? 6 : 3)
                .dropHighlight(isTargeted, cornerRadius: size * 0.09)
                .scaleEffect(hovering ? 1.015 : 1)
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(folder.title)
                    .font(.system(size: size > 180 ? 17 : 15, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.top, 16)
            Text(subtitle(count))
                .font(.system(size: size > 180 ? 14 : 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 3)
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .folder(folder.id) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onDrag { NSItemProvider.forItem(.folder(folder.id), title: folder.title) }
        .onDrop(of: DropPayload.acceptedTypes, isTargeted: $isTargeted) { providers in
            Task { await model.handleDrop(await DropPayload.load(from: providers, expandingFolders: false), intoFolder: folder.id) }
            return true
        }
        .contextMenu { FolderMenuItems(folderID: folder.id) }
    }

    @ViewBuilder
    private func mosaic(collections: [TrackCollection], subfolders: Int) -> some View {
        let tiles: [(url: URL?, seed: UUID)] = collections.map { (store.artworkURL(forCollection: $0.id), $0.id) }
        let inset = size * 0.08
        let gap = size * 0.045
        let tile = (size - inset * 2 - gap) / 2
        if tiles.isEmpty {
            Image(systemName: subfolders > 0 ? "folder.fill" : "folder")
                .font(.system(size: size * 0.32, weight: .light))
                .foregroundStyle(.tertiary)
        } else {
            VStack(spacing: gap) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<2, id: \.self) { column in
                            let index = row * 2 + column
                            if index < tiles.count {
                                ArtworkView(url: tiles[index].url, seed: tiles[index].seed, cornerRadius: size * 0.05, pixelSize: 240)
                                    .frame(width: tile, height: tile)
                            } else {
                                RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                                    .frame(width: tile, height: tile)
                            }
                        }
                    }
                }
            }
        }
    }

    private func subtitle(_ count: (folders: Int, collections: Int)) -> String {
        var parts: [String] = []
        if count.folders > 0 { parts.append(count.folders == 1 ? "1 folder" : "\(count.folders) folders") }
        if count.collections > 0 { parts.append(count.collections == 1 ? "1 collection" : "\(count.collections) collections") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }
}

/// A compact rounded action button ("New Collection", "Add Tracks").
struct PillButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .contentShape(Capsule())
                .glassOr(glass, in: Capsule(), interactive: true, classic: Color.primary.opacity(hovering ? 0.09 : 0.05))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
