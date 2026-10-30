// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents

/// The item a schema intent acts on.
///
/// The `.audio` domain types `audioEntity` (and `target`) as a union; the case
/// names must match the schema's `AudioItem` cases. Luma supports the four
/// content types it can actually play or modify: song, album, artist, playlist.
@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum LumaAudioItem {
    case song(LumaSongEntity)
    case album(LumaAlbumEntity)
    case artist(LumaArtistEntity)
    case playlist(LumaPlaylistEntity)

    /// Human-readable label used in Siri dialogs.
    var title: String {
        switch self {
        case .song(let song): return song.title
        case .album(let album): return album.title
        case .artist(let artist): return artist.name
        case .playlist(let playlist): return playlist.title
        }
    }

    /// Server scope of the wrapped entity.
    var entityID: LumaEntityID? {
        switch self {
        case .song(let song): return LumaEntityID(rawValue: song.id)
        case .album(let album): return LumaEntityID(rawValue: album.id)
        case .artist(let artist): return LumaEntityID(rawValue: artist.id)
        case .playlist(let playlist): return LumaEntityID(rawValue: playlist.id)
        }
    }
}
