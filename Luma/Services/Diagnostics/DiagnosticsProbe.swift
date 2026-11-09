import Foundation

nonisolated enum DiagnosticsProbeOutcome: String, Codable, Sendable, Equatable {
    case recorded
    case consentRequired
    case diagnosticsDisabled
    case firebaseNotConfigured
    case collectionInactive
    case collectionUnavailable
    case sampledOut
    case traceUnavailable
    case localChecksFailed
    case cancelled

    var isSuccess: Bool { self == .recorded }
}

nonisolated enum DiagnosticsServerReceipt: String, Codable, Sendable, Equatable {
    /// The public SDK has no per-trace upload confirmation callback.
    case unavailable
    /// Local-only instrumentation has no Firebase upload path.
    case notApplicable
}

nonisolated struct DiagnosticsProbeCheckResult: Sendable, Equatable {
    let checksPassed: Int
    let failed: Bool
}

/// Local invariant checks. This is real work, but very small: it validates the
/// closed trace/attribute/metric vocabularies rather than sleeping artificially.
nonisolated enum DiagnosticsProbeChecks {
    static func run() -> DiagnosticsProbeCheckResult {
        var passed = 0
        for name in DiagnosticsTraceName.allCases {
            guard name.rawValue.hasPrefix("luma_"), name.rawValue.count <= 100,
                  !name.rawValue.contains(" ") else {
                return DiagnosticsProbeCheckResult(checksPassed: passed, failed: true)
            }
            passed += 1
        }
        let samples: [(DiagnosticsAttribute, DiagnosticsValue)] = [
            (.connectionType, .wifi), (.mediaFormat, .flac), (.cacheState, .hit),
            (.playbackMode, .gapless), (.offlineState, .online)
        ]
        for (attribute, value) in samples {
            guard attribute.rawValue.count <= 40, value.isValid(for: attribute) else {
                return DiagnosticsProbeCheckResult(checksPassed: passed, failed: true)
            }
            passed += 1
        }
        for metric in DiagnosticsMetric.allCases {
            guard metric.rawValue.count <= 100 else {
                return DiagnosticsProbeCheckResult(checksPassed: passed, failed: true)
            }
            passed += 1
        }
        for issue in DiagnosticsIssue.allCases {
            guard issue.rawValue > 0 else {
                return DiagnosticsProbeCheckResult(checksPassed: passed, failed: true)
            }
            passed += 1
        }
        return DiagnosticsProbeCheckResult(checksPassed: passed, failed: false)
    }
}

nonisolated struct DiagnosticsProbeResult: Codable, Sendable, Equatable {
    let executedAt: Date
    let traceName: DiagnosticsTraceName
    let traceStarted: Bool
    let traceFinished: Bool
    let durationMilliseconds: Double
    let backend: DiagnosticsBackendKind
    let collectionActive: Bool
    let checksPassed: Int
    let localError: Bool
    let outcome: DiagnosticsProbeOutcome
    let serverReceipt: DiagnosticsServerReceipt
}

/// Owns the user-initiated local probe. It never changes consent or Firebase
/// settings and never claims that a trace reached the server.
@MainActor @Observable
final class DiagnosticsProbeController {
    static let shared = DiagnosticsProbeController()
    private static let lastResultKey = "luma.diagnostics.lastProbe"

    private let center: DiagnosticsCenter
    private let defaults: UserDefaults
    private let checks: @Sendable () async -> DiagnosticsProbeCheckResult
    private let now: @Sendable () -> Date
    private(set) var lastResult: DiagnosticsProbeResult?
    private(set) var isProbing = false
    private var probeTask: Task<Void, Never>?

    init(
        center: DiagnosticsCenter = .shared,
        defaults: UserDefaults = .standard,
        checks: @escaping @Sendable () async -> DiagnosticsProbeCheckResult = { DiagnosticsProbeChecks.run() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.center = center
        self.defaults = defaults
        self.checks = checks
        self.now = now
        if let data = defaults.data(forKey: Self.lastResultKey) {
            lastResult = try? JSONDecoder().decode(DiagnosticsProbeResult.self, from: data)
        }
    }

    /// UI entry point. The synchronous guard makes a double tap a no-op before the
    /// task can be scheduled.
    @discardableResult
    func start(settings: DiagnosticsSettings) -> Bool {
        guard !isProbing else { return false }
        isProbing = true
        probeTask = Task { [weak self] in
            _ = await self?.performProbe(settings: settings)
        }
        return true
    }

    /// Test/async entry point. Returns nil when a probe is already running.
    func runProbe(settings: DiagnosticsSettings) async -> DiagnosticsProbeResult? {
        guard !isProbing else { return nil }
        isProbing = true
        return await performProbe(settings: settings)
    }

    func cancelActiveProbe() {
        probeTask?.cancel()
    }

    private func performProbe(settings: DiagnosticsSettings) async -> DiagnosticsProbeResult {
        defer {
            isProbing = false
            probeTask = nil
        }
        let snapshot = center.collectionSnapshot(consent: settings.sharingEnabled)
        guard settings.sharingEnabled else {
            return publish(result(.consentRequired, snapshot: snapshot, duration: 0, checks: nil))
        }
        guard !Task.isCancelled else {
            return publish(result(.cancelled, snapshot: snapshot, duration: 0, checks: nil))
        }
        guard snapshot.backend != .disabled else {
            return publish(await earlyResult(.diagnosticsDisabled, snapshot: snapshot))
        }
        if snapshot.backend == .firebase {
            guard snapshot.state.firebaseConfigured else {
                return publish(await earlyResult(.firebaseNotConfigured, snapshot: snapshot))
            }
            guard snapshot.state.performance != .unavailable else {
                return publish(await earlyResult(.collectionUnavailable, snapshot: snapshot))
            }
            guard snapshot.state.performance == .active else {
                return publish(await earlyResult(.collectionInactive, snapshot: snapshot))
            }
        }

        let started = center.startTrace(.manualProbe)
        let trace = started.outcome == .started ? started.trace : nil
        let traceStarted = trace != nil
        let workStart = ContinuousClock.now
        let check = await checks()
        let duration = milliseconds(workStart.duration(to: .now))
        var traceFinished = false
        let outcome: DiagnosticsProbeOutcome

        if let trace {
            if Task.isCancelled {
                trace.finish(.cancelled)
                traceFinished = true
                outcome = .cancelled
            } else if check.failed {
                trace.increment(.probeChecks, by: Int64(check.checksPassed))
                trace.finish(.failure)
                traceFinished = true
                outcome = .localChecksFailed
            } else {
                trace.increment(.probeChecks, by: Int64(check.checksPassed))
                trace.finish(.success)
                traceFinished = true
                outcome = .recorded
            }
        } else if Task.isCancelled {
            outcome = .cancelled
        } else if check.failed {
            outcome = .localChecksFailed
        } else {
            outcome = mapped(started.outcome)
        }

        return publish(result(
            outcome,
            snapshot: snapshot,
            duration: duration,
            checks: check,
            traceStarted: traceStarted,
            traceFinished: traceFinished
        ))
    }


    private func earlyResult(_ outcome: DiagnosticsProbeOutcome,
                             snapshot: DiagnosticsCollectionSnapshot) async -> DiagnosticsProbeResult {
        let workStart = ContinuousClock.now
        let check = await checks()
        return result(
            outcome,
            snapshot: snapshot,
            duration: milliseconds(workStart.duration(to: .now)),
            checks: check
        )
    }

    private func mapped(_ outcome: DiagnosticsStartOutcome) -> DiagnosticsProbeOutcome {
        switch outcome {
        case .sampledOut: .sampledOut
        case .disabled: .diagnosticsDisabled
        case .busy, .unavailable, .started: .traceUnavailable
        }
    }

    private func result(
        _ outcome: DiagnosticsProbeOutcome,
        snapshot: DiagnosticsCollectionSnapshot,
        duration: Double,
        checks: DiagnosticsProbeCheckResult?,
        traceStarted: Bool = false,
        traceFinished: Bool = false
    ) -> DiagnosticsProbeResult {
        DiagnosticsProbeResult(
            executedAt: now(),
            traceName: .manualProbe,
            traceStarted: traceStarted,
            traceFinished: traceFinished,
            durationMilliseconds: duration,
            backend: snapshot.backend,
            collectionActive: snapshot.backend == .local
                || (snapshot.backend == .firebase && snapshot.state.performance == .active),
            checksPassed: checks?.checksPassed ?? 0,
            localError: checks?.failed ?? false,
            outcome: outcome,
            serverReceipt: snapshot.backend == .firebase ? .unavailable : .notApplicable
        )
    }

    private func publish(_ result: DiagnosticsProbeResult) -> DiagnosticsProbeResult {
        lastResult = result
        if let data = try? JSONEncoder().encode(result) {
            defaults.set(data, forKey: Self.lastResultKey)
        }
        return result
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}

