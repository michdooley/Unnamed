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

    @State private var hover: Double?
    @State private var drag: Double?

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
                case .active(let point): hover = min(1, max(0, point.x / width))
                case .ended: hover = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard onSeek != nil else { return }
                        drag = min(1, max(0, value.location.x / width))
                    }
                    .onEnded { value in
                        guard let onSeek else { return }
                        onSeek(min(1, max(0, value.location.x / width)))
                        drag = nil
                    },
                including: onSeek == nil ? .subviews : .all
            )
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
