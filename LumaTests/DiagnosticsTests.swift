import Foundation
import Testing
@testable import Luma

@Suite("Diagnostic consent and lifecycle", .serialized)
@MainActor
struct DiagnosticsTests {
    @Test func consentDefaultsOffAndPersistsOnlyExplicitChanges() {
        let suite = "luma.diagnostics.unit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var applications = 0
        let settings = DiagnosticsSettings(defaults: defaults) { _ in applications += 1 }
        #expect(!settings.sharingEnabled)
        #expect(settings.status == .disabled)
        #expect(applications == 0)
        settings.setSharingEnabled(true)
        settings.setSharingEnabled(true)
        #expect(applications == 1)
        #expect(DiagnosticsSettings(defaults: defaults, apply: { _ in }).sharingEnabled)
        settings.setSharingEnabled(false)
        #expect(applications == 2)
        #expect(!DiagnosticsSettings(defaults: defaults, apply: { _ in }).sharingEnabled)
    }

    @Test func noConfigurationIsSafeAndTestsUseOnlyLocalBackends() {
        let configuration = DiagnosticsConfiguration(consent: false, bundle: Bundle(for: DiagnosticsBundleProbe.self),
            arguments: [], environment: [:])
        #expect(configuration.configurationPath == nil)
        #expect(!configuration.hasConsent)
        #expect(!configuration.localOnly)
        let test = DiagnosticsConfiguration(consent: true, arguments: [],
            environment: ["XCTestConfigurationFilePath": "fixture"])
        #expect(test.localOnly && test.isTest)
        #expect(test.buildChannel == "test")
        let ui = DiagnosticsConfiguration(consent: true, arguments: ["--luma-ui-testing"], environment: [:])
        #expect(ui.localOnly && ui.isTest)
    }

    @Test func disabledCenterIsNoop() {
        let center = DiagnosticsCenter()
        let trace = center.begin(.lyricsLoad)
        #expect(trace === PerformanceTrace.disabled)
        trace.increment(.failedRequests)
        trace.finish()
        center.report(.lyricsParse)
    }

    @Test func completionIsExactlyOnceAcrossRacingTasks() async {
        let spy = DiagnosticSpy()
        let center = DiagnosticsCenter()
        center.install(spy, sampleEvery: 1)
        let trace = center.begin(.lyricsLoad)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { trace.increment(.retries); trace.finish() } }
        }
        #expect(spy.measurements.count == 1)
        #expect(spy.measurements.first?.result == .success)
    }

    @Test func abandonedWorkIsCancelledAndMetricsAreBounded() {
        let spy = DiagnosticSpy()
        let center = DiagnosticsCenter()
        center.install(spy, sampleEvery: 1)
        var trace: PerformanceTrace? = center.begin(.prefetch)
        trace?.increment(.retries, by: .max)
        trace?.increment(.retries, by: .max)
        trace?.increment(.failedRequests, by: -1)
        trace = nil
        #expect(spy.measurements.count == 1)
        #expect(spy.measurements.first?.result == .cancelled)
        #expect(spy.measurements.first?.metrics[.retries] == 1_000_000_000)
        #expect(spy.measurements.first?.metrics[.failedRequests] == nil)
    }

    @Test func optOutClosesActiveOperationsAndRejectsFurtherWork() {
        let spy = DiagnosticSpy()
        let center = DiagnosticsCenter()
        center.install(spy, sampleEvery: 1)
        let active = center.begin(.audioPrepare)
        center.install(NoopDiagnosticsService())
        #expect(!spy.isEnabled)
        #expect(spy.measurements.first?.result == .cancelled)
        active.finish()
        center.begin(.audioPrepare).finish()
        center.report(.audioState)
        #expect(spy.measurements.count == 1)
        #expect(spy.issues.isEmpty)
    }

    @Test func samplesAndDeduplicatesRecoverableErrors() {
        let spy = DiagnosticSpy()
        let center = DiagnosticsCenter()
        center.install(spy, sampleEvery: 10)
        for _ in 0..<25 { center.begin(.apiRequest).finish() }
        for _ in 0..<20 { center.report(.streamRecovery) }
        center.report(.cache)
        #expect(spy.measurements.count == 3)
        #expect(spy.issues == [.streamRecovery, .cache])
    }

    @Test func attributesAreClosedFilteredAndWithinFirebaseLimit() {
        let spy = DiagnosticSpy()
        let center = DiagnosticsCenter()
        center.install(spy, sampleEvery: 1, deviceClass: "private-host.example", buildChannel: "private-account")
        center.begin(.cacheRead, attributes: [.cacheState: .wifi, .mediaFormat: .flac]).finish()
        let attributes = spy.attributes.first ?? [:]
        #expect(attributes["device_class"] == "unknown")
        #expect(attributes["app_build_channel"] == "unknown")
        #expect(attributes["cache_state"] == nil)
        #expect(attributes["media_format"] == "flac")
        #expect(attributes.count + 1 <= 5)
        #expect(DiagnosticsTraceName.allCases.allSatisfy { $0.rawValue.count <= 32 })
    }

    @Test func activeOperationsAndLocalHistoryAreBounded() {
        let local = LocalDiagnosticsAdapter()
        let center = DiagnosticsCenter()
        center.install(local, sampleEvery: 1)
        let active = (0..<200).map { _ in center.begin(.prefetch) }
        #expect(active.filter { $0 !== PerformanceTrace.disabled }.count == 128)
        active.forEach { $0.finish() }
        for _ in 0..<300 { center.begin(.cacheRead).finish() }
        #expect(local.measurements.count == 256)
        #expect(local.measurements.allSatisfy { $0.durationMilliseconds >= 0 })
    }
}

private final class DiagnosticsBundleProbe: NSObject {}

nonisolated private final class DiagnosticSpy: DiagnosticsService, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    private var completed: [DiagnosticsMeasurement] = []
    private var reported: [DiagnosticsIssue] = []
    private var startedAttributes: [[String: String]] = []
    var isEnabled: Bool { lock.withLock { enabled } }
    var measurements: [DiagnosticsMeasurement] { lock.withLock { completed } }
    var issues: [DiagnosticsIssue] { lock.withLock { reported } }
    var attributes: [[String: String]] { lock.withLock { startedAttributes } }
    func start(_ name: DiagnosticsTraceName, attributes: [String: String]) -> (any DiagnosticsBackendSpan)? {
        lock.withLock { startedAttributes.append(attributes) }
        return Span(owner: self)
    }
    func report(_ issue: DiagnosticsIssue) { lock.withLock { reported.append(issue) } }
    func disable() { lock.withLock { enabled = false } }
    private func append(_ value: DiagnosticsMeasurement) { lock.withLock { completed.append(value) } }
    private struct Span: DiagnosticsBackendSpan {
        let owner: DiagnosticSpy
        func finish(_ measurement: DiagnosticsMeasurement) { owner.append(measurement) }
    }
}
