import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

nonisolated struct DiagnosticsConfiguration: Sendable {
    static let consentKey = "luma.diagnostics.sharing"
    let hasConsent: Bool
    let isTest: Bool
    let localOnly: Bool
    let configurationPath: String?
    let buildChannel: String

    init(consent: Bool, bundle: Bundle = .main, arguments: [String] = ProcessInfo.processInfo.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        hasConsent = consent
        isTest = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestSessionIdentifier"] != nil
            || arguments.contains("--luma-ui-testing")
        localOnly = arguments.contains("--luma-diagnostics-local") || isTest
        #if DEBUG
        buildChannel = isTest ? "test" : "debug"
        #else
        buildChannel = isTest ? "test" : "release"
        #endif
        configurationPath = Self.validConfiguration(in: bundle)
    }
    static func validConfiguration(in bundle: Bundle) -> String? {
        guard let path = bundle.path(forResource: "GoogleService-Info", ofType: "plist"),
              let data = FileManager.default.contents(atPath: path),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              isValidConfiguration(dictionary, bundleIdentifier: bundle.bundleIdentifier) else { return nil }
        return path
    }

    /// Pure validation used by both the runtime guard and tests. A plist copied from
    /// another app (or a placeholder) must never configure Firebase.
    nonisolated static func isValidConfiguration(
        _ dictionary: [String: Any], bundleIdentifier: String?
    ) -> Bool {
        guard let bundleIdentifier,
              dictionary["BUNDLE_ID"] as? String == bundleIdentifier,
              let appID = dictionary["GOOGLE_APP_ID"] as? String, !appID.isEmpty,
              appID.hasPrefix("1:"),
              let project = dictionary["PROJECT_ID"] as? String, !project.isEmpty,
              let apiKey = dictionary["API_KEY"] as? String, !apiKey.isEmpty else { return false }
        return true
    }
}

@MainActor @Observable
final class DiagnosticsSettings {
    static let shared = DiagnosticsSettings()
    private let defaults: UserDefaults
    private let apply: @MainActor (DiagnosticsSettings) -> Void
    private(set) var sharingEnabled: Bool
    private(set) var status = Status.disabled
    enum Status: Equatable { case disabled, local, sharing, missingConfiguration }

    init(defaults: UserDefaults? = nil,
         apply: @escaping @MainActor (DiagnosticsSettings) -> Void = DiagnosticsBootstrap.apply) {
        self.apply = apply
        if let defaults { self.defaults = defaults }
        else if ProcessInfo.processInfo.arguments.contains("--luma-ui-testing") {
            self.defaults = UserDefaults(suiteName: "luma.diagnostics.ui-fixture")!
        } else { self.defaults = .standard }
        sharingEnabled = self.defaults.bool(forKey: DiagnosticsConfiguration.consentKey)
    }
    func setSharingEnabled(_ enabled: Bool) {
        guard sharingEnabled != enabled else { return }
        sharingEnabled = enabled
        defaults.set(enabled, forKey: DiagnosticsConfiguration.consentKey)
        apply(self)
    }
    func setStatus(_ value: Status) { status = value }
}
