import Foundation

/// App-lifetime traces. These stay fixed per process and are never named after a song,
/// account or server. If diagnostics are disabled, `DiagnosticsCenter` returns the shared
/// disabled trace and these helpers cost only a lock-free check.
nonisolated enum DiagnosticsLifecycle {
    private static let lock = NSLock()
    private static var coldStart: PerformanceTrace?
    private static var homeReady: PerformanceTrace?
    private static var warmStart: PerformanceTrace?

    static func beginAppLaunch() {
        let center = DiagnosticsCenter.shared
        let cold = center.begin(.coldStart)
        let home = center.begin(.homeReady)
        lock.withLock {
            coldStart = cold
            homeReady = home
        }
    }

    /// First SwiftUI root is on screen. Finishing twice is a no-op.
    static func finishColdStart(result: DiagnosticsResult = .success) {
        let trace = lock.withLock { () -> PerformanceTrace? in
            defer { coldStart = nil }
            return coldStart
        }
        trace?.finish(result)
    }

    /// The bootstrap gate opened: Home can issue the first catalog request.
    static func finishHomeReady(result: DiagnosticsResult = .success) {
        let trace = lock.withLock { () -> PerformanceTrace? in
            defer { homeReady = nil }
            return homeReady
        }
        trace?.finish(result)
    }

    /// Returning from background is a different latency budget from a cold launch.
    static func beginWarmStart() {
        warmStart?.finish(.cancelled)
        let trace = DiagnosticsCenter.shared.begin(.warmStart)
        lock.withLock { warmStart = trace }
    }

    static func finishWarmStart(result: DiagnosticsResult = .success) {
        let trace = lock.withLock { () -> PerformanceTrace? in
            defer { warmStart = nil }
            return warmStart
        }
        trace?.finish(result)
    }

    /// Test seam. Production code never calls this.
    static func resetForTests() {
        lock.withLock {
            coldStart?.finish(.cancelled)
            homeReady?.finish(.cancelled)
            warmStart?.finish(.cancelled)
            coldStart = nil
            homeReady = nil
            warmStart = nil
        }
    }
}
