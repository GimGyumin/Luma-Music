import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(FirebaseCore)
import FirebaseCore
#endif
#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif
#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(FirebasePerformance)
import FirebasePerformance
#endif

/// Only closed, normalized values reach Firebase. This adapter never creates HTTPMetric
/// instances, forwards Error objects, records user IDs, or includes request URLs.
nonisolated final class FirebaseDiagnosticsAdapter: DiagnosticsService, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    private let local = LocalDiagnosticsAdapter()
    var isEnabled: Bool { lock.withLock { enabled } }
    var backendKind: DiagnosticsBackendKind { .firebase }

    func collectionState() -> DiagnosticsCollectionState {
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(FirebaseCore)
        guard FirebaseApp.app() != nil else { return .unavailable }
        var state = DiagnosticsCollectionState(firebaseConfigured: true)
        #if canImport(FirebasePerformance)
        let performance = Performance.sharedInstance()
        state.performance = performance.isDataCollectionEnabled ? .active : .inactive
        state.performanceInstrumentationEnabled = performance.isInstrumentationEnabled
        #endif
        #if canImport(FirebaseCrashlytics)
        state.crashlytics = Crashlytics.crashlytics().isCrashlyticsCollectionEnabled() ? .active : .inactive
        #endif
        return state
        #else
        return .unavailable
        #endif
    }

    func start(_ name: DiagnosticsTraceName, attributes: [String: String]) -> (any DiagnosticsBackendSpan)? {
        let localSpan = local.start(name, attributes: attributes)
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(FirebasePerformance) && canImport(FirebaseCore)
        guard isEnabled, FirebaseApp.app() != nil else { return localSpan }
        let remote: FirebasePerformance.Trace? = Performance.startTrace(name: name.rawValue)
        for (key, value) in attributes { remote?.setValue(value, forAttribute: key) }
        return Span(owner: self, local: localSpan, remote: remote)
        #else
        return localSpan
        #endif
    }

    func report(_ issue: DiagnosticsIssue) {
        guard isEnabled else { return }
        local.report(issue)
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(FirebaseCrashlytics) && canImport(FirebaseCore)
        guard FirebaseApp.app() != nil else { return }
        // Domain + numeric code only. No localized text, URL, song, account or token.
        Crashlytics.crashlytics().record(error: NSError(domain: "LumaDiagnostics", code: issue.rawValue))
        #endif
    }

    /// A non-sensitive playback fact for crash reports. Closed values only.
    func setContext(_ attribute: DiagnosticsAttribute, value: DiagnosticsValue) {
        guard value.isValid(for: attribute) else { return }
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(FirebaseCrashlytics) && canImport(FirebaseCore)
        guard isEnabled, FirebaseApp.app() != nil else { return }
        Crashlytics.crashlytics().setCustomValue(value.rawValue, forKey: attribute.rawValue)
        #endif
    }

    func disable() {
        let wasEnabled = lock.withLock { () -> Bool in
            let previous = enabled
            enabled = false
            return previous
        }
        guard wasEnabled else { return }
        local.disable()
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(FirebasePerformance)
        // Persisted by the SDK. It may take a subsequent launch to fully stop uploads;
        // the settings UI says so instead of promising an instant stop.
        Performance.sharedInstance().isDataCollectionEnabled = false
        #endif
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(FirebaseCrashlytics)
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)
        Crashlytics.crashlytics().deleteUnsentReports()
        #endif
    }
    #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(FirebasePerformance)
    private struct Span: DiagnosticsBackendSpan, @unchecked Sendable {
        let owner: FirebaseDiagnosticsAdapter
        let local: (any DiagnosticsBackendSpan)?
        let remote: FirebasePerformance.Trace?
        func finish(_ measurement: DiagnosticsMeasurement) {
            local?.finish(measurement)
            // Disabling collection wins any race with an in-flight completion.
            if owner.isEnabled {
                remote?.setValue(measurement.result.rawValue, forAttribute: "operation_result")
                for (metric, value) in measurement.metrics { remote?.incrementMetric(metric.rawValue, by: value) }
            }
            remote?.stop()
        }
    }
    #endif
}

@MainActor
enum DiagnosticsBootstrap {
    private static var started = false
    static func start() {
        guard !started else { return }
        started = true
        apply(settings: .shared)
    }
    static func apply(settings: DiagnosticsSettings) {
        let configuration = DiagnosticsConfiguration(consent: settings.sharingEnabled)
        #if os(macOS)
        let deviceClass = "mac"
        #elseif os(iOS)
        let deviceClass = UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone"
        #else
        let deviceClass = "other"
        #endif
        guard configuration.hasConsent else {
            DiagnosticsCenter.shared.install(NoopDiagnosticsService())
            settings.setStatus(.disabled)
            return
        }
        if configuration.localOnly {
            DiagnosticsCenter.shared.install(LocalDiagnosticsAdapter(), sampleEvery: 1, deviceClass: deviceClass, buildChannel: configuration.buildChannel)
            settings.setStatus(.local)
            return
        }
        // Native macOS and Mac Catalyst have no supported Firebase Performance product.
        // They keep the same trace API, implemented with os_signpost and an in-process
        // bounded history, so no performance data leaves the device.
        #if os(macOS) || targetEnvironment(macCatalyst)
        DiagnosticsCenter.shared.install(LocalDiagnosticsAdapter(), sampleEvery: 1,
            deviceClass: deviceClass, buildChannel: configuration.buildChannel)
        settings.setStatus(.local)
        #elseif os(iOS) && canImport(FirebaseCore)
        guard let path = configuration.configurationPath,
              let options = FirebaseOptions(contentsOfFile: path) else {
            // Consent is on but Firebase has no usable app configuration. Keep the
            // local trace surface so the user can still verify instrumentation;
            // nothing is uploaded.
            DiagnosticsCenter.shared.install(LocalDiagnosticsAdapter(), sampleEvery: 1,
                deviceClass: deviceClass, buildChannel: configuration.buildChannel)
            settings.setStatus(.missingConfiguration)
            return
        }
        #if canImport(FirebasePerformance)
        // Must run BEFORE configure(). Automatic startup/screen/network traces are
        // disabled because OpenSubsonic credentials can live in query strings and because
        // Firebase cannot verify they are scrubbed from its automatic HTTP capture.
        Performance.sharedInstance().isInstrumentationEnabled = false
        Performance.sharedInstance().isDataCollectionEnabled = false
        #endif
        if FirebaseApp.app() == nil { FirebaseApp.configure(options: options) }
        #if canImport(FirebaseCrashlytics)
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        Crashlytics.crashlytics().setCustomValue(configuration.buildChannel, forKey: "app_build_channel")
        Crashlytics.crashlytics().setCustomValue(deviceClass, forKey: "device_class")
        #endif
        #if canImport(FirebasePerformance)
        // The SDK persists this setting. Enabling can take a subsequent launch to apply.
        Performance.sharedInstance().isDataCollectionEnabled = true
        #endif
        DiagnosticsCenter.shared.install(FirebaseDiagnosticsAdapter(),
            sampleEvery: configuration.buildChannel == "debug" ? 1 : 10,
            deviceClass: deviceClass, buildChannel: configuration.buildChannel)
        settings.setStatus(.sharing)
        #else
        DiagnosticsCenter.shared.install(LocalDiagnosticsAdapter(), sampleEvery: 1,
            deviceClass: deviceClass, buildChannel: configuration.buildChannel)
        settings.setStatus(.missingConfiguration)
        #endif
    }
}
