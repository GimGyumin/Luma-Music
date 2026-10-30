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
    /// Album navigation currently uses the standard push/pop transition. Keep the
    /// link call sites stable so their destination identity and queue state do not change.
    func albumZoom(sourceID: String, namespace: Namespace.ID) -> Self {
        self
    }
}

