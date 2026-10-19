import SwiftUI

/// Single-line text that slowly scrolls back and forth when it doesn't fit.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    /// Points per second.
    var speed: Double = 28
    var pause: Double = 1.8

    @State private var textWidth: CGFloat = 0
    @State private var start = Date.now

    var body: some View {
        GeometryReader { geo in
            let overflow = max(0, textWidth - geo.size.width)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: overflow <= 0)) { context in
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    .offset(x: -offset(at: context.date, overflow: overflow))
                    .frame(maxHeight: .infinity, alignment: .leading)
            }
            .mask(
                LinearGradient(
                    stops: overflow > 0
                        ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                           .init(color: .black, location: 0.94), .init(color: .clear, location: 1)]
                        : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .clipped()
        .onChange(of: text) { start = .now }
    }

    private func offset(at date: Date, overflow: CGFloat) -> CGFloat {
        guard overflow > 0 else { return 0 }
        let travel = Double(overflow) / speed
        let cycle = 2 * (pause + travel)
        let t = date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
        switch t {
        case ..<pause: return 0
        case ..<(pause + travel): return CGFloat((t - pause) * speed)
        case ..<(2 * pause + travel): return overflow
        default: return overflow - CGFloat((t - 2 * pause - travel) * speed)
        }
    }
}
