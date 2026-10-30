import SwiftUI

struct AlbumZoomDestinationView: View {
    let route: AlbumZoomDestination
    var body: some View {
        Group {
            if let album = route.album {
                AlbumDetailView(album: album)
            } else {
                AlbumDetailView(albumId: route.id, albumName: route.name, coverArtId: route.coverArtID,
                    mode: route.downloadedOnly ? .downloadedOnly : .full)
            }
        }
    }
}
