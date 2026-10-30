// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import OSLog

/// Cross-platform album link used by shelves, grids and lists.
///
/// Album pages use the standard NavigationStack transition. The source ID remains
/// available to labels but does not activate a matched navigation zoom.
struct AlbumNavigationLink<Label: View>: View {
    let album: AlbumID3
    let namespace: Namespace.ID
    var destination: HomeDestination? = nil
    var sourceContext = ""
    @ViewBuilder let label: (String, Namespace.ID) -> Label

    private var sourceID: String { sourceContext.isEmpty ? album.id : "\(sourceContext):\(album.id)" }

    var body: some View {
        Group {
            #if os(iOS)
            NavigationLink(value: (destination ?? .album(album)).albumZoom(sourceID: sourceID, namespace: namespace)) {
                label(sourceID, namespace)
            }
            #else
            DetailNavigationLink(destination: destination ?? .album(album)) { label(sourceID, namespace) }
            #endif
        }
        #if os(iOS)
        .onAppear {
            Logger.ui.debug("[ALBUM-NAV] source appear album=\(album.id, privacy: .public) source=\(sourceID, privacy: .public) ns=\(String(describing: namespace), privacy: .public)")
        }
        .onDisappear {
            Logger.ui.debug("[ALBUM-NAV] source disappear album=\(album.id, privacy: .public) source=\(sourceID, privacy: .public) ns=\(String(describing: namespace), privacy: .public)")
        }
        #endif
    }
}
