import SwiftUI

/// A record/CD showing the track's artwork. Spins while the track plays.
struct DiscView: View {
    let artworkURL: URL?
    let seed: UUID
    var spinning = false
    /// Degrees per second.
    var speed: Double = 40

    @State private var baseAngle: Double = 0
    @State private var spinStart: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !spinning)) { context in
            let elapsed = spinStart.map { context.date.timeIntervalSince($0) } ?? 0
            disc
                .rotationEffect(.degrees(baseAngle + elapsed * speed))
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { if spinning { spinStart = .now } }
        .onChange(of: spinning) { _, isSpinning in
            if isSpinning {
                spinStart = .now
            } else if let start = spinStart {
                baseAngle += Date.now.timeIntervalSince(start) * speed
                spinStart = nil
            }
        }
    }

    private var disc: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                ArtworkView(url: artworkURL, seed: seed, cornerRadius: size / 2, pixelSize: 400)
                // A faint sheen and grooves so it reads as a disc, not a dot.
                Circle()
                    .fill(AngularGradient(
                        colors: [.white.opacity(0.0), .white.opacity(0.22), .white.opacity(0.0), .white.opacity(0.16), .white.opacity(0.0)],
                        center: .center
                    ))
                ForEach(1..<5) { ring in
                    Circle()
                        .stroke(.white.opacity(0.07), lineWidth: max(0.5, size / 200))
                        .padding(size * (0.08 + CGFloat(ring) * 0.06))
                }
                Circle()
                    .fill(.white.opacity(0.9))
                    .frame(width: size * 0.2, height: size * 0.2)
                Circle()
                    .stroke(.black.opacity(0.12), lineWidth: max(0.5, size / 160))
                    .frame(width: size * 0.2, height: size * 0.2)
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: size * 0.07, height: size * 0.07)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
