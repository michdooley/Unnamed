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
                    if model.orderedCollections.isEmpty {
                        EmptyHome()
                    } else {
                        CenteredFlowLayout(spacing: 48, rowSpacing: 44) {
                            ForEach(model.orderedCollections) { collection in
                                CollectionCard(store: store, collection: collection)
                            }
                        }
                        .padding(.horizontal, 48)
                    }
                }
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
        .dropHighlight(isTargeted, cornerRadius: 0)
        .onDrop(of: DropPayload.acceptedTypes, isTargeted: $isTargeted) { providers in
            Task { await importDrop(providers) }
            return true
        }
    }

    /// Dropped folders become collections; loose files go to All Tracks.
    private func importDrop(_ providers: [NSItemProvider]) async {
        let payload = await DropPayload.load(from: providers, expandingFolders: false)
        var loose: [URL] = []
        for url in payload.fileURLs {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let files = DropPayload.expandFolders([url])
                guard !files.isEmpty else { continue }
                let collection = store.createCollection(title: url.lastPathComponent)
                await model.importFiles(files, into: collection.id)
            } else {
                loose.append(url)
            }
        }
        await model.importFiles(loose.filter(AudioAnalyzer.isAudioFile), into: nil)
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
            Text("Create a collection for an album, EP or mixtape — or drop audio files and folders anywhere in this window.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack {
                Button("New Collection") { model.promptNewCollection() }
                    .buttonStyle(.borderedProminent)
                Button("Add Tracks…") { model.importAudio(into: nil) }
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

    var body: some View {
        let isCurrent = player.contextCollectionID == collection.id && player.hasTrack
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(url: store.artworkURL(forCollection: collection.id), seed: collection.id, cornerRadius: size * 0.09, pixelSize: 500)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(hovering ? 0.2 : 0.08), radius: hovering ? 16 : 8, y: hovering ? 8 : 4)
                .dropHighlight(isTargeted, cornerRadius: size * 0.09)
                .overlay(alignment: .bottomTrailing) {
                    if !collection.trackIDs.isEmpty {
                        Button {
                            isCurrent ? player.togglePlayPause() : player.play(collection: collection.id)
                        } label: {
                            Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(.white)
                                .frame(width: 46, height: 46)
                                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(white: 0.12).opacity(0.88)))
                                .contentShape(Rectangle())
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
