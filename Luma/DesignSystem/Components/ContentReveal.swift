import SwiftUI

/// Shared, restrained opacity reveal for async content. The caller keeps its
/// existing loading/background view mounted and only marks the loaded branch
/// with `transition(.opacity)`; the animation reads Reduce Motion here, in one
/// place, so screens do not stack their own timings.
enum LumaContentReveal {
    static let animation = Animation.easeOut(duration: 0.18)
}

private struct LumaContentRevealModifier: ViewModifier {
    let isReady: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(reduceMotion ? nil : LumaContentReveal.animation, value: isReady)
    }
}

extension View {
    /// Animates the insertion of a loaded branch. The loaded view itself should
    /// carry `.transition(.opacity)`; this modifier supplies the shared timing
    /// and honors Reduce Motion.
    func lumaContentReveal(isReady: Bool) -> some View {
        modifier(LumaContentRevealModifier(isReady: isReady))
    }
}
