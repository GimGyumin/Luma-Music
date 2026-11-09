import Foundation
import Testing
@testable import Luma

@Suite("Diagnostics integration", .serialized)
@MainActor
struct DiagnosticsIntegrationTests {
    private let requiredTraceNames: Set<String> = [
        "luma_cold_start", "luma_warm_start", "luma_restore_session", "luma_home_ready",
        "luma_album_open", "luma_album_close", "luma_player_open", "luma_player_close",
        "luma_library_render", "luma_artwork_decode", "luma_play_request_to_audio",
        "luma_audio_prepare", "luma_first_audio", "luma_seek", "luma_stream_reconnect",
        "luma_cache_read", "luma_cache_write", "luma_prefetch", "luma_gapless_transition",
        "luma_lyrics_load", "luma_lyrics_parse", "luma_lyrics_first_render",
        "luma_lyrics_sync_ready", "luma_waveform_prepare", "luma_waveform_first_render",
        "luma_lyrics_screen_enter", "luma_library_sync", "luma_spotlight_query",
        "luma_fts_query", "luma_search_merge", "luma_replay_sync",
        "luma_manual_diagnostics_probe"
    ]

    @Test func traceCatalogIsFixedAndWithinFirebaseLimits() {
        let names = DiagnosticsTraceName.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        #expect(requiredTraceNames.isSubset(of: Set(names)))
        for name in names {
            #expect(name.hasPrefix("luma_"))
            #expect(name.count <= 100)
            #expect(!name.contains(" "))
        }
        for attribute in [DiagnosticsAttribute.connectionType, .mediaFormat, .cacheState,
                          .playbackMode, .offlineState] {
            #expect(attribute.rawValue.count <= 40)
        }
    }

    @Test func closedAttributeValuesRejectMismatchedEnumCases() {
        #expect(!DiagnosticsValue.wifi.isValid(for: .cacheState))
        #expect(!DiagnosticsValue.flac.isValid(for: .connectionType))
        #expect(DiagnosticsValue.hit.isValid(for: .cacheState))
        #expect(DiagnosticsValue.gapless.isValid(for: .playbackMode))
        #expect(DiagnosticsValue.offline.isValid(for: .offlineState))
    }

    @Test func playbackTelemetryClosesEverySpanAndCountsHealth() {
        let recorder = DiagnosticRecorder()
        let center = DiagnosticsCenter()
        center.install(recorder, sampleEvery: 1)
        var telemetry = PlaybackTelemetry()
        telemetry.beginRequest(center: center)
        telemetry.markEngineStarted(center: center)
        telemetry.markConfirmed(center: center)
        telemetry.noteUnderrun()
        telemetry.beginSeek(center: center)
        telemetry.finishSeek(.success)
        telemetry.markStopped()

        let measurements = recorder.measurements
        #expect(Set(measurements.map(\.name.rawValue)).isSuperset(of: [
            "luma_play_request_to_audio", "luma_audio_prepare", "luma_first_audio",
            "luma_playback_session", "luma_seek"
        ]))
        #expect(measurements.allSatisfy { $0.result == .success })
        #expect(measurements.first(where: { $0.name == .playbackSession })?.metrics[.underruns] == 1)
        #expect(!telemetry.hasActiveSession)
    }

    @Test func cancellationClosesPendingPlaybackSpans() {
        let recorder = DiagnosticRecorder()
        let center = DiagnosticsCenter()
        center.install(recorder, sampleEvery: 1)
        var telemetry = PlaybackTelemetry()
        telemetry.beginRequest(center: center)
        telemetry.beginSeek(center: center)
        telemetry.cancelPending()
        #expect(recorder.measurements.count == 3)
        #expect(recorder.measurements.allSatisfy { $0.result == .cancelled })
    }

    @Test func gaplessFailureCarriesFixedCounter() {
        let recorder = DiagnosticRecorder()
        let center = DiagnosticsCenter()
        center.install(recorder, sampleEvery: 1)
        var telemetry = PlaybackTelemetry()
        telemetry.beginGapless(center: center)
        telemetry.finishGapless(.failure, failed: true)
        let measurement = recorder.measurements.first
        #expect(measurement?.name == .gaplessTransition)
        #expect(measurement?.result == .failure)
        #expect(measurement?.metrics[.gaplessFailures] == 1)
    }

    @Test func lifecycleClosesColdAndHomeReadyExactlyOnce() {
        let recorder = DiagnosticRecorder()
        DiagnosticsCenter.shared.install(recorder, sampleEvery: 1)
        DiagnosticsLifecycle.resetForTests()
        defer {
            DiagnosticsLifecycle.resetForTests()
            DiagnosticsCenter.shared.install(NoopDiagnosticsService())
        }
        DiagnosticsLifecycle.beginAppLaunch()
        DiagnosticsLifecycle.finishColdStart()
        DiagnosticsLifecycle.finishColdStart()
        DiagnosticsLifecycle.finishHomeReady()
        let names = recorder.measurements.map(\.name)
        #expect(names.filter { $0 == .coldStart }.count == 1)
        #expect(names.filter { $0 == .homeReady }.count == 1)
    }

    @Test func crashContextOnlyAcceptsClosedValues() {
        let recorder = DiagnosticRecorder()
        let center = DiagnosticsCenter()
        center.install(recorder, sampleEvery: 1)
        center.updateContext(.cacheState, value: .wifi)
        center.updateContext(.playbackMode, value: .gapless)
        #expect(recorder.contexts.count == 1)
        #expect(recorder.contexts.first?.0 == .playbackMode)
        #expect(recorder.contexts.first?.1 == .gapless)
    }

    @Test func configurationValidationRejectsPlaceholdersAndWrongBundle() {
        let valid: [String: Any] = [
            "BUNDLE_ID": "com.kyumin.Music.Luma",
            "GOOGLE_APP_ID": "1:1234567890:ios:abcdef",
            "PROJECT_ID": "luma-test",
            "API_KEY": "not-a-secret-in-this-fixture"
        ]
        #expect(DiagnosticsConfiguration.isValidConfiguration(valid, bundleIdentifier: "com.kyumin.Music.Luma"))
        #expect(!DiagnosticsConfiguration.isValidConfiguration(valid, bundleIdentifier: "com.example.Other"))
        #expect(!DiagnosticsConfiguration.isValidConfiguration(valid, bundleIdentifier: nil))
        var placeholder = valid
        placeholder["GOOGLE_APP_ID"] = "YOUR_GOOGLE_APP_ID"
        #expect(!DiagnosticsConfiguration.isValidConfiguration(placeholder,
            bundleIdentifier: "com.kyumin.Music.Luma"))
        var noKey = valid
        noKey["API_KEY"] = ""
        #expect(!DiagnosticsConfiguration.isValidConfiguration(noKey,
            bundleIdentifier: "com.kyumin.Music.Luma"))
    }
}

nonisolated private final class DiagnosticRecorder: DiagnosticsService, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DiagnosticsMeasurement] = []
    private var storedContexts: [(DiagnosticsAttribute, DiagnosticsValue)] = []
    var isEnabled: Bool { true }
    var measurements: [DiagnosticsMeasurement] { lock.withLock { stored } }
    var contexts: [(DiagnosticsAttribute, DiagnosticsValue)] { lock.withLock { storedContexts } }

    func start(_ name: DiagnosticsTraceName, attributes: [String: String]) -> (any DiagnosticsBackendSpan)? {
        Span(owner: self)
    }

    func report(_ issue: DiagnosticsIssue) {}

    func disable() {}

    func setContext(_ attribute: DiagnosticsAttribute, value: DiagnosticsValue) {
        lock.withLock { storedContexts.append((attribute, value)) }
    }

    private func append(_ measurement: DiagnosticsMeasurement) {
        lock.withLock { stored.append(measurement) }
    }

    private struct Span: DiagnosticsBackendSpan {
        let owner: DiagnosticRecorder
        func finish(_ measurement: DiagnosticsMeasurement) { owner.append(measurement) }
    }
}
