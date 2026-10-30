// Luma — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.

import SwiftUI

/// A small presentation-only lag behind the native scroll spring. The active line
/// stays attached to its real scroll anchor; following lines settle in succession.
/// No scroll offsets, playback clocks or layout measurements are written per frame.
nonisolated struct LyricLineCascade: Equatable {
    var revision = 0
    var target = 0
    var travel: CGFloat = 0
    var spring = Spring(mass: 1, stiffness: 170, damping: 28.7, allowOverDamping: true)
    var startedAt = 0.0
    var history: [Impulse] = []
    static let duration = 1.4

    struct Impulse: Equatable {
        var target: Int
        var travel: CGFloat
        var spring: Spring
        var age: Double
    }

    mutating func retarget(to target: Int, travel: CGFloat, spring: Spring, now: Double) {
        let age = max(0, now - startedAt)
        history = history.compactMap { old in
            var retained = old
            retained.age += age
            return retained.age < Self.duration ? retained : nil
        }
        if self.travel > 0, age < Self.duration {
            history.append(Impulse(target: self.target, travel: self.travel, spring: self.spring, age: age))
        }
        history = Array(history.suffix(12))
        revision &+= 1
        self.target = target
        self.travel = travel
        self.spring = spring
        startedAt = now
    }

    static func measuredTravel(previous: Int?, target: Int, heights: [Int: CGFloat], spacing: CGFloat,
                               viewportHeight: CGFloat) -> CGFloat? {
        guard let previous, target == previous + 1,
              let height = heights[previous], height > 0,
              viewportHeight > 0, height + spacing < viewportHeight * 0.75 else { return nil }
        return height + spacing
    }

    func offset(row: Int, elapsed: Double) -> CGFloat {
        let current = Self.offset(row: row, elapsed: elapsed, target: target, travel: travel, spring: spring)
        let prior = history.reduce(CGFloat.zero) { value, impulse in
            value + Self.offset(row: row, elapsed: elapsed + impulse.age,
                target: impulse.target, travel: impulse.travel, spring: impulse.spring)
        }
        return min(LyricScrollConfiguration.maximumLag, current + prior)
    }

    private static func offset(row: Int, elapsed: Double, target: Int, travel: CGFloat, spring: Spring) -> CGFloat {
        let distance = row - target
        guard travel > 0, distance > 0, distance <= 6,
              elapsed > 0, elapsed < Self.duration else { return 0 }
        let delay = min(LyricScrollConfiguration.maximumDelay, Double(distance) * LyricScrollConfiguration.cascadeDelay)
        let leading = spring.value(target: 1.0, time: elapsed)
        let following = spring.value(target: 1.0, time: max(0, elapsed - delay))
        // Fade the subpixel tail to exactly zero before the finite animation ends.
        let tail = min(1, (Self.duration - elapsed) / 0.2)
        return travel * CGFloat(max(0, leading - following) * tail)
    }
}

struct LyricLineCascadeModifier: ViewModifier {
    let motion: LyricLineCascade
    let row: Int
    let enabled: Bool

    func body(content: Content) -> some View {
        let participates = enabled && motion.travel > 0 && row > motion.target - 6 && row <= motion.target + 6
        return content.keyframeAnimator(initialValue: 0.0, trigger: motion.revision) { view, elapsed in
            view.offset(y: participates ? motion.offset(row: row, elapsed: elapsed) : 0)
        } keyframes: { _ in
            MoveKeyframe(0.0)
            LinearKeyframe(LyricLineCascade.duration, duration: participates ? LyricLineCascade.duration : 0)
        }
    }
}

/// Tunable native presentation policy, not undocumented Apple Music constants.
nonisolated enum LyricScrollConfiguration {
    static let cascadeDelay = 0.035
    static let maximumDelay = 0.14
    static let maximumLag: CGFloat = 36
    static let maximumVelocity = 2200.0 // points / second for a settled critical response

    static func spring(intervalMs: Double?, distance: CGFloat?) -> Spring {
        let base = AMLLSpringPolicy.position(seeking: false, intervalMs: intervalMs)
        let omega = sqrt(base.stiffness)
        // Long translated/wrapped blocks must not shoot through a short viewport.
        let limited = distance.map { min(omega, maximumVelocity * exp(1) / max(1, Double(abs($0)))) } ?? omega
        let ratio = max(1, base.damping / (2 * omega))
        return Spring(mass: 1, stiffness: limited * limited, damping: 2 * limited * ratio, allowOverDamping: true)
    }
}
