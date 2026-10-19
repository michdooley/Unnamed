import SwiftUI
import UnnamedKit

/// SoundCloud-style bar waveform with a played/unplayed split, a playhead,
/// hover scrubbing and comment markers.
struct WaveformView: View {
    struct Style {
        var barWidth: CGFloat = 2
        var gap: CGFloat = 1
        var played: Color
        var unplayed: Color
        var playhead: Color? = Color(hex: 0xFFD60A)
        var hover: Color = .white.opacity(0.5)

        static let playerBar = Style(barWidth: 2, gap: 1, played: .white, unplayed: .white.opacity(0.32), hover: .white.opacity(0.6))
        static let playerBarGlass = Style(barWidth: 2, gap: 1, played: .primary.opacity(0.9), unplayed: .primary.opacity(0.25), playhead: .accentColor, hover: .primary.opacity(0.4))
        static let detail = Style(barWidth: 2, gap: 1.5, played: .primary.opacity(0.85), unplayed: .secondary.opacity(0.35), hover: .primary.opacity(0.35))
        static let preview = Style(barWidth: 1.5, gap: 1.5, played: .secondary.opacity(0.5), unplayed: .secondary.opacity(0.5), playhead: nil)
    }

    struct Marker: Identifiable {
        var id: UUID
        var fraction: Double
        var label: String
    }

    var peaks: [UInt8]
    var progress: Double
    var style: Style
    /// Shows the playhead (only for the track that's loaded in the player).
    var showsPlayhead = true
    var duration: TimeInterval = 0
    var markers: [Marker] = []
    var onSeek: ((Double) -> Void)?
    var onMarkerTap: ((Marker) -> Void)?
    /// Where a scrub in progress is (nil when there isn't one).
    var onScrub: ((Double?) -> Void)?
    /// When set, dragging scratches: the music follows the pointer, and a
    /// plain click still seeks.
    var scratch: WaveformScratch?

    @State private var hover: Double?
    /// Where a scrub is, while one's in progress. Gesture state resets itself
    /// if the drag is cancelled, so the playhead can't get stuck there.
    @GestureState private var drag: Double?
    @State private var scratching = false

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let shown = drag ?? progress
            Canvas { context, size in
                let step = style.barWidth + style.gap
                let count = max(1, Int((size.width + style.gap) / step))
                let bars = peaks.resampled(to: count)
                let minHeight = max(1, size.height * 0.06)
                for i in 0..<count {
                    let level = peaks.isEmpty ? 0 : CGFloat(bars[i]) / 255
                    let height = max(minHeight, level * size.height)
                    let rect = CGRect(x: CGFloat(i) * step, y: (size.height - height) / 2, width: style.barWidth, height: height)
                    let isPlayed = showsPlayhead && (Double(i) + 0.5) / Double(count) <= shown
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: style.barWidth / 2),
                        with: .color(isPlayed ? style.played : style.unplayed)
                    )
                }
                if let hover, drag == nil, onSeek != nil {
                    let x = hover * size.width
                    context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(style.hover))
                }
                if showsPlayhead, let color = style.playhead {
                    let x = min(size.width - 1, max(0, shown * size.width - 1))
                    context.fill(Path(roundedRect: CGRect(x: x, y: -1, width: 2, height: size.height + 2), cornerRadius: 1), with: .color(color))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hover = min(1, max(0, point.x / width))
                    scratch?.prepare()
                case .ended: hover = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($drag) { value, state, _ in
                        guard onSeek != nil else { return }
                        state = min(1, max(0, value.location.x / width))
                    }
                    .onChanged { value in
                        guard let scratch, onSeek != nil else { return }
                        let fraction = min(1, max(0, value.location.x / width))
                        if scratching {
                            scratch.move(fraction)
                        } else if Self.isDrag(value) {
                            scratching = true
                            scratch.begin(fraction)
                        }
                    }
                    .onEnded { value in
                        if scratch != nil, Self.isDrag(value) {
                            // (Already ended if the gesture state reset first.)
                            if scratching {
                                scratching = false
                                scratch?.end()
                            }
                        } else {
                            onSeek?(min(1, max(0, value.location.x / width)))
                        }
                    },
                including: onSeek == nil ? .subviews : .all
            )
            .onChange(of: drag) { _, position in
                onScrub?(position)
                // A cancelled drag still lets go of the record.
                if position == nil, scratching {
                    scratching = false
                    scratch?.end()
                }
            }
            .overlay(alignment: .topLeading) {
                if duration > 0, onSeek != nil, let position = drag ?? hover {
                    Text(Format.clock(position * duration))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .offset(x: min(width - 34, max(0, position * width - 17)), y: -18)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                ForEach(markers) { marker in
                    Circle()
                        .fill(Color.accentColor)
                        .overlay(Circle().stroke(.background, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .help(marker.label)
                        .offset(x: marker.fraction * width - 4, y: 10)
                        .onTapGesture { onMarkerTap?(marker) }
                }
            }
        }
    }
}

extension WaveformView {
    fileprivate static func isDrag(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.width) > 3 || abs(value.translation.height) > 3
    }
}

/// Scratching along a waveform: positions are fractions of the track.
struct WaveformScratch {
    var prepare: () -> Void
    var begin: (Double) -> Void
    var move: (Double) -> Void
    var end: () -> Void

    static func record(_ player: PlayerController) -> WaveformScratch {
        WaveformScratch(
            prepare: { player.prepareScratch() },
            begin: { player.beginScratch(at: $0 * player.duration) },
            move: { player.scratch(to: $0 * player.duration) },
            end: { player.endScratch() }
        )
    }
}
