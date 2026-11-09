import SwiftUI
import Combine

/// Tracks live `matchedTransitionSource` views by source ID and namespace.
///
/// Apple's zoom transition has no public way to ask “is my source still alive?”.
/// A source inside a lazy grid can be missing, or a screen can register the same
/// ID twice, when an album detail is pushed. Requesting zoom in that state is what
/// leaves an outgoing detail snapshot on screen or overlaps two covers. The
/// destination reads this registry and falls back to the standard push when no
/// source with the matching ID/namespace exists.
@MainActor
final class AlbumZoomSourceRegistry: ObservableObject {
    struct Key: Hashable, @unchecked Sendable {
        let id: String
        let namespace: Namespace.ID
    }

    static let shared = AlbumZoomSourceRegistry()
    @Published private(set) var counts: [Key: Int] = [:]

    func register(id: String, namespace: Namespace.ID) {
        counts[Key(id: id, namespace: namespace), default: 0] += 1
    }

    func unregister(_ key: Key) {
        guard let count = counts[key] else { return }
        if count <= 1 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = count - 1
        }
    }

    func sourceCount(id: String, namespace: Namespace.ID) -> Int {
        counts[Key(id: id, namespace: namespace)] ?? 0
    }
}

/// Owns one registration for the lifetime of a source view. The token is kept in
/// `@StateObject`: being covered by a pushed page keeps that state alive, while a
/// card that is actually removed/rebuilt releases the token and unregisters.
@MainActor
final class AlbumZoomSourceToken: ObservableObject {
    private let key: AlbumZoomSourceRegistry.Key?

    init(id: String?, namespace: Namespace.ID?) {
        guard let id, let namespace else {
            key = nil
            return
        }
        let key = AlbumZoomSourceRegistry.Key(id: id, namespace: namespace)
        self.key = key
        AlbumZoomSourceRegistry.shared.register(id: id, namespace: namespace)
    }

    deinit {
        guard let key else { return }
        Task { @MainActor in
            AlbumZoomSourceRegistry.shared.unregister(key)
        }
    }
}