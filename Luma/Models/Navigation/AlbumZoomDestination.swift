import SwiftUI
import SwiftSonic

/// A value-path snapshot keeps the selected album and source namespace together.
/// Metadata refreshes do not change the identity of an already-pushed page.
nonisolated struct AlbumZoomDestination: Hashable {
    let id: String
    let name: String
    let coverArtID: String?
    let album: AlbumID3?
    let downloadedOnly: Bool
    let sourceID: String
    let namespace: Namespace.ID
    /// One id per actual route value. It is deliberately excluded from equality/hash:
    /// the same album/source opened twice is still the same destination identity, while
    /// logs can tell the two navigation attempts apart.
    let attemptID: UUID

    init?(destination: HomeDestination, sourceID: String, namespace: Namespace.ID) {
        switch destination {
        case .album(let album):
            id = album.id; name = album.name; coverArtID = album.coverArt
            self.album = album; downloadedOnly = false
        case .albumById(let id, let name, _, let cover), .albumPush(let id, let name, let cover, _):
            self.id = id; self.name = name; coverArtID = cover; album = nil; downloadedOnly = false
        case .downloadedAlbum(let album):
            id = album.albumId; name = album.name; coverArtID = album.coverArtId
            self.album = nil; downloadedOnly = true
        case .offlineAlbum(let album):
            id = album.albumId; name = album.albumName; coverArtID = album.coverArtId
            self.album = nil; downloadedOnly = false
        default: return nil
        }
        self.sourceID = sourceID; self.namespace = namespace
        self.attemptID = UUID()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.sourceID == rhs.sourceID && lhs.namespace == rhs.namespace
            && lhs.downloadedOnly == rhs.downloadedOnly
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(sourceID); hasher.combine(namespace); hasher.combine(downloadedOnly)
    }
}

extension HomeDestination {
    /// Album entry/exit stays on the standard `NavigationStack` push/pop.
    /// The value wrapper remains for older call sites, but no navigation
    /// transition is requested here.
    func albumZoom(sourceID: String, namespace: Namespace.ID) -> Self {
        _ = sourceID
        _ = namespace
        return self
    }
}

