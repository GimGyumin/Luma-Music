import Foundation
import Testing
@testable import Luma

@Suite("Manual diagnostics probe", .serialized)
@MainActor
struct DiagnosticsProbeTests {
    @Test func consentOffDoesNotCreateATrace() async throws {
        let harness = try DiagnosticsProbeHarness(consent: false, backend: .local)
        defer { harness.cleanUp() }
        let result = try #require(await harness.controller.runProbe(settings: harness.settings))
        #expect(result.outcome == .consentRequired)
        #expect(!result.traceStarted)
        #expect(!result.traceFinished)
        #expect(result.serverReceipt == .notApplicable)
        #expect(harness.recorder.measurements.isEmpty)
    }

    @Test func consentOnLocalBackendRecordsAndFinishes() async throws {
        let harness = try DiagnosticsProbeHarness(consent: true, backend: .local)
        defer { harness.cleanUp() }
        let result = try #require(await harness.controller.runProbe(settings: harness.settings))
        #expect(result.outcome == .recorded)
        #expect(result.traceStarted)
        #expect(result.traceFinished)
        #expect(result.collectionActive)
        #expect(!result.localError)
        #expect(result.checksPassed > 0)
        #expect(result.durationMilliseconds >= 0)
        #expect(result.serverReceipt == .notApplicable)
        #expect(harness.recorder.measurements.count == 1)
        #expect(harness.recorder.measurements.first?.name == .manualProbe)
        #expect(harness.recorder.measurements.first?.result == .success)
        #expect((harness.recorder.measurements.first?.metrics[.probeChecks] ?? 0) > 0)
    }

    @Test func missingConfigurationUsesLocalSinkNotNoop() async throws {
        let harness = try DiagnosticsProbeHarness(consent: true, backend: .local, configured: false)
        defer { harness.cleanUp() }
        let result = try #require(await harness.controller.runProbe(settings: harness.settings))
        #expect(result.outcome == .recorded)
        #expect(result.backend == .local)
        #expect(result.collectionActive)
        #expect(harness.recorder.measurements.count == 1)
    }

    @Test func inactiveFirebaseCollectionIsReportedWithoutATrace() async throws {
        let harness = try DiagnosticsProbeHarness(consent: true, backend: .firebase, performance: .inactive)
        defer { harness.cleanUp() }
        let result = try #require(await harness.controller.runProbe(settings: harness.settings))
        #expect(result.outcome == .collectionInactive)
        #expect(!result.traceStarted)
        #expect(!result.traceFinished)
        #expect(result.serverReceipt == .unavailable)
        #expect(harness.recorder.measurements.isEmpty)
        #expect(result.localError == false)
    }

    @Test func noopBackendIsReportedAsDisabled() async throws {
        let harness = try DiagnosticsProbeHarness(consent: true, backend: .disabled)
        defer { harness.cleanUp() }
        let result = try #require(await harness.controller.runProbe(settings: harness.settings))
        #expect(result.outcome == .diagnosticsDisabled)
        #expect(!result.traceStarted)
        #expect(result.backend == .disabled)
    }

    @Test func duplicateStartIsRejectedBeforeScheduling() async throws {
        let harness = try DiagnosticsProbeHarness(consent: true, backend: .local, checksDelay: .milliseconds(120))
        defer { harness.cleanUp() }
        #expect(harness.controller.start(settings: harness.settings))
        #expect(!harness.controller.start(settings: harness.settings))
        await harness.waitUntilIdle()
        #expect(harness.recorder.measurements.count == 1)
    }

    @Test func cancellationFinishesTheTraceAsCancelled() async throws {
        let harness = try DiagnosticsProbeHarness(consent: true, backend: .local, checksDelay: .milliseconds(600))
        defer { harness.cleanUp() }
        #expect(harness.controller.start(settings: harness.settings))
        try? await Task.sleep(for: .milliseconds(80))
        harness.controller.cancelActiveProbe()
        await harness.waitUntilIdle()
        #expect(harness.controller.lastResult?.outcome == .cancelled)
        #expect(harness.recorder.measurements.count == 1)
        #expect(harness.recorder.measurements.first?.result == .cancelled)
    }

    @Test func samplingCanSkipTheProbeButStillRunsLocalChecks() async throws {
        let harness = try DiagnosticsProbeHarness(consent: true, backend: .local, sampleEvery: 2)
        defer { harness.cleanUp() }
        let first = try #require(await harness.controller.runProbe(settings: harness.settings))
        #expect(first.outcome == .recorded)
        let second = try #require(await harness.controller.runProbe(settings: harness.settings))
        #expect(second.outcome == .sampledOut)
        #expect(!second.traceStarted)
        #expect(second.checksPassed > 0)
        #expect(harness.recorder.measurements.count == 1)
    }

    @Test func localCheckFailureFinishesTheTraceAsFailure() async throws {
        let harness = try DiagnosticsProbeHarness(consent: true, backend: .local,
            checks: DiagnosticsProbeCheckResult(checksPassed: 3, failed: true))
        defer { harness.cleanUp() }
        let result = try #require(await harness.controller.runProbe(settings: harness.settings))
        #expect(result.outcome == .localChecksFailed)
        #expect(result.localError)
        #expect(result.traceFinished)
        #expect(harness.recorder.measurements.first?.result == .failure)
    }

    @Test func localAdapterIsUsedWhenExplicitlyForced() async throws {
        let suite = "luma.probe.local.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DiagnosticsSettings(defaults: defaults, apply: { _ in })
        settings.setSharingEnabled(true)
        let center = DiagnosticsCenter()
        center.install(LocalDiagnosticsAdapter(), sampleEvery: 1, deviceClass: "phone", buildChannel: "test")
        let controller = DiagnosticsProbeController(center: center, defaults: defaults)
        let result = try #require(await controller.runProbe(settings: settings))
        #expect(result.outcome == .recorded)
        #expect(result.backend == .local)
        #expect(result.serverReceipt == .notApplicable)
    }


    @Test func firebaseResultNeverClaimsServerReceipt() async throws {
        let harness = try DiagnosticsProbeHarness(consent: true, backend: .firebase, performance: .active)
        defer { harness.cleanUp() }
        let result = try #require(await harness.controller.runProbe(settings: harness.settings))
        #expect(result.outcome == .recorded)
        #expect(result.traceFinished)
        #expect(result.serverReceipt == .unavailable)
        #expect(result.serverReceipt != .notApplicable)
    }

    @Test func encodedResultContainsNoMediaOrNetworkIdentifiers() async throws {
        let harness = try DiagnosticsProbeHarness(consent: true, backend: .firebase, performance: .active)
        defer { harness.cleanUp() }
        let result = try #require(await harness.controller.runProbe(settings: harness.settings))
        let data = try JSONEncoder().encode(result)
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["song", "artist", "album", "lyrics", "http", "token", "password"] {
            #expect(!text.contains(forbidden))
        }
        #expect(text.contains("luma_manual_diagnostics_probe"))
    }

    @Test func sessionMonitorIsBoundedAndCountsResults() {
        let monitor = DiagnosticsSessionMonitor()
        for index in 0..<55 {
            monitor.recordStarted()
            let result: DiagnosticsResult = index % 3 == 0 ? .failure : (index % 3 == 1 ? .cancelled : .success)
            monitor.recordCompleted(DiagnosticsMeasurement(
                name: .manualProbe, durationMilliseconds: Double(index), result: result, metrics: [:]
            ))
        }
        let snapshot = monitor.currentSnapshot()
        #expect(snapshot.startedCount == 55)
        #expect(snapshot.finishedCount == 55)
        #expect(snapshot.recentEvents.count == DiagnosticsSessionMonitor.capacity)
        #expect(snapshot.recentEvents.first?.name == .manualProbe)
        #expect(snapshot.failureCount + snapshot.cancelledCount + snapshot.successCount == 55)
    }

    @Test func consistencyDistinguishesRestartAndLocalOnly() {
        let info = DiagnosticsInfoPlistState(performanceCollectionEnabled: false,
            performanceCollectionDeactivated: nil, performanceInstrumentationEnabled: false,
            crashlyticsCollectionEnabled: false)
        let active = DiagnosticsCollectionState(firebaseConfigured: true, performance: .active,
            performanceInstrumentationEnabled: false, crashlytics: .active)
        let inactive = DiagnosticsCollectionState(firebaseConfigured: true, performance: .inactive,
            performanceInstrumentationEnabled: false, crashlytics: .inactive)
        #expect(DiagnosticsCollectionSnapshot(backend: .firebase, consent: true, state: active, infoPlist: info)
            .consistency == .consistent)
        #expect(DiagnosticsCollectionSnapshot(backend: .firebase, consent: true, state: inactive, infoPlist: info)
            .consistency == .pendingRestart)
        #expect(DiagnosticsCollectionSnapshot(backend: .local, consent: true, state: .unavailable, infoPlist: info)
            .consistency == .localOnly)
        #expect(DiagnosticsCollectionSnapshot(backend: .disabled, consent: false, state: .unavailable, infoPlist: info)
            .consistency == .unavailable)
    }

    @Test func statusModelObservesSessionCountsWithoutPolling() async throws {
        let center = DiagnosticsCenter()
        let recorder = DiagnosticsProbeRecorder(backend: .local, state: .unavailable)
        center.install(recorder, sampleEvery: 1, deviceClass: "phone", buildChannel: "test")
        let model = DiagnosticsStatusModel(center: center)
        model.startObserving()
        center.begin(.manualProbe).finish(.success)
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.session.startedCount == 1)
        #expect(model.session.successCount == 1)
        #expect(model.session.lastEvent?.name == .manualProbe)
        model.stopObserving()
    }

    @Test func lastResultPersistsWithoutMediaData() async throws {
        let harness = try DiagnosticsProbeHarness(consent: true, backend: .local)
        defer { harness.cleanUp() }
        let result = try #require(await harness.controller.runProbe(settings: harness.settings))
        let reloaded = DiagnosticsProbeController(center: DiagnosticsCenter(), defaults: harness.defaults)
        #expect(reloaded.lastResult?.outcome == result.outcome)
        #expect(reloaded.lastResult?.traceName == result.traceName)
        #expect(reloaded.lastResult?.serverReceipt == result.serverReceipt)
    }

    @Test func dashboardURLAndUITestModeAreFixed() {
        #expect(DiagnosticsLinks.performanceDashboard.absoluteString
            == "https://console.firebase.google.com/project/luma-music-df4a4/performance")
        let configuration = DiagnosticsConfiguration(consent: true, arguments: ["--luma-ui-testing"], environment: [:])
        #expect(configuration.localOnly)
        #expect(configuration.buildChannel == "test")
    }

    #if os(macOS)
    @Test func macOSProbeNeverUsesFirebaseBackend() async throws {
        let harness = try DiagnosticsProbeHarness(consent: true, backend: .local)
        defer { harness.cleanUp() }
        let result = try #require(await harness.controller.runProbe(settings: harness.settings))
        #expect(result.backend == .local)
        #expect(result.serverReceipt == .notApplicable)
        #expect(result.traceFinished)
    }
    #endif
}

