import SwiftUI
import UnnamedKit

/// One track in a list. Click to play, drag to reorder or to drop into
/// another collection, Finder, or a DAW.
struct TrackRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    let track: Track
    /// Position in the collection; nil shows artwork instead.
    var number: Int?
    /// What plays (in order) when this row is clicked.
    var queue: [UUID]
    /// The collection this row is shown in, if any.
    var collectionID: UUID?
    var showsCollections = false

    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        let isCurrent = player.currentTrackID == track.id
        HStack(spacing: 14) {
            leading(isCurrent: isCurrent)
                .frame(width: number == nil ? 40 : 28, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 16, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                details
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(Format.clock(track.duration))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)

            Button {
                model.showDetails(for: track.id, in: collectionID)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Details")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 60)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isCurrent ? 0.07 : hovering ? 0.04 : 0))
        )
        .overlay(alignment: .top) {
            if dropTargeted {
                Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            player.playOrToggle(trackID: track.id, in: queue, context: collectionID)
        }
        .contextMenu {
            TrackMenuItems(trackID: track.id, collectionID: collectionID, queue: queue)
        }
        .onDrag {
            NSItemProvider.forTrack(track.id, audioURL: store.audioURL(for: track.id), title: track.title)
        }
        .modifier(RowDropTarget(collectionID: collectionID, beforeTrackID: track.id, isTargeted: $dropTargeted))
    }

    @ViewBuilder
    private func leading(isCurrent: Bool) -> some View {
        if isCurrent {
            Image(systemName: player.isLoading ? "icloud.and.arrow.down" : "waveform")
                .font(.system(size: 15, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying || player.isLoading)
        } else if hovering {
            Image(systemName: "play.fill")
                .font(.system(size: 13))
        } else if let number {
            Text("\(number)")
                .font(.system(size: 15))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            TrackArtworkView(trackID: track.id, collectionID: collectionID, cornerRadius: 6, pixelSize: 96)
        }
    }

    private var details: some View {
        HStack(spacing: 8) {
            Text(Format.date(track.createdAt))
            if track.versions.count > 1, let current = track.currentVersionID {
                Text(track.versionLabel(of: current).components(separatedBy: " · ")[0])
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .help("\(track.versions.count) versions — playing \(track.versionLabel(of: current))")
            }
            if let count = store.comments[track.id]?.count, count > 0 {
                Label("\(count)", systemImage: "bubble.left")
                    .labelStyle(CompactLabelStyle())
                    .help("\(count) comment\(count == 1 ? "" : "s")")
            }
            if store.notes[track.id] != nil {
                Image(systemName: "doc.text")
                    .help("Has notes")
            }
            if showsCollections {
                let names = store.collections(containing: track.id).map(\.title)
                if !names.isEmpty {
                    Text(names.joined(separator: ", "))
                }
            }
            CloudBadge(status: store.cloudStatus[track.id])
        }
    }
}

/// Accepts tracks (reorder / add) and files (import) dropped onto a row.
private struct RowDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let collectionID: UUID?
    let beforeTrackID: UUID
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if let collectionID {
            content.onDrop(of: DropPayload.acceptedTypes, isTargeted: $isTargeted) { providers in
                Task {
                    let payload = await DropPayload.load(from: providers)
                    await model.handleDrop(payload, into: collectionID, before: beforeTrackID)
                }
                return true
            }
        } else {
            content
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

/// Shows when a track's audio isn't simply on this Mac.
struct CloudBadge: View {
    let status: CloudStatus?

    var body: some View {
        switch status {
        case .notDownloaded:
            Image(systemName: "icloud.and.arrow.down")
                .help("In iCloud — downloads when you play it")
        case .downloading:
            Image(systemName: "icloud.and.arrow.down")
                .symbolEffect(.pulse)
                .help("Downloading from iCloud…")
        case .uploading:
            Image(systemName: "icloud.and.arrow.up")
                .help("Uploading to iCloud…")
        case .missing:
            Image(systemName: "exclamationmark.icloud")
                .help("The audio file hasn't arrived from iCloud yet")
        case .local, .downloaded, nil:
            EmptyView()
        }
    }
}

/// Context-menu actions for a track.
struct TrackMenuItems: View {
    @Environment(AppModel.self) private var model
    let trackID: UUID
    var collectionID: UUID?
    var queue: [UUID] = []

    var body: some View {
        let player = model.player
        let store = model.store
        let isCurrent = player.currentTrackID == trackID
        Button(isCurrent && player.isPlaying ? "Pause" : "Play") {
            player.playOrToggle(trackID: trackID, in: queue.isEmpty ? [trackID] : queue, context: collectionID)
        }
        Button("Add to Queue") { player.addToQueue(trackID) }
        Divider()
        Button("Details…") { model.showDetails(for: trackID, in: collectionID) }
        Button("Notes…") { model.showDetails(for: trackID, in: collectionID, pane: .notes) }
        Button("Comments…") { model.showDetails(for: trackID, in: collectionID, pane: .comments) }
        Button("Edit Track…") { model.showDetails(for: trackID, in: collectionID, pane: .edit) }
        Divider()
        Button("Upload New Version…") { model.uploadNewVersion(of: trackID) }
        Button("Version History…") { model.showDetails(for: trackID, in: collectionID, pane: .versions) }
        Divider()
        Menu("Add to Collection") {
            ForEach(model.orderedCollections) { collection in
                Button(collection.title) { store?.addTracks([trackID], to: collection.id) }
                    .disabled(collection.trackIDs.contains(trackID))
            }
            Divider()
            Button("New Collection…") { model.promptNewCollection(with: [trackID]) }
        }
        if let collectionID {
            Menu("Move to") {
                ForEach(model.orderedCollections.filter { $0.id != collectionID }) { collection in
                    Button(collection.title) { store?.moveTracks([trackID], from: collectionID, to: collection.id) }
                }
            }
        }
        FolderPickerMenu(title: "Move to Folder", current: store?.folder(ofTrack: trackID)) {
            model.move([.track(trackID)], toFolder: $0)
        }
        Button("Duplicate") { model.duplicate(trackID: trackID, in: collectionID) }
        Divider()
        Button("Export Audio…") { model.exportAudio(of: trackID) }
        Button("Show in Finder") { model.revealInFinder(trackID: trackID) }
        if store?.isInCloud == true {
            if store?.cloudStatus[trackID] == .notDownloaded {
                Button("Make Available Offline") { store?.download(trackID) }
            } else {
                Button("Remove Download") { store?.removeDownload(trackID) }
            }
        }
        Divider()
        if let collectionID {
            Button("Remove from Collection") { store?.removeTracks([trackID], from: collectionID) }
        }
        Button("Delete Track…", role: .destructive) { model.pendingDeletion = .track(trackID) }
    }
}
