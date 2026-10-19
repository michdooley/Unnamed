import SwiftUI

extension EnvironmentValues {
    /// Whether to draw with Liquid Glass (macOS 26+, and the Settings toggle is on).
    @Entry var liquidGlass = false
}

enum LiquidGlassSupport {
    static var isAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

extension View {
    /// Liquid Glass in `shape` when it's on; otherwise the classic `fill`.
    @ViewBuilder
    func glassOr<S: Shape, F: ShapeStyle>(
        _ enabled: Bool,
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        clear: Bool = false,
        classic fill: F
    ) -> some View {
        if #available(macOS 26, *), enabled {
            self.glassEffect((clear ? Glass.clear : Glass.regular).tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(shape.fill(fill))
        }
    }

    /// Glass that comes and goes with `on` without changing the view's identity
    /// (so a row keeps its state when it starts playing).
    @ViewBuilder
    func glassWhen<S: Shape>(_ on: Bool, enabled: Bool, in shape: S) -> some View {
        if #available(macOS 26, *), enabled {
            self.glassEffect(on ? .regular : .identity, in: shape)
        } else {
            self
        }
    }

    /// Lets glass shapes morph into each other (macOS 26); a no-op otherwise.
    @ViewBuilder
    func glassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID, enabled: Bool) -> some View {
        if #available(macOS 26, *), enabled {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

/// Groups glass shapes so they blend and morph together (macOS 26).
struct GlassGroup<Content: View>: View {
    var enabled: Bool
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *), enabled {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
