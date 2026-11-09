import SwiftUI

/// Single source of truth for chrome that must remain stable while an album detail
/// page participates in a zoom transition. SwiftUI's `onScrollDown` tab-bar
/// minimization can otherwise run during the push/pop transition and visibly
/// re-show the bar for a frame.
@MainActor
@Observable
final class TabBarChromeState {
    private(set) var albumPageIDs: Set<String> = []

    var isAlbumPresented: Bool { !albumPageIDs.isEmpty }

    func beginAlbum(pageID: String) {
        guard !pageID.isEmpty else { return }
        albumPageIDs.insert(pageID)
    }

    func endAlbum(pageID: String) {
        albumPageIDs.remove(pageID)
    }
}
