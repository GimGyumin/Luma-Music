import Foundation

nonisolated enum DiagnosticsBackendKind: String, Codable, Sendable, Equatable {
    case disabled, local, firebase

    var displayName: String {
        switch self {
        case .disabled: "Disabled"
        case .local: "Local only"
        case .firebase: "Firebase"
        }
    }
}

nonisolated enum DiagnosticsCollectionAvailability: String, Codable, Sendable, Equatable {
    case active, inactive, unavailable
}

/// Values read directly from the public Firebase APIs. `unavailable` means the
/// platform cannot expose this state, not that collection is disabled.
nonisolated struct DiagnosticsCollectionState: Sendable, Equatable {
    var firebaseConfigured = false
    var performance: DiagnosticsCollectionAvailability = .unavailable
    var performanceInstrumentationEnabled: Bool?
    var crashlytics: DiagnosticsCollectionAvailability = .unavailable

    static let unavailable = DiagnosticsCollectionState()
}

/// Values from the app's Info.plist. These are defaults/overrides, not proof that
/// the SDK is currently collecting.
nonisolated struct DiagnosticsInfoPlistState: Sendable, Equatable {
    var performanceCollectionEnabled: Bool?
    var performanceCollectionDeactivated: Bool?
    var performanceInstrumentationEnabled: Bool?
    var crashlyticsCollectionEnabled: Bool?

    static func read(from bundle: Bundle = .main) -> DiagnosticsInfoPlistState {
        DiagnosticsInfoPlistState(
            performanceCollectionEnabled: bool("firebase_performance_collection_enabled", in: bundle),
            performanceCollectionDeactivated: bool("firebase_performance_collection_deactivated", in: bundle),
            performanceInstrumentationEnabled: bool("firebase_performance_instrumentation_enabled", in: bundle),
            crashlyticsCollectionEnabled: bool("FirebaseCrashlyticsCollectionEnabled", in: bundle)
        )
    }

    private static func bool(_ key: String, in bundle: Bundle) -> Bool? {
        guard let value = bundle.object(forInfoDictionaryKey: key) else { return nil }
        if let value = value as? Bool { return value }
        return (value as? NSNumber)?.boolValue
    }
}

nonisolated enum DiagnosticsCollectionConsistency: String, Sendable, Equatable {
    case consistent, pendingRestart, localOnly, unavailable
}

/// A point-in-time view of consent and the SDK state. It deliberately contains no
/// server-response field: the SDK exposes no per-trace upload confirmation callback.
nonisolated struct DiagnosticsCollectionSnapshot: Sendable, Equatable {
    var backend: DiagnosticsBackendKind
    var consent: Bool
    var state: DiagnosticsCollectionState
    var infoPlist: DiagnosticsInfoPlistState

    var consistency: DiagnosticsCollectionConsistency {
        guard backend == .firebase else {
            return backend == .local ? .localOnly : .unavailable
        }
        guard state.firebaseConfigured else { return .unavailable }
        let performanceMismatch = state.performance != .unavailable
            && (state.performance == .active) != consent
        let crashlyticsMismatch = state.crashlytics != .unavailable
            && (state.crashlytics == .active) != consent
        return performanceMismatch || crashlyticsMismatch ? .pendingRestart : .consistent
    }
}

nonisolated struct DiagnosticsSessionEvent: Sendable, Equatable, Identifiable {
    let id: UInt64
    let name: DiagnosticsTraceName
    let durationMilliseconds: Double
    let result: DiagnosticsResult
    let recordedAt: Date
}

nonisolated struct DiagnosticsSessionSnapshot: Sendable, Equatable {
    var startedCount = 0
    var finishedCount = 0
    var successCount = 0
    var failureCount = 0
    var cancelledCount = 0
    /// Newest first. Bounded to 50 entries by the monitor.
    var recentEvents: [DiagnosticsSessionEvent] = []

    var lastEvent: DiagnosticsSessionEvent? { recentEvents.first }
    static let empty = DiagnosticsSessionSnapshot()
}

/// In-memory, size-bounded session history. Events contain only closed trace names,
/// durations, results and timestamps. There is no persistence and no polling.
nonisolated final class DiagnosticsSessionMonitor: @unchecked Sendable {
    static let capacity = 50
    private let lock = NSLock()
    private var snapshot = DiagnosticsSessionSnapshot()
    private var nextEventID: UInt64 = 1
    private var continuations: [UUID: AsyncStream<DiagnosticsSessionSnapshot>.Continuation] = [:]

    func recordStarted() {
        lock.withLock {
            snapshot.startedCount += 1
            notifyLocked()
        }
    }

    func recordCompleted(_ measurement: DiagnosticsMeasurement, at date: Date = Date()) {
        lock.withLock {
            snapshot.finishedCount += 1
            switch measurement.result {
            case .success: snapshot.successCount += 1
            case .failure: snapshot.failureCount += 1
            case .cancelled: snapshot.cancelledCount += 1
            }
            let event = DiagnosticsSessionEvent(
                id: nextEventID,
                name: measurement.name,
                durationMilliseconds: measurement.durationMilliseconds,
                result: measurement.result,
                recordedAt: date
            )
            nextEventID &+= 1
            snapshot.recentEvents.insert(event, at: 0)
            if snapshot.recentEvents.count > Self.capacity {
                snapshot.recentEvents.removeLast(snapshot.recentEvents.count - Self.capacity)
            }
            notifyLocked()
        }
    }

    func currentSnapshot() -> DiagnosticsSessionSnapshot {
        lock.withLock { snapshot }
    }

    /// One AsyncStream per observing UI model. Values are snapshots, not raw events,
    /// so a late subscriber cannot miss the current counters.
    func stream() -> AsyncStream<DiagnosticsSessionSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock {
                continuations[id] = continuation
                continuation.yield(snapshot)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
    }

    private func notifyLocked() {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    func resetForTests() {
        lock.withLock {
            snapshot = .empty
            nextEventID = 1
        }
    }
}

