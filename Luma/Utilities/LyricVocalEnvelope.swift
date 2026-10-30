// Luma — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.

import Foundation

/// Presentation envelopes use the provider's word interval. Glyph fractions only
/// interpolate a visual sweep; they do not claim phoneme-level timing.
nonisolated enum LyricVocalEnvelope {
    static let releaseMilliseconds = 600.0

    static func release(time: Double, end: Double) -> Double {
        guard time.isFinite, end.isFinite else { return 0 }
        let t = max(0, time - end) / releaseMilliseconds
        guard t < 1 else { return 0 }
        // Smoothly settle back to the baseline, with zero velocity at both ends.
        return 1 - t * t * (3 - 2 * t)
    }

    static func glow(time: Double, start: Double, end: Double, fraction: Double) -> Double {
        guard time.isFinite, start.isFinite, end.isFinite, end > start else { return 0 }
        let duration = end - start
        let onset = start + duration * min(1, max(0, fraction))
        let attack = min(1, max(0, (time - onset) / min(100, duration * 0.2)))
        let strength = duration >= 900 ? 0.24 : 0.10
        return strength * attack * attack * (3 - 2 * attack) * release(time: time, end: end)
    }

    static func appearance(_ original: AMLLGlyphStyle, time: Double, start: Double, end: Double,
                           fraction: Double, fontSize: Double, motion: Bool) -> AMLLGlyphStyle {
        guard motion, time >= start else { return AMLLGlyphStyle() }
        let settling = release(time: time, end: end)
        var result = original
        result.lift = min(fontSize * 0.07, max(0, original.lift)) * settling
        result.scale = 1 + min(0.035, max(0, original.scale - 1)) * settling
        result.shiftX = min(0.6, max(-0.6, original.shiftX)) * settling
        result.glow = max(min(0.3, original.glow) * settling,
            glow(time: time, start: start, end: end, fraction: fraction))
        result.glowRadius = fontSize * 0.12
        return result
    }
}
