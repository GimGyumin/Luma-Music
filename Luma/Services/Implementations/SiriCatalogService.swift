// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic
import CoreSpotlight
import AppIntents
import OSLog

/// Siri-facing catalog facade.
///
/// Search is **local-first** so a Siri request never blocks on a full library
/// fetch: songs come from `LibraryMetadataStore` (persistent, warmed on every
/// search), albums/artists/playlists from the existing in-memory
/// `LibraryIndexService`, with `search3`/server endpoints as the fallback.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class SiriCatalogService: SiriCatalogServiceProtocol {
    private let libraryService: any LibraryServiceProtocol
    private let metadataStore: LibraryMetadataStore
    private let libraryIndex: LibraryIndexService
    private let serverState: ServerState
    private let mediaIdentityService: MediaIdentityService?
    private var metadataScope: String?
    private var remoteSearchCache: (key: String, fetchedAt: Date, result: SearchResult3)?
    private var inFlightRemoteSearch: (key: String, task: Task<SearchResult3?, Never>)?

    private static let remoteSearchCacheLifetime: TimeInterval = 15

    init(
        libraryService: any LibraryServiceProtocol,
        metadataStore: LibraryMetadataStore,
        libraryIndex: LibraryIndexService,
        serverState: ServerState,
        mediaIdentityService: MediaIdentityService? = nil
    ) {
        self.libraryService = libraryService
        self.metadataStore = metadataStore
        self.libraryIndex = libraryIndex
        self.serverState = serverState
        self.mediaIdentityService = mediaIdentityService
    }

    private func resolveServerId() async -> UUID? {
        await SiriBootGate.waitUntilReady()
        guard !serverState.isSigningOut, let account = serverState.activeServer else { return nil }
        let scope = SpotlightRecord.scope(serverID: account.id, address: account.baseURL, username: account.username)
        if metadataScope != scope {
            let key = "luma.siri.metadataScope." + account.id.uuidString
            if let previous = UserDefaults.standard.string(forKey: key), previous != scope {
                metadataStore.clear(serverId: account.id)
            }
            UserDefaults.standard.set(scope, forKey: key)
            inFlightRemoteSearch?.task.cancel()
            inFlightRemoteSearch = nil
            remoteSearchCache = nil
            metadataScope = scope
        }
        return account.id
    }

    /// Entity identifiers are scoped to a server. Never resolve an identifier
    /// from an old account against the currently active server.
    private func isActive(_ id: LumaEntityID) async -> Bool {
        await resolveServerId() == id.serverId
    }

    /// A single AudioSearch asks for songs, albums, and artists separately. Coalesce
    /// those lookups so one spoken query produces one `search3` request, not three.
    private func remoteSearch(_ query: String, serverId: UUID) async -> SearchResult3? {
        guard serverState.isOnline, serverState.isServerReachable else { return nil }
        let normalized = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let revision = serverState.accountRevision
        let key = "\(serverId.uuidString):\(revision):\(normalized)"
        if let cached = remoteSearchCache,
           cached.key == key,
           Date().timeIntervalSince(cached.fetchedAt) < Self.remoteSearchCacheLifetime {
            return cached.result
        }
        if let inFlightRemoteSearch, inFlightRemoteSearch.key == key {
            let value = await inFlightRemoteSearch.task.value
            guard serverState.activeServer?.id == serverId, serverState.accountRevision == revision else { return nil }
            return value
        }

        let task = Task { [libraryService] in
            try? await libraryService.search(query)
        }
        inFlightRemoteSearch = (key, task)
        let result = await task.value
        guard serverState.activeServer?.id == serverId, serverState.accountRevision == revision else { return nil }
        if inFlightRemoteSearch?.key == key { inFlightRemoteSearch = nil }
        if let result { remoteSearchCache = (key, Date(), result) }
        return result
    }

    // MARK: - Songs

    func songs(matching query: String, limit: Int) async -> [LumaSongEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        let revision = serverState.accountRevision
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        libraryIndex.ensureIndexed(using: libraryService)
        let local = await libraryIndex.searchInBackground(query: q, limit: limit)
        guard serverState.activeServer?.id == serverId, serverState.accountRevision == revision else { return [] }
        var seenLocal = Set<String>()
        var songs = (local.songs + metadataStore.matching(q, serverId: serverId, limit: limit))
            .filter { seenLocal.insert($0.id).inserted }

        // `search3` is authoritative for a query. Always merge it so a thin or
        // partially-warmed local cache can't fill the page with weak matches and push
        // the requested track out (or suppress the fallback entirely). Server hits go
        // first, then local hits fill any remaining slots.
        if let remote = await remoteSearch(q, serverId: serverId)?.song {
            let mapped = remote.map { DisplayableSong(from: $0) }
            metadataStore.upsert(mapped, serverId: serverId)
            var seen = Set<String>()
            var merged: [DisplayableSong] = []
            for song in mapped + songs {
                guard !seen.contains(song.id) else { continue }
                seen.insert(song.id)
                merged.append(song)
            }
            // Never trust server order as the final Siri choice. Rank fresh and cached
            // candidates together so album words and unrequested variant suffixes count.
            songs = merged.enumerated().sorted { lhs, rhs in
                let lhsScore = SiriSongSearchRanker.score(lhs.element, query: q)
                let rhsScore = SiriSongSearchRanker.score(rhs.element, query: q)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }

        guard serverState.activeServer?.id == serverId, serverState.accountRevision == revision else { return [] }
        let entities = songs
            .prefix(limit)
            .map { LumaSongEntity(song: $0, serverId: serverId, loadRelations: true) }
        return entities
    }

    /// Genre/year/file-format search over the already-prepared library index and
    /// the persistent metadata cache. Only a genre request asks the server for a
    /// bounded `getSongsByGenre` page; no full-library download is performed.
    func songs(filteredBy query: LibrarySongQuery, limit: Int) async -> [LumaSongEntity] {
        guard query.hasCriteria else { return [] }
        guard let serverId = await resolveServerId() else { return [] }
        let revision = serverState.accountRevision
        let capped = max(1, min(limit, 100))

        libraryIndex.ensureIndexed(using: libraryService)
        var candidates: [DisplayableSong] = libraryIndex.searchableSnapshot?.songs ?? []
        candidates += metadataStore.filtered(query, serverId: serverId, limit: capped * 8)

        if let genre = query.genre, serverState.isOnline, serverState.isServerReachable {
            if let remote = try? await libraryService.songsByGenre(genre, count: max(100, capped * 4)) {
                guard serverState.activeServer?.id == serverId, serverState.accountRevision == revision else { return [] }
                metadataStore.upsert(remote, serverId: serverId)
                candidates += remote
            }
        }

        if let text = query.text, !text.isEmpty, serverState.isOnline, serverState.isServerReachable,
           let remote = await remoteSearch(text, serverId: serverId)?.song {
            guard serverState.activeServer?.id == serverId, serverState.accountRevision == revision else { return [] }
            let mapped = remote.map { DisplayableSong(from: $0) }
            metadataStore.upsert(mapped, serverId: serverId)
            candidates += mapped
        }

        guard serverState.activeServer?.id == serverId, serverState.accountRevision == revision else { return [] }
        var seen = Set<String>()
        var matches: [DisplayableSong] = []
        for song in candidates where query.matches(song) {
            guard seen.insert(song.id).inserted else { continue }
            matches.append(song)
        }
        if let text = query.text, !text.isEmpty {
            matches.sort { lhs, rhs in
                let left = SiriSongSearchRanker.score(lhs, query: text)
                let right = SiriSongSearchRanker.score(rhs, query: text)
                if left != right { return left > right }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        } else {
            matches.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return matches.prefix(capped).map {
            LumaSongEntity(song: $0, serverId: serverId, loadRelations: true)
        }
    }

    func song(id: LumaEntityID) async -> LumaSongEntity? {
        guard await isActive(id) else { return nil }
        let revision = serverState.accountRevision
        let currentID = mediaIdentityService?.resolveCurrentID(id.localId, serverId: id.serverId, entityType: .song) ?? id.localId
        if let song = libraryIndex.searchableSnapshot?.songs.first(where: { $0.id == currentID })
            ?? metadataStore.song(id: id.localId, serverId: id.serverId)
            ?? metadataStore.song(id: currentID, serverId: id.serverId) {
            return LumaSongEntity(song: song, serverId: id.serverId, loadRelations: true)
        }
        guard let remote = try? await libraryService.song(id: currentID),
              serverState.activeServer?.id == id.serverId, serverState.accountRevision == revision else { return nil }
        let song = DisplayableSong(from: remote)
        metadataStore.upsert([song], serverId: id.serverId)
        return LumaSongEntity(song: song, serverId: id.serverId, loadRelations: true)
    }

    // MARK: - Albums

    func albums(matching query: String, limit: Int) async -> [LumaAlbumEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        let revision = serverState.accountRevision
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

        libraryIndex.ensureIndexed(using: libraryService)
        let localHits = await libraryIndex.searchInBackground(query: q, limit: limit)
        var results = localHits.albums.map {
            LumaAlbumEntity(
                id: LumaEntityID(serverId: serverId, localId: $0.id).rawValue,
                title: $0.name,
                artistName: LumaEntityDisplay.artistName($0.artist),
                artists: $0.artist.map { [LumaArtistEntity(serverId: serverId, name: $0)] } ?? []
            )
        }

        if results.count < limit {
            if let remote = await remoteSearch(q, serverId: serverId)?.album {
                let seen = Set(results.map(\.id))
                results += remote.compactMap { album in
                    let entity = LumaAlbumEntity(album: album, serverId: serverId, loadRelations: false)
                    return seen.contains(entity.id) ? nil : entity
                }
            }
        }
        guard serverState.activeServer?.id == serverId, serverState.accountRevision == revision else { return [] }
        let entities = Array(results.prefix(limit))
        return entities
    }

    func album(id: LumaEntityID) async -> LumaAlbumEntity? {
        guard await isActive(id) else { return nil }
        let revision = serverState.accountRevision
        let currentID = mediaIdentityService?.resolveCurrentID(id.localId, serverId: id.serverId, entityType: .album) ?? id.localId
        if let album = libraryIndex.searchableSnapshot?.albums.first(where: { $0.id == currentID }) {
            return LumaAlbumEntity(id: id.rawValue, title: album.name, artistName: LumaEntityDisplay.artistName(album.artist))
        }
        guard let album = try? await libraryService.album(id: currentID),
              serverState.activeServer?.id == id.serverId, serverState.accountRevision == revision else { return nil }
        return LumaAlbumEntity(album: album, serverId: id.serverId, loadRelations: false)
    }
    // MARK: - Artists

    func artists(matching query: String, limit: Int) async -> [LumaArtistEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        let revision = serverState.accountRevision
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

        libraryIndex.ensureIndexed(using: libraryService)
        let localHits = await libraryIndex.searchInBackground(query: q, limit: limit)
        var results = localHits.artists.map {
            LumaArtistEntity(
                id: LumaEntityID(serverId: serverId, localId: $0.id).rawValue,
                name: $0.name
            )
        }

        if results.count < limit {
            if let remote = await remoteSearch(q, serverId: serverId)?.artist {
                let seen = Set(results.map(\.id))
                results += remote.compactMap { artist in
                    let entity = LumaArtistEntity(artist: artist, serverId: serverId)
                    return seen.contains(entity.id) ? nil : entity
                }
            }
        }
        guard serverState.activeServer?.id == serverId, serverState.accountRevision == revision else { return [] }
        let entities = Array(results.prefix(limit))
        return entities
    }

    func artist(id: LumaEntityID) async -> LumaArtistEntity? {
        guard await isActive(id) else { return nil }
        let revision = serverState.accountRevision
        let currentID = mediaIdentityService?.resolveCurrentID(id.localId, serverId: id.serverId, entityType: .artist) ?? id.localId
        if let artist = libraryIndex.searchableSnapshot?.artists.first(where: { $0.id == currentID }) {
            return LumaArtistEntity(id: id.rawValue, name: artist.name)
        }
        guard let artist = try? await libraryService.artist(id: currentID),
              serverState.activeServer?.id == id.serverId, serverState.accountRevision == revision else { return nil }
        return LumaArtistEntity(artist: artist, serverId: id.serverId)
    }

    // MARK: - Playlists

    func playlists(matching query: String, limit: Int) async -> [LumaPlaylistEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        let revision = serverState.accountRevision
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

        libraryIndex.ensureIndexed(using: libraryService)
        let localHits = await libraryIndex.searchInBackground(query: q, limit: limit)
        var results = localHits.playlists.map {
            LumaPlaylistEntity(
                id: LumaEntityID(serverId: serverId, localId: $0.id).rawValue,
                title: $0.name
            )
        }

        if results.count < limit {
            if let remote = try? await libraryService.playlists() {
                let seen = Set(results.map(\.id))
                results += remote
                    .filter { $0.name.localizedCaseInsensitiveContains(q) }
                    .prefix(limit)
                    .compactMap { playlist in
                        let entity = LumaPlaylistEntity(playlist: playlist, serverId: serverId)
                        return seen.contains(entity.id) ? nil : entity
                    }
            }
        }
        guard serverState.activeServer?.id == serverId, serverState.accountRevision == revision else { return [] }
        let entities = Array(results.prefix(limit))
        return entities
    }

    func playlist(id: LumaEntityID) async -> LumaPlaylistEntity? {
        guard await isActive(id) else { return nil }
        let revision = serverState.accountRevision
        let currentID = mediaIdentityService?.resolveCurrentID(id.localId, serverId: id.serverId, entityType: .playlist) ?? id.localId
        if let playlist = libraryIndex.searchableSnapshot?.playlists.first(where: { $0.id == currentID }) {
            return LumaPlaylistEntity(id: id.rawValue, title: playlist.name, trackCount: playlist.trackCount ?? 0)
        }
        guard let playlists = try? await libraryService.playlists(),
              serverState.activeServer?.id == id.serverId, serverState.accountRevision == revision else { return nil }
        guard let playlist = playlists.first(where: { $0.id == currentID }) else { return nil }
        return LumaPlaylistEntity(playlist: playlist, serverId: id.serverId)
    }

    // MARK: - Suggestions (open-ended "play some music")

    func suggestedSongs(limit: Int) async -> [LumaSongEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        let revision = serverState.accountRevision

        // Prefer songs the person already endorsed; fall back to random.
        let songs: [Song]
        if let starred = try? await libraryService.getStarred2().song, !starred.isEmpty {
            songs = Array(starred.prefix(limit))
        } else {
            songs = (try? await libraryService.randomSongs(size: limit)) ?? []
        }

        guard serverState.activeServer?.id == serverId, serverState.accountRevision == revision else { return [] }
        let mapped = songs.map { DisplayableSong(from: $0) }
        metadataStore.upsert(mapped, serverId: serverId)
        return mapped.prefix(limit).map {
            LumaSongEntity(song: $0, serverId: serverId, loadRelations: true)
        }
    }

    // MARK: - Playback resolution

    func playableSong(id: LumaEntityID) async -> DisplayableSong? {
        guard await isActive(id) else { return nil }
        let revision = serverState.accountRevision
        let currentID = mediaIdentityService?.resolveCurrentID(id.localId, serverId: id.serverId, entityType: .song) ?? id.localId
        if let song = libraryIndex.searchableSnapshot?.songs.first(where: { $0.id == currentID })
            ?? metadataStore.song(id: id.localId, serverId: id.serverId)
            ?? metadataStore.song(id: currentID, serverId: id.serverId) {
            return song
        }
        guard let remote = try? await libraryService.song(id: currentID),
              serverState.activeServer?.id == id.serverId, serverState.accountRevision == revision else { return nil }
        let song = DisplayableSong(from: remote)
        metadataStore.upsert([song], serverId: id.serverId)
        return song
    }

    /// Full SwiftSonic `Song` record, used by playlist additions.
    func songRecord(id: LumaEntityID) async -> Song? {
        guard await isActive(id) else { return nil }
        let revision = serverState.accountRevision
        let currentID = mediaIdentityService?.resolveCurrentID(id.localId, serverId: id.serverId, entityType: .song) ?? id.localId
        let value = try? await libraryService.song(id: currentID)
        guard serverState.activeServer?.id == id.serverId, serverState.accountRevision == revision else { return nil }
        return value
    }

    // Local listings never issue another full-library request during Siri resolution.
    func allSongs(limit: Int) async -> [LumaSongEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        return (libraryIndex.searchableSnapshot?.songs ?? []).prefix(max(0, limit)).map {
            LumaSongEntity(song: $0, serverId: serverId, loadRelations: true)
        }
    }
    func allAlbums(limit: Int) async -> [LumaAlbumEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        return (libraryIndex.searchableSnapshot?.albums ?? []).prefix(max(0, limit)).map {
            LumaAlbumEntity(id: LumaEntityID(serverId: serverId, localId: $0.id).rawValue,
                title: $0.name, artistName: LumaEntityDisplay.artistName($0.artist))
        }
    }
    func allArtists(limit: Int) async -> [LumaArtistEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        return (libraryIndex.searchableSnapshot?.artists ?? []).prefix(max(0, limit)).map {
            LumaArtistEntity(id: LumaEntityID(serverId: serverId, localId: $0.id).rawValue, name: $0.name)
        }
    }
    func allPlaylists(limit: Int) async -> [LumaPlaylistEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        return (libraryIndex.searchableSnapshot?.playlists ?? []).prefix(max(0, limit)).map {
            LumaPlaylistEntity(id: LumaEntityID(serverId: serverId, localId: $0.id).rawValue,
                title: $0.name, trackCount: $0.trackCount ?? 0)
        }
    }

    func playableSongs(inAlbum id: LumaEntityID) async -> [DisplayableSong] {
        guard await isActive(id) else { return [] }
        let revision = serverState.accountRevision
        guard let album = try? await libraryService.album(id: id.localId),
              serverState.activeServer?.id == id.serverId, serverState.accountRevision == revision else { return [] }
        return (album.song ?? []).map { DisplayableSong(from: $0) }
    }

    func playableSongs(byArtist id: LumaEntityID) async -> [DisplayableSong] {
        guard await isActive(id) else { return [] }
        let revision = serverState.accountRevision
        let tracks = (try? await libraryService.fetchAllTracks(forArtistID: id.localId)) ?? []
        guard serverState.activeServer?.id == id.serverId, serverState.accountRevision == revision else { return [] }
        return tracks
    }

    func playableSongs(inPlaylist id: LumaEntityID) async -> [DisplayableSong] {
        guard await isActive(id) else { return [] }
        let revision = serverState.accountRevision
        guard let playlist = try? await libraryService.playlist(id: id.localId),
              serverState.activeServer?.id == id.serverId, serverState.accountRevision == revision else { return [] }
        return (playlist.entry ?? []).map { DisplayableSong(from: $0) }
    }

    // Reuse the existing local sync; no second, truncated 1,000-song HTTP scan.
    func warmLibraryForSiri() async {
        libraryIndex.ensureIndexed(using: libraryService)
        if let snapshot = libraryIndex.searchableSnapshot, let id = serverState.activeServer?.id {
            LumaNativeSearch.shared.accept(snapshot, serverID: id)
        }
    }
}
