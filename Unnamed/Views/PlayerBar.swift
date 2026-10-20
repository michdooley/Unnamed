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
                    MarqueeText(text: track.title, font: .system(size: 13.5, weight: .medium), color: glass ? .primary : .white)
                        .frame(height: 18)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(glass ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.55)))
                        .lineLimit(1)
                }
                .frame(width: density == .minimal ? 104 : 128, alignment: .leading)

                // The waveform and the clock follow playback on their own, so the
                // bar itself (and the window around it) isn't laid out again on
                // every tick of the clock.
                if density != .minimal {
                    PlayerWaveform(
                        peaks: store.peaks(for: trackID, version: player.playingVersionID),
                        width: density == .full ? 190 : 130,
                        glass: glass,
                        playhead: glass ? tint?.color ?? .accentColor : Color(hex: 0xFFD60A)
                    )
                }

                if density == .full {
                    PlayerClock(color: glass ? Color.secondary : Color.white.opacity(0.6))
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

/// The player's waveform. The bars, the playhead and (with Liquid Glass) a
/// little glass bead magnifying the bars under the playhead are all drawn on
/// a canvas that follows the player by itself; a transparent waveform on top
/// handles hovering, clicking and scratching.
private struct PlayerWaveform: View {
    @Environment(PlayerController.self) private var player
    let peaks: [UInt8]
    let width: CGFloat
    let glass: Bool
    let playhead: Color

    @State private var scrub: Double?

    var body: some View {
        ZStack {
            PlayerWaveformBars(peaks: peaks, scrub: scrub, glass: glass, playhead: playhead)
            WaveformView(
                peaks: peaks,
                progress: 0,
                style: WaveformView.Style(barWidth: 2, gap: 1, played: .clear, unplayed: .clear, playhead: nil,
                                          hover: glass ? .primary.opacity(0.4) : .white.opacity(0.6)),
                showsPlayhead: false,
                duration: player.duration,
                onSeek: { player.seek(toFraction: $0) },
                onScrub: { scrub = $0 },
                scratch: .record(player)
            )
        }
        .frame(width: width, height: 30)
    }
}

private struct PlayerWaveformBars: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.lowPower) private var lowPower
    let peaks: [UInt8]
    let scrub: Double?
    let glass: Bool
    let playhead: Color

    var body: some View {
        let _ = Perf.count("waveform")
        let progress = min(1, max(0, scrub ?? player.progress))
        let style = glass ? WaveformView.Style.playerBarGlass : WaveformView.Style.playerBar
        let lens = glass && !lowPower
        Canvas { context, size in
            let step = style.barWidth + style.gap
            let count = max(1, Int((size.width + style.gap) / step))
            let bars = peaks.resampled(to: count)
            let minHeight = max(1, size.height * 0.06)
            func drawBars(_ context: inout GraphicsContext) {
                for i in 0..<count {
                    let level = peaks.isEmpty ? 0 : CGFloat(bars[i]) / 255
                    let height = max(minHeight, level * size.height)
                    let rect = CGRect(x: CGFloat(i) * step, y: (size.height - height) / 2, width: style.barWidth, height: height)
                    let played = (Double(i) + 0.5) / Double(count) <= progress
                    context.fill(Path(roundedRect: rect, cornerRadius: style.barWidth / 2), with: .color(played ? style.played : style.unplayed))
                }
            }
            let x = min(size.width, max(0, progress * size.width))
            let playheadRect = CGRect(x: min(size.width - 1, max(0, x - 1)), y: -1, width: 2, height: size.height + 2)
            guard lens else {
                var plain = context
                drawBars(&plain)
                context.fill(Path(roundedRect: playheadRect, cornerRadius: 1), with: .color(playhead))
                return
            }
            // A bead over the playhead, magnifying what's under it.
            let r: CGFloat = 12
            let center = CGPoint(x: x, y: size.height / 2)
            let bead = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            var outside = context
            var everything = Path(CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20))
            everything.addPath(bead)
            outside.clip(to: everything, style: FillStyle(eoFill: true))
            drawBars(&outside)
            outside.fill(Path(roundedRect: playheadRect, cornerRadius: 1), with: .color(playhead))
            var inside = context
            inside.clip(to: bead)
            inside.translateBy(x: center.x, y: center.y)
            inside.scaleBy(x: 1.9, y: 1.9)
            inside.translateBy(x: -center.x, y: -center.y)
            drawBars(&inside)
            inside.fill(Path(roundedRect: playheadRect, cornerRadius: 1), with: .color(playhead))
            context.fill(bead, with: .color(.white.opacity(0.06)))
            context.stroke(bead, with: .linearGradient(Gradient(colors: [.white.opacity(0.8), .white.opacity(0.08), .white.opacity(0.4)]),
                                                         startPoint: CGPoint(x: center.x - r, y: center.y - r),
                                                         endPoint: CGPoint(x: center.x + r, y: center.y + r)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: center.x - r + 4.5, y: center.y - r + 4.5, width: 8, height: 3.5)), with: .color(.white.opacity(0.55)))
        }
        .opacity(player.isLoading ? 0.4 : 1)
        .allowsHitTesting(false)
    }
}

/// "0:21 / 1:04", drawn on a canvas so the ticking clock doesn't make the
/// window lay itself out again.
private struct PlayerClock: View {
    @Environment(PlayerController.self) private var player
    let color: Color

    var body: some View {
        let label = "\(Format.clock(player.currentTime)) / \(Format.clock(player.duration))"
        Canvas { context, size in
            context.draw(Text(label).font(.system(size: 12, design: .monospaced)).foregroundStyle(color),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
        }
        .frame(width: player.duration >= 3600 ? 130 : 96, height: 16)
        .accessibilityLabel(label)
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
