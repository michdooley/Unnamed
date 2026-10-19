import SwiftUI
import UnnamedKit

/// Searches titles, file names, notes, comments, keys and BPM.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore

    private struct CommentHit: Identifiable {
        var trackID: UUID
        var comment: TrackComment
        // Duplicated tracks carry copies of the same comment files, so the
        // comment ID alone isn't unique across the library.
        var id: String { "\(trackID.uuidString)/\(comment.id.uuidString)" }
    }

    var body: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            ContentUnavailableView(
                "Search Your Library",
                systemImage: "magnifyingglass",
                description: Text("Find tracks by title, file name, notes, comments, key or BPM.")
            )
        } else {
            let folders = store.folders.values
                .filter { matches($0.title, query) }
                .sorted { LibraryStore.titleOrder($0.title, $0.id, $1.title, $1.id) }
            let collections = model.orderedCollections.filter { matches($0.title, query) }
            let tracks = store.tracksNewestFirst.filter { trackMatches($0, query) }
            let comments = commentHits(query)
            if folders.isEmpty && collections.isEmpty && tracks.isEmpty && comments.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        if !folders.isEmpty || !collections.isEmpty {
                            section(folders.isEmpty ? "Collections" : collections.isEmpty ? "Folders" : "Folders & Collections") {
                                ScrollView(.horizontal) {
                                    HStack(alignment: .top, spacing: 28) {
                                        ForEach(folders) { folder in
                                            FolderCard(store: store, folder: folder, size: 140)
                                        }
                                        ForEach(collections) { collection in
                                            CollectionCard(store: store, collection: collection, size: 140)
                                        }
                                    }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 2)
                                }
                                .scrollIndicators(.hidden)
                            }
                        }
                        if !tracks.isEmpty {
                            section("Tracks") {
                                LazyVStack(spacing: 2) {
                                    ForEach(tracks) { track in
                                        TrackRow(store: store, track: track, queue: tracks.map(\.id), showsCollections: true)
                                    }
                                }
                            }
                        }
                        if !comments.isEmpty {
                            section("Comments") {
                                VStack(spacing: 2) {
                                    ForEach(comments) { hit in
                                        CommentHitRow(store: store, trackID: hit.trackID, comment: hit.comment)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 36)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            content()
        }
    }

    private func matches(_ text: String?, _ query: String) -> Bool {
        guard let text else { return false }
        return text.localizedStandardContains(query)
    }

    private func trackMatches(_ track: Track, _ query: String) -> Bool {
        matches(track.title, query)
            || matches(track.originalFileName, query)
            || matches(store.notes[track.id], query)
            || matches(track.musicalKey, query)
            || track.versions.contains { matches($0.name, query) || matches($0.originalFileName, query) }
            || track.bpm.map { matches(String(format: "%g", $0), query) } == true
    }

    private func commentHits(_ query: String) -> [CommentHit] {
        store.comments
            .flatMap { trackID, comments in
                comments.filter { matches($0.text, query) }.map { CommentHit(trackID: trackID, comment: $0) }
            }
            .sorted { $0.comment.createdAt > $1.comment.createdAt }
    }
}

private struct CommentHitRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    let trackID: UUID
    let comment: TrackComment
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TimestampChip(time: comment.timestamp) {
                player.play(trackID: trackID, at: comment.timestamp, in: [trackID], context: nil)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(comment.text)
                    .font(.system(size: 15))
                    .lineLimit(2)
                Text("on \(store.tracks[trackID]?.title ?? "a deleted track")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.showDetails(for: trackID, in: nil, pane: .comments) }
    }
}

/// A small "1:23" button that jumps to a moment in a track.
struct TimestampChip: View {
    let time: TimeInterval
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            Text(Format.clock(time))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .help("Play from \(Format.clock(time))")
    }
}
