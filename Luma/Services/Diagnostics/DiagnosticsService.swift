import Foundation
import OSLog

/// Closed names and values prevent media, accounts, URLs and free-form errors from
/// entering the reporting API. The same surface is used by local and remote sinks.
nonisolated enum DiagnosticsTraceName: String, CaseIterable, Sendable, Codable {
    case coldStart = "luma_cold_start", warmStart = "luma_warm_start"
    case restoreSession = "luma_restore_session", homeReady = "luma_home_ready"
    case albumOpen = "luma_album_open", albumClose = "luma_album_close"
    case playerOpen = "luma_player_open", playerClose = "luma_player_close"
    case libraryRender = "luma_library_render", artworkDecode = "luma_artwork_decode"
    case playRequestToAudio = "luma_play_request_to_audio", audioPrepare = "luma_audio_prepare"
    case firstAudio = "luma_first_audio", seek = "luma_seek", streamReconnect = "luma_stream_reconnect"
    case cacheRead = "luma_cache_read", cacheWrite = "luma_cache_write", prefetch = "luma_prefetch"
    case cacheMaintenance = "luma_cache_maintenance"
    case gaplessTransition = "luma_gapless_transition", lyricsLoad = "luma_lyrics_load"
    case lyricsParse = "luma_lyrics_parse", lyricsFirstRender = "luma_lyrics_first_render"
    case lyricsSyncReady = "luma_lyrics_sync_ready", waveformPrepare = "luma_waveform_prepare"
    case waveformFirstRender = "luma_waveform_first_render", lyricsScreenEnter = "luma_lyrics_screen_enter"
    case librarySync = "luma_library_sync", spotlightQuery = "luma_spotlight_query"
    case ftsQuery = "luma_fts_query", searchMerge = "luma_search_merge", replaySync = "luma_replay_sync"
    case serverConnect = "luma_server_connect", authentication = "luma_authentication", apiRequest = "luma_api_request"
    /// Aggregate health for one playback request. Fixed name, never a track identifier.
    case playbackSession = "luma_playback_session"
    /// User-initiated local diagnostics validation. Never a song/account/URL name.
    case manualProbe = "luma_manual_diagnostics_probe"
}

nonisolated enum DiagnosticsAttribute: String, Sendable {
    case connectionType = "connection_type", mediaFormat = "media_format", cacheState = "cache_state"
    case playbackMode = "playback_mode", offlineState = "offline_state"
}

nonisolated enum DiagnosticsValue: String, Sendable {
    case unknown, wifi, cellular, wired, other, aac, alac, flac, mp3, opus, pcm
    case hit, miss, partial, native, audioStreaming = "audio_streaming", normal, gapless, crossfade
    case online, offline

    func isValid(for attribute: DiagnosticsAttribute) -> Bool {
        switch attribute {
        case .connectionType: [.unknown, .wifi, .cellular, .wired, .other].contains(self)
        case .mediaFormat: [.unknown, .aac, .alac, .flac, .mp3, .opus, .pcm, .other].contains(self)
        case .cacheState: [.unknown, .hit, .miss, .partial].contains(self)
        case .playbackMode: [.unknown, .native, .audioStreaming, .normal, .gapless, .crossfade].contains(self)
        case .offlineState: [.unknown, .online, .offline].contains(self)
        }
    }
}

nonisolated enum DiagnosticsMetric: String, CaseIterable, Sendable {
    case cacheHits = "cache_hit_count", retries = "retry_count", failedRequests = "failed_request_count"
    case underruns = "buffer_underrun_count", gaplessFailures = "gapless_failure_count"
    case uiStalls = "ui_stall_count", lyricsLate = "lyrics_late_count"
    case probeChecks = "probe_check_count"
}

nonisolated enum DiagnosticsResult: String, Sendable, Equatable {
    case success, cancelled, failure

    /// Classifies without reading or forwarding the error's description. Network hiccups
    /// stay ordinary failures; they are never promoted to Crashlytics crashes.
    static func classify(_ error: any Error) -> DiagnosticsResult {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        return .failure
    }
}
nonisolated enum DiagnosticsIssue: Int, CaseIterable, Sendable {
    case audioRenderer = 1, audioBuffer, audioState, gapless, streamRecovery, artworkDecode
    case database, spotlight, lyricsParse, cache, restore, debugProbe
}

nonisolated struct DiagnosticsMeasurement: Sendable {
    let name: DiagnosticsTraceName
    let durationMilliseconds: Double
    let result: DiagnosticsResult
    let metrics: [DiagnosticsMetric: Int64]
}

nonisolated protocol DiagnosticsBackendSpan: Sendable {
    func finish(_ measurement: DiagnosticsMeasurement)
}
nonisolated protocol DiagnosticsService: AnyObject, Sendable {
    var isEnabled: Bool { get }
    var backendKind: DiagnosticsBackendKind { get }
    func collectionState() -> DiagnosticsCollectionState
    func start(_ name: DiagnosticsTraceName, attributes: [String: String]) -> (any DiagnosticsBackendSpan)?
    func report(_ issue: DiagnosticsIssue)
    func disable()
    /// Optional; the default keeps fakes and the local sink source-compatible.
    func setContext(_ attribute: DiagnosticsAttribute, value: DiagnosticsValue)
}

extension DiagnosticsService {
    nonisolated var backendKind: DiagnosticsBackendKind { .local }
    nonisolated func collectionState() -> DiagnosticsCollectionState { .unavailable }
    nonisolated func setContext(_ attribute: DiagnosticsAttribute, value: DiagnosticsValue) {}
}

nonisolated enum DiagnosticsStartOutcome: String, Sendable, Equatable {
    case started, sampledOut, disabled, busy, unavailable
}

nonisolated struct DiagnosticsStartResult: Sendable {
    let trace: PerformanceTrace?
    let outcome: DiagnosticsStartOutcome
}

/// The last owner closes abandoned work as cancelled. Cancellation and a normal
/// completion may race, but only the first completion reaches the backend.
nonisolated final class PerformanceTrace: @unchecked Sendable {
    static let disabled = PerformanceTrace()
    private let lock = NSLock()
    private let name: DiagnosticsTraceName
    private let started: ContinuousClock.Instant
    private var backend: (any DiagnosticsBackendSpan)?
    private var metrics: [DiagnosticsMetric: Int64] = [:]
    private var completion: (@Sendable (DiagnosticsMeasurement) -> Void)?
    private var finished: Bool

    private init() {
        name = .coldStart; started = .now; finished = true
    }
    init(name: DiagnosticsTraceName, backend: any DiagnosticsBackendSpan,
         completion: @escaping @Sendable (DiagnosticsMeasurement) -> Void) {
        self.name = name; self.backend = backend; self.completion = completion
        started = .now; finished = false
    }
    var isFinished: Bool { lock.withLock { finished } }
    func increment(_ metric: DiagnosticsMetric, by amount: Int64 = 1) {
        guard amount > 0 else { return }
        lock.withLock {
            guard !finished else { return }
            metrics[metric] = min(1_000_000_000, metrics[metric, default: 0] + min(amount, 1_000_000_000))
        }
    }
    func finish(_ result: DiagnosticsResult = .success) {
        let work = lock.withLock { () -> ((any DiagnosticsBackendSpan), DiagnosticsMeasurement, (@Sendable (DiagnosticsMeasurement) -> Void)?)? in
            guard !finished, let backend else { return nil }
            finished = true
            let elapsed = started.duration(to: .now).components
            let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            let measurement = DiagnosticsMeasurement(name: name, durationMilliseconds: milliseconds, result: result, metrics: metrics)
            let work = (backend, measurement, completion)
            self.backend = nil; completion = nil
            return work
        }
        guard let (backend, measurement, completion) = work else { return }
        backend.finish(measurement)
        completion?(measurement)
    }
    deinit { finish(.cancelled) }
}

nonisolated final class NoopDiagnosticsService: DiagnosticsService {
    var isEnabled: Bool { false }
    var backendKind: DiagnosticsBackendKind { .disabled }
    func collectionState() -> DiagnosticsCollectionState { .unavailable }
    func start(_ name: DiagnosticsTraceName, attributes: [String: String]) -> (any DiagnosticsBackendSpan)? { nil }
    func report(_ issue: DiagnosticsIssue) {}
    func disable() {}
}

nonisolated final class DiagnosticsCenter: @unchecked Sendable {
    static let shared = DiagnosticsCenter()
    private final class WeakTrace { weak var trace: PerformanceTrace?; init(_ trace: PerformanceTrace) { self.trace = trace } }
    private let lock = NSLock()
    private let sessionMonitor = DiagnosticsSessionMonitor()
    private var service: any DiagnosticsService = NoopDiagnosticsService()
    private var active: [UUID: WeakTrace] = [:]
    private var samples: [DiagnosticsTraceName: UInt64] = [:]
    private var issueTimes: [DiagnosticsIssue: ContinuousClock.Instant] = [:]
    private var epoch: UInt64 = 0
    private var every: UInt64 = 10
    private var commonAttributes: [String: String] = [:]

    func install(_ service: any DiagnosticsService, sampleEvery: Int = 10, deviceClass: String = "unknown", buildChannel: String = "unknown") {
        let previous = lock.withLock { () -> (any DiagnosticsService, [PerformanceTrace]) in
            let previous = (self.service, active.values.compactMap(\.trace))
            self.service = service; every = UInt64(max(1, sampleEvery)); epoch &+= 1
            active.removeAll(); samples.removeAll(); issueTimes.removeAll()
            let devices = ["phone", "tablet", "mac", "other", "unknown"]
            let channels = ["debug", "release", "test", "unknown"]
            commonAttributes = ["device_class": devices.contains(deviceClass) ? deviceClass : "unknown",
                                "app_build_channel": channels.contains(buildChannel) ? buildChannel : "unknown"]
            return previous
        }
        if previous.0 !== service { previous.0.disable() }
        previous.1.forEach { $0.finish(.cancelled) }
    }

    func begin(_ name: DiagnosticsTraceName, attributes: [DiagnosticsAttribute: DiagnosticsValue] = [:]) -> PerformanceTrace {
        startTrace(name, attributes: attributes).trace ?? .disabled
    }

    /// Same sampling/admission path as `begin`, but returns why a trace was not
    /// created so a user-initiated probe can report the exact local cause.
    func startTrace(_ name: DiagnosticsTraceName,
                    attributes: [DiagnosticsAttribute: DiagnosticsValue] = [:]) -> DiagnosticsStartResult {
        let selection = lock.withLock { () -> (DiagnosticsStartOutcome, (any DiagnosticsService)?, UInt64, [String: String]) in
            guard service.isEnabled else { return (.disabled, nil, 0, [:]) }
            guard active.count < 128 else { return (.busy, nil, 0, [:]) }
            let count = samples[name, default: 0]
            samples[name] = count &+ 1
            guard count % every == 0 else { return (.sampledOut, nil, 0, [:]) }
            var safe = commonAttributes
            // Two common fields and the completion result reserve three of five slots.
            for key in attributes.keys.sorted(by: { $0.rawValue < $1.rawValue }).prefix(2) {
                if let value = attributes[key], value.isValid(for: key) { safe[key.rawValue] = value.rawValue }
            }
            return (.started, service, epoch, safe)
        }
        guard selection.0 == .started, let service = selection.1,
              let backend = service.start(name, attributes: selection.3) else {
            return DiagnosticsStartResult(trace: nil, outcome: selection.0 == .started ? .unavailable : selection.0)
        }
        let version = selection.2
        let id = UUID()
        let trace = PerformanceTrace(name: name, backend: backend) { [weak self] measurement in
            self?.completed(id, measurement)
        }
        let accepted = lock.withLock {
            guard epoch == version, active.count < 128 else { return false }
            active[id] = WeakTrace(trace)
            return true
        }
        guard accepted else {
            trace.finish(.cancelled)
            return DiagnosticsStartResult(trace: nil, outcome: .unavailable)
        }
        sessionMonitor.recordStarted()
        return DiagnosticsStartResult(trace: trace, outcome: .started)
    }

    private func completed(_ id: UUID, _ measurement: DiagnosticsMeasurement) {
        sessionMonitor.recordCompleted(measurement)
        remove(id)
    }
    private func remove(_ id: UUID) { lock.withLock { _ = active.removeValue(forKey: id) } }

    func sessionSnapshot() -> DiagnosticsSessionSnapshot { sessionMonitor.currentSnapshot() }
    func sessionStream() -> AsyncStream<DiagnosticsSessionSnapshot> { sessionMonitor.stream() }

    func collectionSnapshot(consent: Bool,
                            infoPlist: DiagnosticsInfoPlistState = .read()) -> DiagnosticsCollectionSnapshot {
        let service = lock.withLock { self.service }
        return DiagnosticsCollectionSnapshot(
            backend: service.backendKind,
            consent: consent,
            state: service.collectionState(),
            infoPlist: infoPlist
        )
    }
    func report(_ issue: DiagnosticsIssue) {
        let selected = lock.withLock { () -> (any DiagnosticsService)? in
            guard service.isEnabled else { return nil }
            let now = ContinuousClock.now
            if let previous = issueTimes[issue], previous.duration(to: now) < .seconds(600) { return nil }
            issueTimes[issue] = now
            return service
        }
        selected?.report(issue)
    }

    /// Crashlytics custom keys are limited to closed values; free-form text is rejected.
    func updateContext(_ attribute: DiagnosticsAttribute, value: DiagnosticsValue) {
        guard value.isValid(for: attribute) else { return }
        let selected = lock.withLock { service.isEnabled ? service : nil }
        selected?.setContext(attribute, value: value)
    }
}

nonisolated final class LocalDiagnosticsAdapter: DiagnosticsService, @unchecked Sendable {
    private static let log = OSLog(subsystem: "app.luma.diagnostics", category: .pointsOfInterest)
    private let lock = NSLock()
    private var enabled = true
    private var completed: [DiagnosticsMeasurement] = []
    var isEnabled: Bool { lock.withLock { enabled } }
    var backendKind: DiagnosticsBackendKind { .local }
    func collectionState() -> DiagnosticsCollectionState { .unavailable }
    var measurements: [DiagnosticsMeasurement] { lock.withLock { completed } }
    func start(_ name: DiagnosticsTraceName, attributes: [String: String]) -> (any DiagnosticsBackendSpan)? {
        guard isEnabled else { return nil }
        let id = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "Luma operation", signpostID: id, "%{public}@", name.rawValue as NSString)
        return Span(owner: self, id: id)
    }
    private func append(_ measurement: DiagnosticsMeasurement, id: OSSignpostID) {
        os_signpost(.end, log: Self.log, name: "Luma operation", signpostID: id, "%{public}@ %{public}@", measurement.name.rawValue as NSString, measurement.result.rawValue as NSString)
        lock.withLock {
            completed.append(measurement)
            if completed.count > 256 { completed.removeFirst(completed.count - 256) }
        }
    }
    func report(_ issue: DiagnosticsIssue) {
        os_log("Normalized diagnostic code=%d", log: Self.log, type: .error, issue.rawValue)
    }
    func disable() { lock.withLock { enabled = false } }
    private struct Span: DiagnosticsBackendSpan {
        let owner: LocalDiagnosticsAdapter
        let id: OSSignpostID
        func finish(_ measurement: DiagnosticsMeasurement) { owner.append(measurement, id: id) }
    }
}
