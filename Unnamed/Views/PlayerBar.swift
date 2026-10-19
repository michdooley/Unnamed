import SwiftUI
import UnnamedKit

/// The floating capsule at the bottom: disc, title, waveform, time and
/// transport. Dark in the classic look; Liquid Glass otherwise, with a little
/// glass lens riding the playhead.
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
    @State private var tint: ArtworkTint?
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        if let trackID = player.currentTrackID, let track = store.tracks[trackID] {
            let artwork = model.artwork(forTrack: trackID, in: player.contextCollectionID)
            HStack(spacing: 14) {
                DiscView(artworkURL: artwork.url, seed: artwork.seed, spinning: player.isPlaying, speed: 30, scratch: .record(player))
                    .frame(width: 42, height: 42)
                    .onTapGesture { model.revealNowPlaying() }
                    .help("Show track details")

                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: track.title, font: .system(size: 13.5, weight: .medium))
                        .frame(height: 18)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(glass ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.55)))
                        .lineLimit(1)
                }
                .frame(width: density == .minimal ? 104 : 128, alignment: .leading)

                if density != .minimal {
                    let width: CGFloat = density == .full ? 190 : 130
                    let peaks = store.peaks(for: trackID, version: player.playingVersionID)
                    Group {
                        if glass {
                            LensedWaveform(
                                peaks: peaks,
                                progress: player.progress,
                                duration: player.duration,
                                width: width,
                                playhead: tint?.color ?? .accentColor,
                                scratch: .record(player)
                            ) {
                                player.seek(toFraction: $0)
                            }
                        } else {
                            WaveformView(
                                peaks: peaks,
                                progress: player.progress,
                                style: .playerBar,
                                duration: player.duration,
                                onSeek: { player.seek(toFraction: $0) },
                                scratch: .record(player)
                            )
                        }
                    }
                    .frame(width: width, height: 30)
                    .opacity(player.isLoading ? 0.4 : 1)
                }

                if density == .full {
                    Text("\(Format.clock(player.currentTime)) / \(Format.clock(player.duration))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(glass ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.6)))
                        .fixedSize()
                }

                HStack(spacing: 2) {
                    if density != .minimal {
                        PlayerButton(systemImage: "backward.fill", help: "Previous") { player.previous() }
                    }
                    ZStack {
                        if player.isLoading {
                            ProgressView().controlSize(.small).tint(glass ? nil : .white)
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
            .modifier(PlayerSurface(glass: glass))
            .task(id: artwork.url ?? URL(filePath: artwork.seed.uuidString)) {
                tint = await ArtworkTint.make(url: artwork.url, seed: artwork.seed)
            }
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

/// Dark capsule (classic) or a Liquid Glass capsule.
private struct PlayerSurface: ViewModifier {
    let glass: Bool

    func body(content: Content) -> some View {
        if glass {
            content
                .foregroundStyle(.primary)
                .glassOr(true, in: Capsule(style: .continuous), classic: Color.clear)
        } else {
            content
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
}

/// The waveform with a little glass bead riding the playhead, magnifying the
/// bars under it. (Drawn by hand: real glass can't sit on the bar's glass.)
private struct LensedWaveform: View {
    let peaks: [UInt8]
    let progress: Double
    let duration: TimeInterval
    let width: CGFloat
    var playhead: Color = .accentColor
    var scratch: WaveformScratch?
    let onSeek: (Double) -> Void

    private let lens: CGFloat = 24
    private let height: CGFloat = 30
    @State private var scrub: Double?

    var body: some View {
        let shown = scrub ?? progress
        let x = min(width, max(0, shown * width))
        var style = WaveformView.Style.playerBarGlass
        style.playhead = playhead
        return ZStack {
            // The waveform, with a hole where the bead is.
            WaveformView(peaks: peaks, progress: progress, style: style, duration: duration, onSeek: onSeek, onScrub: { scrub = $0 }, scratch: scratch)
                .mask {
                    ZStack {
                        // Generous, so the hover time above the bars isn't clipped.
                        Rectangle().padding(-40)
                        Circle()
                            .frame(width: lens, height: lens)
                            .position(x: x, y: height / 2)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
            // The same bars, magnified, inside the bead.
            WaveformView(peaks: peaks, progress: shown, style: style)
                .scaleEffect(1.9, anchor: UnitPoint(x: shown, y: 0.5))
                .mask {
                    Circle()
                        .frame(width: lens, height: lens)
                        .position(x: x, y: height / 2)
                }
                .allowsHitTesting(false)
            bead
                .position(x: x, y: height / 2)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
    }

    private var bead: some View {
        Circle()
            .fill(.white.opacity(0.06))
            .overlay(
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.8), .white.opacity(0.08), .white.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .overlay(alignment: .topLeading) {
                // A specular glint.
                Ellipse()
                    .fill(.white.opacity(0.55))
                    .frame(width: 8, height: 3.5)
                    .rotationEffect(.degrees(-35))
                    .offset(x: 4.5, y: 4.5)
                    .blur(radius: 0.6)
            }
            .frame(width: lens, height: lens)
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
    }
}

private struct PlayerButton: View {
    let systemImage: String
    var size: CGFloat = 15
    var isActive = false
    var help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 32, height: 32)
                .background(Circle().fill((glass ? Color.primary : .white).opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var foreground: Color {
        if isActive { return glass ? .accentColor : Color(hex: 0xFFD60A) }
        return (glass ? Color.primary : .white).opacity(hovering ? 1 : 0.85)
    }
}
