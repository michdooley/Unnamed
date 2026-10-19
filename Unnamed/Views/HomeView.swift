import SwiftUI
import UnnamedKit

struct HomeView: View {
    @Environment(AppModel.self) private var model
    let store: LibraryStore
    @State private var isTargeted = false

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                Group {
                    let folders = store.subfolders(of: nil)
                    let collections = model.orderedCollections(in: nil)
                    if folders.isEmpty && collections.isEmpty {
                        EmptyHome()
                    } else {
                        CenteredFlowLayout(spacing: 48, rowSpacing: 44) {
                            ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                                FolderCard(store: store, folder: folder)
                                    .cascadeIn(index)
                            }
                            ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
                                CollectionCard(store: store, collection: collection)
                                    .cascadeIn(folders.count + index)
                            }
                        }
                        .padding(.horizontal, 48)
                    }
                }
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
        .pageEntrance()
        .dropHighlight(isTargeted, cornerRadius: 0)
        .onDrop(of: DropPayload.acceptedTypes, isTargeted: $isTargeted) { providers in
            Task { await importDrop(providers) }
            return true
        }
    }

    /// Items dragged in from elsewhere move to the top level; Finder items
    /// become collections.
    private func importDrop(_ providers: [NSItemProvider]) async {
        await model.handleDrop(await DropPayload.load(from: providers, expandingFolders: false), intoFolder: nil)
    }
}

private struct EmptyHome: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Your ideas go here")
                .font(.system(size: 22, weight: .semibold))
            Text("Create a collection for an album, EP or mixtape, or drop audio files and folders anywhere in this window.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack {
                Button("New Collection") { model.promptNewCollection() }
                    .buttonStyle(.borderedProminent)
                Button("From Files…") { model.newCollectionFromFiles(in: .some(nil)) }
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
    }
}

struct CollectionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    let collection: TrackCollection
    var size: CGFloat = 200

    @State private var hovering = false
    @State private var isTargeted = false
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        let isCurrent = player.contextCollectionID == collection.id && player.hasTrack
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(url: store.artworkURL(forCollection: collection.id), seed: collection.id, cornerRadius: size * 0.09, pixelSize: 500)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(hovering ? 0.2 : 0.08), radius: hovering ? 16 : 8, y: hovering ? 8 : 4)
                .dropHighlight(isTargeted, cornerRadius: size * 0.09)
                .overlay(alignment: .bottomTrailing) {
                    if !store.tracks(in: collection.id).isEmpty {
                        Button {
                            isCurrent ? player.togglePlayPause() : player.play(collection: collection.id)
                        } label: {
                            Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(.white)
                                .frame(width: 46, height: 46)
                                .contentShape(Rectangle())
                                .glassOr(glass, in: RoundedRectangle(cornerRadius: 13, style: .continuous), tint: .black.opacity(0.25),
                                         interactive: true, clear: true, classic: Color(white: 0.12).opacity(0.88))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 8, y: 8)
                        .help(isCurrent && player.isPlaying ? "Pause" : "Play")
                    }
                }
                .scaleEffect(hovering ? 1.015 : 1)
            Text(collection.title)
                .font(.system(size: 17, weight: .medium))
                .lineLimit(1)
                .padding(.top, 16)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 3)
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .collection(collection.id) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onDrag { NSItemProvider.forItem(.collection(collection.id), title: collection.title) }
        .contextMenu { CollectionMenuItems(collectionID: collection.id) }
        .onDrop(of: DropPayload.acceptedTypes, isTargeted: $isTargeted) { providers in
            Task {
                let payload = await DropPayload.load(from: providers)
                await model.handleDrop(payload, into: collection.id)
            }
            return true
        }
    }

    private var subtitle: String {
        let count = collection.trackIDs.count
        guard count > 0 else { return "Empty" }
        return "\(Format.trackCount(count)) · \(Format.length(store.totalDuration(of: collection.id)))"
    }
}
