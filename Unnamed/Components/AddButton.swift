import SwiftUI

/// The round "+" at the bottom of the window.
///
/// Hovering lifts it and runs an iridescent rim around the edge, like a CD
/// catching the light. While its menu is open it turns into a spinning CD,
/// and the "+" turns into an "×".
struct AddButton: View {
    @Binding var isOpen: Bool
    var size: CGFloat = 58

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(white: 0.1))

                if isOpen {
                    ShaderDiscView(radius: 0.5, speed: 1.4)
                        .clipShape(Circle())
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    IridescentRim(active: hovering)
                        .opacity(hovering ? 1 : 0)
                    // A soft inner glow.
                    Circle()
                        .strokeBorder(.white.opacity(0.16), lineWidth: 7)
                        .blur(radius: 5)
                        .clipShape(Circle())
                        .opacity(hovering ? 1 : 0)
                }

                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isOpen ? Color(white: 0.15) : .white)
                    .rotationEffect(.degrees(isOpen ? 135 : 0))
                    .scaleEffect(isOpen ? 0.62 : 1)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .scaleEffect(hovering && !isOpen ? 1.06 : 1)
            .shadow(color: .black.opacity(hovering ? 0.32 : 0.22), radius: hovering ? 20 : 16, y: 8)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.3, bounce: 0.35), value: hovering)
        .animation(.spring(duration: 0.45, bounce: 0.3), value: isOpen)
    }
}

/// The Liquid Glass "+": a glass bead whose options bubble up out of it as
/// glass capsules and melt back into it when it closes. While open, the
/// bead holds a little spinning CD, like a disc in a glass case.
///
/// It lives in the dock's glass container (`space`), next to the player.
/// `tucked` draws it back into the player bar's end, where the two pieces of
/// glass merge, so it melts in when it goes and oozes out when it comes back.
@available(macOS 26, *)
struct GlassAddButton: View {
    @Environment(AppModel.self) private var model
    let space: Namespace.ID
    var size: CGFloat = 58
    var tucked = false

    /// The bead's size and place when tucked into the bar's rounded end.
    private let tuckedSize: CGFloat = 18
    private let tuckedInset: CGFloat = 12

    @State private var hovering = false

    var body: some View {
        // Takes only the bead's room in the dock; the options float above it.
        Color.clear
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 10) {
                    if model.addMenuOpen {
                        ForEach(AddOption.allCases) { option in
                            Button {
                                withAnimation(Self.morph) { model.addMenuOpen = false }
                                option.perform(model)
                            } label: {
                                Label(option.title, systemImage: option.systemImage)
                                    .font(.system(size: 14, weight: .medium))
                                    .padding(.horizontal, 18)
                                    .frame(height: 40)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .glassEffectID(option, in: space)
                        }
                    }
                    bead
                        .glassEffect(.regular.interactive(), in: .circle)
                        .glassEffectID("bead", in: space)
                        .glassEffectTransition(.matchedGeometry)
                        .padding(.bottom, tucked ? (size - tuckedSize) / 2 : 0)
                        .padding(.trailing, tucked ? tuckedInset : 0)
                }
                .fixedSize()
            }
    }

    static let morph = Animation.spring(duration: 0.5, bounce: 0.32)

    private var bead: some View {
        let isOpen = model.addMenuOpen
        return Button {
            withAnimation(Self.morph) { model.addMenuOpen.toggle() }
        } label: {
            ZStack {
                if isOpen {
                    ShaderDiscView(radius: 0.5, speed: 1.4)
                        .clipShape(Circle())
                        .padding(6)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    IridescentRim(active: hovering)
                        .padding(2)
                        .opacity(hovering ? 1 : 0)
                }
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isOpen ? Color(white: 0.15) : .primary)
                    .rotationEffect(.degrees(isOpen ? 135 : 0))
                    .scaleEffect(isOpen ? 0.62 : tucked ? 0.3 : 1)
                    .opacity(tucked ? 0 : 1)
            }
            .frame(width: tucked ? tuckedSize : size, height: tucked ? tuckedSize : size)
            .contentShape(Circle())
        }
        .allowsHitTesting(!tucked)
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.3, bounce: 0.35), value: hovering)
    }
}

/// What the "+" offers.
enum AddOption: String, CaseIterable, Identifiable, Sendable {
    case collection, folder, fromFiles

    var id: Self { self }

    var title: String {
        switch self {
        case .collection: "New Collection"
        case .folder: "New Folder"
        case .fromFiles: "New Collection from Files…"
        }
    }

    var systemImage: String {
        switch self {
        case .collection: "square.stack"
        case .folder: "folder.badge.plus"
        case .fromFiles: "waveform.badge.plus"
        }
    }

    @MainActor func perform(_ model: AppModel) {
        switch self {
        case .collection: model.promptNewCollection()
        case .folder: model.promptNewFolder()
        case .fromFiles: model.newCollectionFromFiles()
        }
    }
}

/// A slowly turning band of spectral colour around the inside edge.
private struct IridescentRim: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lowPower) private var lowPower

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduceMotion || lowPower)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6 * 360
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            Color(hex: 0x6FFFD2), Color(hex: 0x7AD8FF), Color(hex: 0xB9A4FF),
                            Color(hex: 0xFF9AD5), Color(hex: 0xFFE38A), Color(hex: 0x6FFFD2),
                        ],
                        center: .center,
                        angle: .degrees(turn)
                    ),
                    lineWidth: 1.6
                )
                .opacity(0.9)
        }
    }
}
