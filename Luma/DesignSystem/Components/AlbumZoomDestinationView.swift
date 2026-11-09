import SwiftUI
import OSLog

struct AlbumZoomDestinationView: View {
    let route: AlbumZoomDestination
    @Environment(\.detailNavigationPath) private var navigationPath
    @StateObject private var sourceRegistry = AlbumZoomSourceRegistry.shared
    /// Latched at destination creation, then updated only while this page is still
    /// on top. Once the path shrinks (pop started), it must not change mid-snapshot.
    @State private var usesZoom: Bool
    @State private var mountedDepth: Int?

    init(route: AlbumZoomDestination) {
        self.route = route
        _usesZoom = State(initialValue: AlbumZoomSourceRegistry.shared.sourceCount(
            id: route.sourceID, namespace: route.namespace) > 0)
    }

    private var liveSourceCount: Int {
        sourceRegistry.sourceCount(id: route.sourceID, namespace: route.namespace)
    }

    private var isPopping: Bool {
        guard let mountedDepth, let navigationPath else { return false }
        return navigationPath.wrappedValue.count < mountedDepth
    }

    private func refreshZoomDecision() {
        guard !isPopping, let mountedDepth, let navigationPath,
              navigationPath.wrappedValue.count >= mountedDepth else { return }
        let next = liveSourceCount > 0
        if usesZoom != next {
            usesZoom = next
            Logger.ui.debug("[ALBUM-ZOOM] source-decision changed attempt=\(route.attemptID.uuidString, privacy: .public) album=\(route.id, privacy: .public) usesZoom=\(next, privacy: .public) liveSources=\(liveSourceCount, privacy: .public)")
        }
    }

    var body: some View {
        Group {
            if let album = route.album {
                AlbumDetailView(album: album, coverArtId: route.coverArtID)
            } else {
                AlbumDetailView(albumId: route.id, albumName: route.name, coverArtId: route.coverArtID,
                    mode: route.downloadedOnly ? .downloadedOnly : .full)
            }
        }
        .environment(\.albumNavigationAttempt, route.attemptID.uuidString)
        // Album entry/exit uses the standard NavigationStack push/pop. The zoom
        // route is retained only as a value wrapper for older call sites; no
        // navigation transition is attached here.
        .onAppear {
            if mountedDepth == nil {
                mountedDepth = navigationPath?.wrappedValue.count ?? 0
            }
            refreshZoomDecision()
            Logger.ui.debug("[ALBUM-ZOOM] destination appear attempt=\(route.attemptID.uuidString, privacy: .public) album=\(route.id, privacy: .public) source=\(route.sourceID, privacy: .public) ns=\(String(describing: route.namespace), privacy: .public) path=\(navigationPath?.wrappedValue.count ?? -1, privacy: .public) usesZoom=\(usesZoom, privacy: .public) liveSources=\(liveSourceCount, privacy: .public)")
            if !usesZoom {
                Logger.ui.debug("[ALBUM-ZOOM] zoom fallback attempt=\(route.attemptID.uuidString, privacy: .public) album=\(route.id, privacy: .public) liveSources=\(liveSourceCount, privacy: .public)")
            } else if liveSourceCount > 1 {
                Logger.ui.debug("[ALBUM-ZOOM] duplicate sources attempt=\(route.attemptID.uuidString, privacy: .public) album=\(route.id, privacy: .public) liveSources=\(liveSourceCount, privacy: .public)")
            }
        }
        .onChange(of: sourceRegistry.counts) { _, _ in
            refreshZoomDecision()
        }
        .onChange(of: navigationPath?.wrappedValue.count) { _, _ in
            refreshZoomDecision()
        }
        .onDisappear {
            Logger.ui.debug("[ALBUM-ZOOM] destination disappear attempt=\(route.attemptID.uuidString, privacy: .public) album=\(route.id, privacy: .public) source=\(route.sourceID, privacy: .public) ns=\(String(describing: route.namespace), privacy: .public) path=\(navigationPath?.wrappedValue.count ?? -1, privacy: .public) usesZoom=\(usesZoom, privacy: .public) liveSources=\(liveSourceCount, privacy: .public)")
        }
    }
}
