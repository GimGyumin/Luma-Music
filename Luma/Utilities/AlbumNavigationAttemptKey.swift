import SwiftUI

private struct AlbumNavigationAttemptKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// Per-push identifier used only by diagnostics. Empty for standard pushes.
    var albumNavigationAttempt: String {
        get { self[AlbumNavigationAttemptKey.self] }
        set { self[AlbumNavigationAttemptKey.self] = newValue }
    }
}