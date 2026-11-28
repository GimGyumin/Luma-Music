import Foundation

/// Decoration owns a monotonic clock; it never reads playback position or PCM samples.
nonisolated struct ArtworkSceneClock: Sendable {
    private(set) var elapsed: TimeInterval = 0
    private(set) var isRunning = false
    private(set) var speed = 1.0
    private var lastTime: TimeInterval?

    mutating func setRunning(_ running: Bool, now: TimeInterval) {
        _ = sample(now: now)
        isRunning = running
    }

    mutating func sample(now: TimeInterval) -> TimeInterval {
        if isRunning, let lastTime { elapsed += max(0, now - lastTime) * speed }
        lastTime = now
        return elapsed
    }

    mutating func setSpeed(_ speed: Double, now: TimeInterval) {
        _ = sample(now: now)
        self.speed = speed.isFinite ? min(4, max(0, speed)) : 1
    }
}
