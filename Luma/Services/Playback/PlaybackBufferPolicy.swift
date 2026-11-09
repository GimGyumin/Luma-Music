import Foundation

/// One prompt command per new item or explicit seek. Normal underruns belong to
/// AVFoundation's automatic waiting policy, even if the clock briefly advances.
nonisolated struct PromptPlaybackGate {
    private(set) var isArmed = false

    mutating func reset(armed: Bool) {
        isArmed = armed
    }

    mutating func didStartPlaying() { isArmed = false }

    mutating func consume(position: Double) -> Bool {
        guard isArmed, position.isFinite else { return false }
        isArmed = false
        return true
    }
}

/// Forward-buffer targets after startup, not startup thresholds. AVFoundation retains control
/// of when playback is sustainable; local files need no network cushion.
nonisolated enum PlaybackBufferPolicy {
    static func forwardBuffer(isLocal: Bool, isLimited: Bool) -> TimeInterval {
        isLocal ? 0 : (isLimited ? 20 : 10)
    }

    /// A one-time startup cushion for finite progressive streams. Normal underruns still
    /// use AVFoundation's automatic stall recovery and the larger forward-buffer target.
    /// Keep the full 1s cushion on metered/constrained links; on unmetered Wi-Fi 0.35s
    /// removes a noticeable first-audio delay while the later 10s target still protects
    /// playback from ordinary jitter.
    static func startupBuffer(isLimited: Bool) -> TimeInterval { isLimited ? 1 : 0.35 }

    static func canPrepareNext(isLocal: Bool, bufferedAhead: Double, remaining: Double) -> Bool {
        isLocal || (bufferedAhead.isFinite && remaining.isFinite && remaining > 0
            && bufferedAhead >= min(5, max(1, remaining - 0.5)))
    }

    static func canStartPromptly(bufferedAhead: Double, minimum: Double) -> Bool {
        bufferedAhead.isFinite && minimum.isFinite && minimum > 0 && bufferedAhead >= minimum
    }

    /// Only the range containing the playhead cushions playback after a seek.
    static func bufferedAhead(position: Double, ranges: [(start: Double, duration: Double)]) -> Double {
        guard position.isFinite else { return 0 }
        return ranges.reduce(0) { result, range in
            let end = range.start + range.duration
            guard range.start.isFinite, end.isFinite,
                  range.start <= position, position < end else { return result }
            return max(result, end - position)
        }
    }
}

/// Guards a restored seek from being injected into a live/user-started attempt.
/// The source swap is asynchronous, so the transport intent is as important as the
/// visible state: a Play tap can arrive before SwiftUI publishes `.loading`.
nonisolated enum RestorationAdmissionPolicy {
    static func permits(trackMatches: Bool, playbackState: PlaybackState,
                        intent: PlaybackIntent?) -> Bool {
        trackMatches && playbackState == .paused && intent != .play
    }
}

/// Position samples that must not erase a real paused/restored clock.
nonisolated enum PlaybackPositionPolicy {
    /// Engine teardown and stream resets report 0 before a new item is scheduled.
    /// While the transport is paused/loading/recovering that zero is not a user seek;
    /// a real seek or a new track commits its position explicitly elsewhere.
    static func shouldPreserveZeroReset(engineProgress: Double, previousPosition: Double,
                                       playbackState: PlaybackState,
                                       engineIsProducing: Bool) -> Bool {
        engineProgress.isFinite && engineProgress <= 0.01
            && previousPosition > 1
            && !engineIsProducing
            && playbackState != .playing
    }
}

/// A persistent wait emits only one KVO event. Sample the media clock using monotonic time
/// so both initial buffering and a later underrun have the same bounded recovery policy.
nonisolated struct PlaybackStallMonitor {
    private var lastMediaTime: Double?
    private var stalledSince: TimeInterval?

    mutating func observe(
        mediaTime: Double, now: TimeInterval, cannotPlay: Bool, isSeeking: Bool
    ) -> Bool {
        defer { lastMediaTime = mediaTime.isFinite ? mediaTime : nil }
        let advancing = mediaTime.isFinite && lastMediaTime.map { mediaTime - $0 >= 0.05 } == true
        let jumpedBack = mediaTime.isFinite && lastMediaTime.map { mediaTime < $0 - 0.05 } == true
        guard cannotPlay, !isSeeking, !advancing, !jumpedBack else {
            stalledSince = nil
            return false
        }
        if stalledSince == nil { stalledSince = now }
        return now - (stalledSince ?? now) >= 12
    }
}

/// Advancing media time, rather than a single engine callback, admits a next-stream request.
nonisolated struct PlaybackPreparationStability {
    private var previous: Double?
    private var previousSample: TimeInterval?
    private var stableSince: TimeInterval?

    mutating func observe(mediaTime: Double, now: TimeInterval, isPlaying: Bool,
                          requiredDuration: TimeInterval = 2) -> Bool {
        defer { previous = mediaTime; previousSample = now }
        guard isPlaying, mediaTime.isFinite, mediaTime >= 0,
              let previous, let previousSample, now >= previousSample,
              now - previousSample <= 2,
              mediaTime > previous + 0.01 else {
            stableSince = nil
            return false
        }
        if stableSince == nil { stableSince = previousSample }
        return now - (stableSince ?? now) >= requiredDuration
    }
}

/// Automatic work is bounded per account revision, song, and requested quality.
/// Explicit downloads remain independent and can be retried immediately by the user.
nonisolated struct AutomaticMediaRetryPolicy {
    private struct Failure { let attempts: Int; let retryAt: Date }
    private var failures: [String: Failure] = [:]

    func permits(_ key: String, now: Date = Date()) -> Bool {
        failures[key].map { $0.attempts < 3 && now >= $0.retryAt } ?? true
    }

    mutating func succeeded(_ key: String) { failures[key] = nil }

    mutating func failed(_ key: String, error: Error, now: Date = Date()) {
        guard PlaybackFailure.classify(error).kind != .cancelled else { return }
        let attempts = (failures[key]?.attempts ?? 0) + 1
        let delay = max(attempts == 1 ? 60.0 : 300.0, Self.serverDelay(error) ?? 0)
        if failures.count >= 128, failures[key] == nil, let oldest = failures.min(by: { $0.value.retryAt < $1.value.retryAt })?.key {
            failures[oldest] = nil
        }
        failures[key] = Failure(attempts: attempts, retryAt: now.addingTimeInterval(delay))
    }

    private static func serverDelay(_ error: Error, depth: Int = 0) -> TimeInterval? {
        if let http = error as? HTTPTransferFailure { return http.retryAfter }
        if depth < 4, let error = error as? LumaError,
           case .downloadFailed(_, let underlying) = error { return serverDelay(underlying, depth: depth + 1) }
        return nil
    }
}
