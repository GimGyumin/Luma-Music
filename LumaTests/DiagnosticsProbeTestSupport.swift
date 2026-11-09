import Foundation
import Testing
@testable import Luma

@MainActor
struct DiagnosticsProbeHarness {
    let settings: DiagnosticsSettings
    let controller: DiagnosticsProbeController
    let recorder: DiagnosticsProbeRecorder
    let defaults: UserDefaults
    let suite: String

    init(consent: Bool, backend: DiagnosticsBackendKind,
         configured: Bool = true,
         performance: DiagnosticsCollectionAvailability = .active,
         sampleEvery: Int = 1,
         checksDelay: Duration = .zero,
         checks: DiagnosticsProbeCheckResult = DiagnosticsProbeChecks.run()) throws {
        suite = "luma.probe.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        let localSettings = DiagnosticsSettings(defaults: defaults, apply: { _ in })
        settings = localSettings
        recorder = DiagnosticsProbeRecorder(
            backend: backend,
            state: DiagnosticsCollectionState(
                firebaseConfigured: configured,
                performance: performance,
                performanceInstrumentationEnabled: false,
                crashlytics: backend == .firebase ? performance : .unavailable
            )
        )
        let center = DiagnosticsCenter()
        if backend == .disabled {
            center.install(NoopDiagnosticsService(), sampleEvery: sampleEvery, deviceClass: "phone", buildChannel: "test")
        } else {
            center.install(recorder, sampleEvery: sampleEvery, deviceClass: "phone", buildChannel: "test")
        }
        controller = DiagnosticsProbeController(center: center, defaults: defaults, checks: {
            if checksDelay > .zero { try? await Task.sleep(for: checksDelay) }
            return checks
        })
        if consent { localSettings.setSharingEnabled(true) }
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }

    func waitUntilIdle() async {
        let deadline = ContinuousClock.now + .seconds(4)
        while controller.isProbing, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

nonisolated final class DiagnosticsProbeRecorder: DiagnosticsService, @unchecked Sendable {
    let backendKind: DiagnosticsBackendKind
    private let state: DiagnosticsCollectionState
    private let lock = NSLock()
    private var stored: [DiagnosticsMeasurement] = []
    var measurements: [DiagnosticsMeasurement] { lock.withLock { stored } }

    init(backend: DiagnosticsBackendKind, state: DiagnosticsCollectionState) {
        backendKind = backend
        self.state = state
    }

    var isEnabled: Bool { true }
    func collectionState() -> DiagnosticsCollectionState { state }
    func start(_ name: DiagnosticsTraceName, attributes: [String: String]) -> (any DiagnosticsBackendSpan)? {
        Span(owner: self)
    }
    func report(_ issue: DiagnosticsIssue) {}
    func disable() {}
    func append(_ measurement: DiagnosticsMeasurement) { lock.withLock { stored.append(measurement) } }

    private struct Span: DiagnosticsBackendSpan {
        let owner: DiagnosticsProbeRecorder
        func finish(_ measurement: DiagnosticsMeasurement) { owner.append(measurement) }
    }
}
