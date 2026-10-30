// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

extension Notification.Name {
    static let lumaFullPlayerPresentationChanged = Notification.Name("lumaFullPlayerPresentationChanged")
}

// MARK: - Player navigation helpers

func postNavigateToAlbum(track: DisplayableSong) {
    guard let albumId = track.albumId else { return }
    NotificationCenter.default.post(
        name: .lumaNavigateToAlbum,
        object: nil,
        userInfo: [
            "albumId":   albumId,
            "albumName": track.albumName ?? "",
            "coverArtId": track.coverArtId as Any
        ]
    )
}

func postNavigateToArtist(track: DisplayableSong) {
    guard let artistId = track.artistId else { return }
    postNavigateToArtist(artistId: artistId, artistName: track.artist ?? "", coverArtId: track.coverArtId)
}

func postNavigateToArtist(artistId: String, artistName: String, coverArtId: String?) {
    NotificationCenter.default.post(
        name: .lumaNavigateToArtist,
        object: nil,
        userInfo: [
            "artistId":   artistId,
            "artistName": artistName,
            "coverArtId": coverArtId as Any
        ]
    )
}

func postNavigateToPlaylist(playlistId: String, name: String, coverArtId: String?) {
    NotificationCenter.default.post(
        name: .lumaNavigateToPlaylist,
        object: nil,
        userInfo: [
            "playlistId": playlistId,
            "name":       name,
            "coverArtId": coverArtId as Any
        ]
    )
}

/// A playlist was deleted (server-confirmed) from a detail surface. The playlist list observes this to reload,
/// so the deleted playlist disappears on return without a manual refresh — and without an `.onAppear` reload.
func postPlaylistDeleted() {
    NotificationCenter.default.post(name: .lumaPlaylistDeleted, object: nil)
}

extension Notification.Name {
    nonisolated static let lumaDownloadCompleted = Notification.Name("luma.downloadCompleted")
    nonisolated static let lumaTogglePlayPause = Notification.Name("luma.togglePlayPause")
    nonisolated static let lumaSkipNext = Notification.Name("luma.skipNext")
    nonisolated static let lumaSkipPrevious = Notification.Name("luma.skipPrevious")
    nonisolated static let lumaFocusSearch = Notification.Name("luma.focusSearch")
    nonisolated static let lumaSearchInApp = Notification.Name("luma.searchInApp")
    nonisolated static let lumaToggleShuffle = Notification.Name("luma.toggleShuffle")
    nonisolated static let lumaToggleRepeat = Notification.Name("luma.toggleRepeat")
    nonisolated static let lumaToggleQueue = Notification.Name("luma.toggleQueue")
    nonisolated static let lumaOpenFullPlayer = Notification.Name("luma.openFullPlayer")
    nonisolated static let lumaOpenFullPlayerLyrics = Notification.Name("luma.openFullPlayerLyrics")
    nonisolated static let lumaSelectAlbums = Notification.Name("luma.selectAlbums")
    nonisolated static let lumaNavigateToAlbum    = Notification.Name("lumaNavigateToAlbum")
    nonisolated static let lumaNavigateToArtist   = Notification.Name("lumaNavigateToArtist")
    nonisolated static let lumaNavigateToPlaylist = Notification.Name("lumaNavigateToPlaylist")
    nonisolated static let lumaPlaylistDeleted    = Notification.Name("luma.playlistDeleted")
    /// Posted after server credentials are saved or the active server changes — clients should drop cached API sessions and Home should reload.
    nonisolated static let lumaServerCredentialsChanged = Notification.Name("luma.serverCredentialsChanged")
    /// Posted after a star/unstar or favorites sync so Library can refresh the top Favorites shelf.
    nonisolated static let lumaFavoritesChanged = Notification.Name("luma.favoritesChanged")
    /// AirPlay / route picker sheet is about to appear — pause Apple Translation so it can’t fight the picker or underrun audio.
    nonisolated static let lumaRoutePickerWillPresent = Notification.Name("luma.routePickerWillPresent")
    /// Route picker sheet dismissed — safe to resume a deferred translation.
    nonisolated static let lumaRoutePickerDidDismiss = Notification.Name("luma.routePickerDidDismiss")
}
