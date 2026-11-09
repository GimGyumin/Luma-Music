import Foundation

/// Owns the traces belonging to one playback request. The player is an actor, so this
/// value is only touched from its serial executor — never from an audio render callback.
nonisolated struct PlaybackTelemetry {
    private var request: PerformanceTrace?
    private var prepare: PerformanceTrace?
    private var firstAudio: PerformanceTrace?
    private var session: PerformanceTrace?
    private var seek: PerformanceTrace?
    private var reconnect: PerformanceTrace?
    private var gapless: PerformanceTrace?

    mutating func beginRequest(center: DiagnosticsCenter = .shared) {
        session?.finish(.success)
        cancelPending()
        session = nil
        request = center.begin(.playRequestToAudio)
        prepare = center.begin(.audioPrepare)
        firstAudio = nil
    }

    /// URL resolution and the engine hand-off are done; the engine has not produced
    /// a sample yet, so `luma_first_audio` stays open until confirmation.
    mutating func markEngineStarted(center: DiagnosticsCenter = .shared) {
        prepare?.finish(.success)
        prepare = nil
        guard request != nil, firstAudio == nil else { return }
        firstAudio = center.begin(.firstAudio)
    }

    /// An engine confirmation (not a seek estimate) is the only condition that closes
    /// request-to-audio and first-audio.
    mutating func markConfirmed(center: DiagnosticsCenter = .shared) {
        guard request != nil || firstAudio != nil || session == nil else { return }
        firstAudio?.finish(.success)
        request?.finish(.success)
        firstAudio = nil
        request = nil
        if session == nil {
            session = center.begin(.playbackSession)
        }
    }

    mutating func markFailed() {
        request?.finish(.failure)
        prepare?.finish(.failure)
        firstAudio?.finish(.failure)
        seek?.finish(.failure)
        gapless?.finish(.failure)
        session?.finish(.failure)
        request = nil
        prepare = nil
        firstAudio = nil
        seek = nil
        gapless = nil
        session = nil
    }

    mutating func markStopped() {
        cancelPending()
        session?.finish(.success)
        session = nil
    }

    mutating func cancelPending() {
        request?.finish(.cancelled)
        prepare?.finish(.cancelled)
        firstAudio?.finish(.cancelled)
        seek?.finish(.cancelled)
        gapless?.finish(.cancelled)
        request = nil
        prepare = nil
        firstAudio = nil
        seek = nil
        gapless = nil
    }

    mutating func beginSeek(center: DiagnosticsCenter = .shared) {
        seek?.finish(.cancelled)
        seek = center.begin(.seek)
    }

    mutating func finishSeek(_ result: DiagnosticsResult) {
        seek?.finish(result)
        seek = nil
    }

    mutating func beginGapless(center: DiagnosticsCenter = .shared) {
        gapless?.finish(.cancelled)
        gapless = center.begin(.gaplessTransition)
    }

    mutating func finishGapless(_ result: DiagnosticsResult, failed: Bool = false) {
        if failed { gapless?.increment(.gaplessFailures) }
        gapless?.finish(result)
        gapless = nil
    }

    @discardableResult
    mutating func beginReconnect(center: DiagnosticsCenter = .shared) -> PerformanceTrace? {
        reconnect?.finish(.cancelled)
        let trace = center.begin(.streamReconnect)
        trace.increment(.retries)
        reconnect = trace
        return trace
    }

    mutating func finishReconnect(_ result: DiagnosticsResult) {
        reconnect?.finish(result)
        reconnect = nil
    }

    /// A sustained buffer underrun is a session-level counter, not a new trace.
    mutating func noteUnderrun() {
        session?.increment(.underruns)
    }

    /// Test seam: exposes only whether a live session trace exists.
    var hasActiveSession: Bool { session != nil }
}
