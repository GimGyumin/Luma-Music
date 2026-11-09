// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import OSLog
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

extension View {
    func songContextMenu(song: DisplayableSong, coverImage: PlatformImage? = nil) -> some View {
        modifier(SongContextMenuModifier(song: song, coverImage: coverImage))
    }

    /// - Parameters:
    ///   - coverImage: Pre-loaded image from ArtworkImageCache. Pass nil to show a placeholder.
    ///   - songs: Pre-loaded tracks. Pass `[]` (default) on list rows to hide play actions.
    ///   - favoriteType: Pass `.album` for albums; `nil` for playlists (not supported by Subsonic).
    func collectionContextMenu(
        itemType: PinnedItemType,
        itemId: String,
        displayName: String,
        displaySubtitle: String = "",
        coverArtId: String? = nil,
        coverImage: PlatformImage? = nil,
        songs: [DisplayableSong] = [],
        favoriteType: FavoriteType? = nil,
        onEdit: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        modifier(CollectionContextMenuModifier(
            itemType: itemType,
            itemId: itemId,
            displayName: displayName,
            displaySubtitle: displaySubtitle,
            coverArtId: coverArtId,
            coverImage: coverImage,
            songs: songs,
            favoriteType: favoriteType,
            onEdit: onEdit,
            onDelete: onDelete
        ))
    }

    /// Variant for items where songs must be fetched on demand.
    /// `songLoader` is called lazily when a play action is tapped.
    func lazyCollectionContextMenu(
        itemType: PinnedItemType,
        itemId: String,
        displayName: String,
        displaySubtitle: String = "",
        coverArtId: String? = nil,
        coverImage: PlatformImage? = nil,
        favoriteType: FavoriteType? = nil,
        songLoader: @escaping () async throws -> [DisplayableSong]
    ) -> some View {
        modifier(LazyCollectionContextMenuModifier(
            itemType: itemType,
            itemId: itemId,
            displayName: displayName,
            displaySubtitle: displaySubtitle,
            coverArtId: coverArtId,
            coverImage: coverImage,
            favoriteType: favoriteType,
            songLoader: songLoader
        ))
    }

    /// Long-press menu for albums: Play / Pin to Home / Favorite (loads tracks on demand).
    func albumLongPressMenu(_ album: AlbumID3) -> some View {
        modifier(AlbumLongPressMenuModifier(
            albumId: album.id,
            displayName: album.name,
            displaySubtitle: album.artist ?? "",
            coverArtId: album.coverArt
        ))
    }

    /// Long-press menu for albums identified by raw ids (downloaded / search history).
    func albumLongPressMenu(
        id: String,
        name: String,
        artist: String? = nil,
        coverArtId: String? = nil
    ) -> some View {
        modifier(AlbumLongPressMenuModifier(
            albumId: id,
            displayName: name,
            displaySubtitle: artist ?? "",
            coverArtId: coverArtId
        ))
    }

    /// Long-press menu for playlists: Play / Pin to Home (loads tracks on demand).
    func playlistLongPressMenu(
        id: String,
        name: String,
        coverArtId: String? = nil
    ) -> some View {
        modifier(PlaylistLongPressMenuModifier(
            playlistId: id,
            displayName: name,
            coverArtId: coverArtId
        ))
    }

    /// Long-press menu for artists: Play / Pin to Home / Favorite.
    func artistLongPressMenu(_ artist: ArtistID3) -> some View {
        modifier(ArtistLongPressMenuModifier(
            artistId: artist.id,
            displayName: artist.name,
            coverArtId: artist.coverArt
        ))
    }

    /// Long-press pin/play menu for a song tile (favorites shelf, etc.).
    func songLongPressMenu(_ song: DisplayableSong) -> some View {
        modifier(SongLongPressMenuModifier(song: song))
    }
}

// MARK: - Convenience long-press modifiers

private struct AlbumLongPressMenuModifier: ViewModifier {
    let albumId: String
    let displayName: String
    let displaySubtitle: String
    let coverArtId: String?

    @Environment(\.appContainer) private var container

    func body(content: Content) -> some View {
        content.lazyCollectionContextMenu(
            itemType: .album,
            itemId: albumId,
            displayName: displayName,
            displaySubtitle: displaySubtitle,
            coverArtId: coverArtId,
            favoriteType: .album,
            songLoader: {
                guard let c = container else { return [] }
                let loaded = try await c.libraryService.displayAlbum(id: albumId)
                return (loaded.song ?? []).map { DisplayableSong(from: $0, isDownloaded: false) }
            }
        )
    }
}

private struct PlaylistLongPressMenuModifier: ViewModifier {
    let playlistId: String
    let displayName: String
    let coverArtId: String?

    @Environment(\.appContainer) private var container

    func body(content: Content) -> some View {
        content.lazyCollectionContextMenu(
            itemType: .playlist,
            itemId: playlistId,
            displayName: displayName,
            displaySubtitle: "",
            coverArtId: coverArtId,
            favoriteType: nil,
            songLoader: {
                guard let c = container else { return [] }
                let loaded = try await c.libraryService.playlist(id: playlistId)
                return (loaded.entry ?? []).map { DisplayableSong(from: $0, isDownloaded: false) }
            }
        )
    }
}

private struct ArtistLongPressMenuModifier: ViewModifier {
    let artistId: String
    let displayName: String
    let coverArtId: String?

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var coverImage: PlatformImage?

    func body(content: Content) -> some View {
        content
            .lazyCollectionContextMenu(
                itemType: .artist,
                itemId: artistId,
                displayName: displayName,
                displaySubtitle: "",
                coverArtId: coverArtId,
                coverImage: coverImage,
                favoriteType: .artist,
                songLoader: {
                    guard let c = container else { return [] }
                    let artist = try await c.libraryService.artist(id: artistId)
                    var songs: [DisplayableSong] = []
                    for album in (artist.album ?? []).prefix(5) {
                        let detail = try await c.libraryService.album(id: album.id)
                        songs.append(contentsOf: (detail.song ?? []).map { DisplayableSong(from: $0) })
                        if songs.count >= 40 { break }
                    }
                    return songs
                }
            )
            .task(id: coverArtId ?? artistId) {
                let id = coverArtId ?? artistId
                if let image = await artworkImageCache.load(coverArtId: id, tier: .hero) {
                    coverImage = image
                } else if let image = await artworkImageCache.load(coverArtId: id, tier: .thumb) {
                    coverImage = image
                }
            }
    }
}

private struct SongLongPressMenuModifier: ViewModifier {
    let song: DisplayableSong

    func body(content: Content) -> some View {
        content.songContextMenu(song: song)
    }
}
