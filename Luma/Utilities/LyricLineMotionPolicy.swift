import Foundation

/// Maps a lyric line's real display interval to the emphasis animation duration.
/// A fast line must settle before the next line begins; slow lines keep the existing
/// calm cadence. The floor preserves a readable motion even for one- or two-word cues.
nonisolated enum LyricLineMotionPolicy {
    static let currentCap: TimeInterval = 0.32
    static let inactiveCap: TimeInterval = 0.42
    static let minimum: TimeInterval = 0.10

    static func duration(lineStartMs: Int, nextStartMs: Int?, isCurrent: Bool,
                         reduceMotion: Bool) -> TimeInterval? {
        guard !reduceMotion else { return nil }
        let cap = isCurrent ? currentCap : inactiveCap
        guard let nextStartMs, nextStartMs > lineStartMs else { return cap }
        let span = Double(nextStartMs - lineStartMs) / 1000
        // Finish inside the available interval with a small settling tail. The
        // floor avoids making rapid cues look like an instant cut.
        return min(cap, max(minimum, span * 0.45))
    }
}
