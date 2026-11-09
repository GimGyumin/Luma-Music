import Foundation
import WidgetKit

/// Publishes the already-built Luma personal mixes to the App Group snapshot used by
/// the recommendations widget. The app must not start a second recommendation graph
/// merely to fill a widget.
@MainActor
enum PersonalMixWidgetSnapshot {
    static func publish(_ mixes: [PersonalMix]) {
        // Keep the same stable priority used by the Playlists shelf, and omit empty mixes.
        let ordered = PlaylistRecommendationPolicy.ordered(mixes)
        let snapshot = ordered.map { SharedMixInfo(kind: $0.kind.rawValue, trackCount: $0.tracks.count) }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let existing = SharedStorage.read { $0.data(forKey: SharedStorageKey.personalMixes.rawValue) }
        guard existing != data else { return }
        SharedStorage.writeAndWait { $0.set(data, forKey: SharedStorageKey.personalMixes.rawValue) }
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.recommendations)
    }
}
