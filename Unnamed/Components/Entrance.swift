import SwiftUI

extension EnvironmentValues {
    /// When the current page appeared. Items that appear soon after cascade
    /// in; items that appear later (scrolled into view) just show.
    @Entry var pageAppearedAt: Date?
}

extension View {
    /// Marks the start of a page's entrance.
    func pageEntrance() -> some View {
        modifier(PageEntrance())
    }

    /// Fades and lifts an item into place, a beat after the one before it.
    func cascadeIn(_ index: Int) -> some View {
        modifier(CascadeIn(index: index))
    }
}

private struct PageEntrance: ViewModifier {
    @State private var appearedAt = Date()

    func body(content: Content) -> some View {
        content.environment(\.pageAppearedAt, appearedAt)
    }
}

private struct CascadeIn: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.pageAppearedAt) private var pageAppearedAt
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                guard !shown else { return }
                let entering = pageAppearedAt.map { Date().timeIntervalSince($0) < 0.8 } ?? false
                guard entering, !reduceMotion else {
                    shown = true
                    return
                }
                let delay = 0.08 + Double(min(index, 12)) * 0.035
                withAnimation(.spring(duration: 0.5, bounce: 0.15).delay(delay)) { shown = true }
            }
    }
}
