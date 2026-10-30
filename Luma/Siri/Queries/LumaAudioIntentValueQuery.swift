// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation
import MediaIntents

/// Bridges `AudioSearch` — the structured form of a Siri audio request — to
/// Luma's catalog. Returns the union `LumaAudioItem` so a single query
/// covers songs, albums, artists, and playlists.
///
/// Mirrors Apple's CosmoTunes `AudioIntentValueQuery` (WWDC26 session 343).
@available(iOS 27.0, macOS 27.0, *)
extension LumaAudioItem {
    struct AudioIntentValueQuery {
        func values(for input: AudioSearch) async throws -> [LumaAudioItem] {
            await SiriBridge.waitUntilReady()
            switch input.criteria {
            case .searchQuery(let query):
                return try await searchResults(for: query)
            case .url(let urls):
                return await results(for: urls)
            case .unspecified:
                return await suggestedResults()
            @unknown default:
                return []
            }
        }

        private func searchResults(for query: String) async throws -> [LumaAudioItem] {
            guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
            let identity = await SiriBridge.catalogIdentityProvider?()
            async let songResults = catalog.songs(matching: query, limit: 10)
            async let albumResults = catalog.albums(matching: query, limit: 5)
            async let artistResults = catalog.artists(matching: query, limit: 5)
            async let playlistResults = catalog.playlists(matching: query, limit: 5)
            async let nativeResults = LumaNativeSearch.shared.search(query, limit: 25)
            let (songs, albums, artists, playlists, native) = await (songResults, albumResults, artistResults, playlistResults, nativeResults)
            try Task.checkCancellation()
            guard identity == (await SiriBridge.catalogIdentityProvider?()) else { throw CancellationError() }
            var result = songs.map(LumaAudioItem.song)
                + albums.map(LumaAudioItem.album)
                + artists.map(LumaAudioItem.artist)
                + playlists.map(LumaAudioItem.playlist)
            if let native, let identity {
                let semantic = await MainActor.run {
                    native.songs.prefix(10).map { LumaAudioItem.song(LumaSongEntity(song: $0, serverId: identity.serverID)) }
                    + native.albums.prefix(5).map { LumaAudioItem.album(LumaAlbumEntity(
                        id: LumaEntityID(serverId: identity.serverID, localId: $0.id).rawValue,
                        title: $0.name, artistName: LumaEntityDisplay.artistName($0.artist))) }
                    + native.artists.prefix(5).map { LumaAudioItem.artist(LumaArtistEntity(
                        id: LumaEntityID(serverId: identity.serverID, localId: $0.id).rawValue, name: $0.name)) }
                    + native.playlists.prefix(5).map { LumaAudioItem.playlist(LumaPlaylistEntity(
                        id: LumaEntityID(serverId: identity.serverID, localId: $0.id).rawValue, title: $0.name)) }
                }
                result += semantic
            }
            guard identity == (await SiriBridge.catalogIdentityProvider?()) else { throw CancellationError() }
            let candidates = result
            return await MainActor.run {
                var seen = Set<String>()
                return candidates.filter { item in
                    let kind: String
                    switch item { case .song: kind = "song"; case .album: kind = "album"; case .artist: kind = "artist"; case .playlist: kind = "playlist" }
                    return seen.insert(kind + ":" + (item.entityID?.rawValue ?? "")).inserted
                }
            }
        }

        private func suggestedResults() async -> [LumaAudioItem] {
            guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
            return await catalog.suggestedSongs(limit: 10).map(LumaAudioItem.song)
        }

        private func results(for urls: [URL]) async -> [LumaAudioItem] {
            guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
            var items: [LumaAudioItem] = []
            for url in urls {
                guard let ref = LumaDeepLink.parse(url) else { continue }
                switch ref.kind {
                case .song:
                    if let song = await catalog.song(id: ref.id) { items.append(.song(song)) }
                case .album:
                    if let album = await catalog.album(id: ref.id) { items.append(.album(album)) }
                case .artist:
                    if let artist = await catalog.artist(id: ref.id) { items.append(.artist(artist)) }
                case .playlist:
                    if let playlist = await catalog.playlist(id: ref.id) { items.append(.playlist(playlist)) }
                }
            }
            return items
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension LumaAudioItem.AudioIntentValueQuery: IntentValueQuery {}
