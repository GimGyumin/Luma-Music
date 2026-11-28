import SwiftUI
import OSLog

/// Chrome that must remain stable only while a detail page is participating in a
/// navigation transition. The pin is held from the start of the appearance/disappearance
/// transition until it settles — never for the page's whole lifetime.
///
/// Pinning for the lifetime is what made `.never` tab-bar minimization leak into other
/// tabs: an album left in one tab's navigation stack kept the pin alive, so the mini
/// player stayed expanded when scrolling anywhere else.
@MainActor
@Observable
final class TabBarChromeState {
    private(set) var transitionPageIDs: Set<String> = []

    var isTransitioning: Bool { !transitionPageIDs.isEmpty }

    func beginTransition(pageID: String) {
        guard !pageID.isEmpty else { return }
        transitionPageIDs.insert(pageID)
        Logger.ui.debug("[CHROME] transition begin page=\(pageID, privacy: .public) pages=\(self.transitionPageIDs.count, privacy: .public)")
    }

    func endTransition(pageID: String) {
        transitionPageIDs.remove(pageID)
        Logger.ui.debug("[CHROME] transition end page=\(pageID, privacy: .public) pages=\(self.transitionPageIDs.count, privacy: .public)")
    }
}
