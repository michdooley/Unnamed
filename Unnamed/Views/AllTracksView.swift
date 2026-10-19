import SwiftUI
import UnnamedKit

/// Every track in the library, newest first.
struct AllTracksView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    @State private var isTargeted = false

    var body: some View {
        let tracks = store.tracksNewestFirst
        let ids = tracks.map(\.id)
        let isCurrent = player.hasTrack && player.contextCollectionID == nil && ids.contains(player.currentTrackID ?? UUID())
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("All Tracks")
                            .font(.system(size: 30, weight: .semibold))
                        Text("\(Format.trackCount(tracks.count)) · \(Format.length(tracks.reduce(0) { $0 + $1.duration }))")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    BigPlayButton(isPlaying: isCurrent && player.isPlaying) {
                        isCurrent ? player.togglePlayPause() : player.play(trackIDs: ids)
                    }
                    .disabled(tracks.isEmpty)
                }

                AddTracksButton(collectionID: nil)
                    .padding(.top, 28)

                LazyVStack(spacing: 2) {
                    ForEach(store.pendingImports.filter { $0.collectionID == nil }) { item in
                        PendingImportRow(title: item.title)
                    }
                    ForEach(tracks) { track in
                        TrackRow(store: store, track: track, queue: ids, showsCollections: true)
                    }
                }
                .padding(.top, 18)

                if tracks.isEmpty {
                    Text("Drop audio files here to add them to your library.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 48)
            .padding(.top, 36)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .dropHighlight(isTargeted, cornerRadius: 0)
        .onDrop(of: DropPayload.acceptedTypes, isTargeted: $isTargeted) { providers in
            Task {
                let payload = await DropPayload.load(from: providers)
                await model.importFiles(payload.fileURLs, into: nil)
            }
            return true
        }
    }
}
