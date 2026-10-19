import SwiftUI
import UnnamedKit

/// The floating dark capsule at the bottom: disc, title, waveform, time and transport.
struct PlayerBar: View {
    /// How much fits: the dock tries `.full` first and falls back on narrow windows.
    enum Density {
        case full, compact, minimal
    }

    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    var density: Density = .full
    @State private var showingVolume = false

    var body: some View {
        if let trackID = player.currentTrackID, let track = store.tracks[trackID] {
            let artwork = model.artwork(forTrack: trackID, in: player.contextCollectionID)
            HStack(spacing: 14) {
                DiscView(artworkURL: artwork.url, seed: artwork.seed, spinning: player.isPlaying, speed: 30)
                    .frame(width: 42, height: 42)
                    .onTapGesture { model.revealNowPlaying() }
                    .help("Show track details")

                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: track.title, font: .system(size: 13.5, weight: .medium))
                        .frame(height: 18)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .frame(width: density == .minimal ? 104 : 128, alignment: .leading)

                if density != .minimal {
                    WaveformView(
                        peaks: store.peaks(for: trackID, version: player.playingVersionID),
                        progress: player.progress,
                        style: .playerBar,
                        duration: player.duration,
                        onSeek: { player.seek(toFraction: $0) }
                    )
                    .frame(width: density == .full ? 190 : 130, height: 30)
                    .opacity(player.isLoading ? 0.4 : 1)
                }

                if density == .full {
                    Text("\(Format.clock(player.currentTime)) / \(Format.clock(player.duration))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize()
                }

                HStack(spacing: 2) {
                    if density != .minimal {
                        PlayerButton(systemImage: "backward.fill", help: "Previous") { player.previous() }
                    }
                    ZStack {
                        if player.isLoading {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            PlayerButton(systemImage: player.isPlaying ? "pause.fill" : "play.fill", size: 18, help: player.isPlaying ? "Pause" : "Play") {
                                player.togglePlayPause()
                            }
                        }
                    }
                    .frame(width: 32, height: 32)
                    PlayerButton(systemImage: "forward.fill", help: "Next") { player.next() }
                    if density != .minimal {
                        PlayerButton(systemImage: "shuffle", isActive: player.shuffle, help: player.shuffle ? "Shuffle on" : "Shuffle off") {
                            player.toggleShuffle()
                        }
                        PlayerButton(
                            systemImage: player.repeatMode == .one ? "repeat.1" : "repeat",
                            isActive: player.repeatMode != .off,
                            help: repeatHelp
                        ) {
                            player.cycleRepeatMode()
                        }
                    }
                    if density == .full {
                        PlayerButton(systemImage: volumeIcon, help: "Volume") { showingVolume.toggle() }
                        .popover(isPresented: $showingVolume, arrowEdge: .top) {
                            HStack(spacing: 10) {
                                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                                Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...1)
                                    .frame(width: 150)
                                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                            }
                            .padding(14)
                        }
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .frame(height: 58)
            .foregroundStyle(.white)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(white: 0.1))
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            )
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.08)))
            .environment(\.colorScheme, .dark)
        }
    }

    private var subtitle: String {
        let place = player.contextCollectionID.flatMap { store.collections[$0]?.title } ?? "All Tracks"
        // Make it obvious when an older version is playing.
        if let version = player.playingVersionID, let id = player.currentTrackID, let track = store.tracks[id] {
            return "\(track.versionLabel(of: version)) · \(place)"
        }
        return place
    }

    private var repeatHelp: String {
        switch player.repeatMode {
        case .off: "Repeat off"
        case .all: "Repeat all"
        case .one: "Repeat one"
        }
    }

    private var volumeIcon: String {
        switch player.volume {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

private struct PlayerButton: View {
    let systemImage: String
    var size: CGFloat = 15
    var isActive = false
    var help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isActive ? Color(hex: 0xFFD60A) : .white.opacity(hovering ? 1 : 0.88))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
