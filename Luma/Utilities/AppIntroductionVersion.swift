import Foundation

nonisolated enum AppIntroductionVersion {
    static let storageKey = "luma.introduction.seenVersion"
    static var current: String {
        identifier(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                   build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
    }
    static func identifier(version: String, build: String) -> String { "\(version) (\(build))" }
    static func needsPresentation(seen: String, current: String) -> Bool { seen != current }
}
