// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftSonic

/// Lightweight local catalog index for faster search + AI context.
/// Persists songs, artists, albums and playlists per server; search never needs a catalog request.
@MainActor
@Observable
final class LibraryIndexService {
    private(set) var isIndexing = false
    private(set) var lastIndexedAt: Date?
    private(set) var entryCount = 0
    private(set) var progress: Double = 0
    private(set) var isPreparing = false
    private(set) var lastError: UserFacingError?
    private(set) var lastBuildSucceeded = false
    var hasUsableIndex: Bool { lastIndexedAt != nil && loadedServerID == serverID() && installedRevision == accountRevision() }

    private var artists: [IndexedArtist] = []
    private var albums: [IndexedAlbum] = []
    private var playlists: [IndexedPlaylist] = []
    private var songs: [DisplayableSong] = []
    private var variants = AtmosVariantCatalogue()
    private var detailVariants: [String: AtmosVariantCatalogue] = [:]
    private var detailServerID: UUID?
    @ObservationIgnored private let defaults: UserDefaults

    func presentedAlbums(_ values: [AlbumID3]) -> [AlbumID3] {
        if loadedServerID == serverID(), lastIndexedAt != nil { return variants.presented(values) }
        return AtmosAlbumPolicy.presented(values)
    }

    func variantAlbums(for album: AlbumID3) -> [AlbumID3] {
        guard loadedServerID == serverID() else { return [] }
        let baseID = variants.albumPairs[album.id] ?? album.id
        return variants.albums.filter { $0.id == baseID || variants.albumPairs[$0.id] == baseID }
    }

    func primaryAlbumID(for id: String) -> String {
        guard loadedServerID == serverID() else { return id }
        return variants.albumPairs[id] ?? id
    }

    func playbackCoverID(for song: DisplayableSong) -> String {
        if let explicit = song.explicitCoverArtId { return explicit }
        if loadedServerID == serverID(), loadedServerID != nil {
            if let cover = variants.songsByID[song.id]?.explicitCoverArtId { return cover }
            if let cover = variants.coverArtID(forAlbumID: song.albumId) { return cover }
        }
        if detailServerID == serverID(), detailServerID != nil, let albumID = song.albumId,
           let catalog = detailVariants[albumID] {
            if let cover = catalog.songsByID[song.id]?.explicitCoverArtId { return cover }
            if let cover = catalog.coverArtID(forAlbumID: albumID) { return cover }
        }
        return song.effectiveCoverArtId
    }

    func preferredAtmosSong(for song: DisplayableSong, serverId: UUID) -> DisplayableSong? {
        guard serverId == serverID() else { return nil }
        let overrides = defaults.dictionary(forKey: Self.manualKey(serverId)) as? [String: String] ?? [:]
        if let id = overrides[song.id] {
            let candidate = (loadedServerID == serverId ? variants.songsByID[id] : nil)
                ?? (detailServerID == serverId ? detailVariants.values.compactMap { $0.songsByID[id] }.first : nil)
            guard let candidate, AtmosVariantCatalogue.isAtmos(candidate) else { return nil }
            return candidate
        }
        if detailServerID == serverId, let album = song.albumId,
           let candidate = detailVariants[album]?.preferred(for: song) { return candidate }
        return loadedServerID == serverId ? variants.preferred(for: song) : nil
    }

    func registerAlbumVersions(_ albums: [AlbumID3], serverId: UUID) async {
        guard serverId == serverID() else { return }
        let token = generation
        let revision = accountRevision()
        let worker = Task.detached(priority: .utility) {
            AtmosVariantCatalogue(songs: albums.flatMap { ($0.song ?? []).map { DisplayableSong(from: $0) } }, albums: albums)
        }
        let catalog = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard token == generation, revision == accountRevision(), serverId == serverID(), !Task.isCancelled else { return }
        if detailServerID != serverId { detailVariants = [:]; detailServerID = serverId }
        for album in albums { detailVariants[album.id] = catalog }
    }

    func atmosCandidates(for song: DisplayableSong, serverId: UUID) async -> [DisplayableSong] {
        guard serverId == serverID() else { return [] }
        let token = generation
        let revision = accountRevision()
        let snapshots = (loadedServerID == serverId ? [variants] : [])
            + (detailServerID == serverId ? Array(detailVariants.values) : [])
        let worker = Task.detached(priority: .userInitiated) {
            Dictionary(snapshots.flatMap { $0.manualCandidates(for: song) }.map { ($0.id, $0) }, uniquingKeysWith: { _, song in song })
                .values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        let candidates = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard token == generation, revision == accountRevision(), serverId == serverID(), !Task.isCancelled else { return [] }
        return candidates
    }

    func manualAtmosSelection(songId: String, serverId: UUID) -> String? {
        guard serverId == serverID() else { return nil }
        return (defaults.dictionary(forKey: Self.manualKey(serverId)) as? [String: String])?[songId]
    }

    /// nil = automatic, empty string = original only, ID = an explicit user selection.
    func setManualAtmosSelection(_ id: String?, for song: DisplayableSong, serverId: UUID) {
        guard serverId == serverID() else { return }
        if let id, !id.isEmpty {
            let candidate = (loadedServerID == serverId ? variants.songsByID[id] : nil)
                ?? (detailServerID == serverId ? detailVariants.values.compactMap { $0.songsByID[id] }.first : nil)
            guard let candidate, AtmosVariantCatalogue.isAtmos(candidate),
                  candidate.id != song.id,
                  AtmosAlbumPolicy.normalized(candidate.artist ?? "") == AtmosAlbumPolicy.normalized(song.artist ?? "") else { return }
        }
        let key = Self.manualKey(serverId)
        var overrides = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        overrides[song.id] = id
        defaults.set(overrides, forKey: key)
    }

    func clearAtmosSelections(serverId: UUID) { defaults.removeObject(forKey: Self.manualKey(serverId)) }
    private static func manualKey(_ serverId: UUID) -> String { "luma.atmos.matches.\(serverId.uuidString)" }
    /// Missing track artwork reuses the album; explicit alternate artwork stays distinct.
    var songArtworkSnapshot: [String: String] {
        Dictionary(songs.compactMap { song -> (String, String)? in
            // The album pass already owns the fallback artwork. Queue a track separately
            // only when it actually has its own artwork ID (or has no album to fall back to).
            guard song.explicitCoverArtId != nil || song.albumId == nil else { return nil }
            return ("song:\(song.id)", playbackCoverID(for: song))
        }, uniquingKeysWith: { _, new in new })
    }

    var albumArtworkSnapshot: [String: String] {
        Dictionary(albums.map { ($0.id, $0.coverArtId ?? $0.id) }, uniquingKeysWith: { _, new in new })
    }

    /// Resolve all browse cards in one background pass. View bodies must never scan the catalog.
    func browseCoverArtIDs(for genres: [String]) async -> [String: String] {
        let token = generation
        let locale = Locale.current
        let worker = Task.detached(priority: .utility) { [songs] in
            var remaining = genres.map { ($0, $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)) }
            var covers: [String: String] = [:]
            for song in songs {
                guard !Task.isCancelled else { return [:] as [String: String] }
                let value = (song.genre ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                guard !value.isEmpty else { continue }
                remaining.removeAll { genre, needle in
                    guard value.contains(needle) || needle.contains(value) else { return false }
                    covers[genre] = song.effectiveCoverArtId
                    return true
                }
                if remaining.isEmpty { break }
            }
            return covers
        }
        let covers = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard token == generation, !Task.isCancelled else { return [:] }
        return covers
    }
    private var songTokens: [[String]] = []
    private var artistTokens: [[String]] = []
    private var albumTokens: [[String]] = []
    private var playlistTokens: [[String]] = []
    private var generation: UInt64 = 0
    private var loadedServerID: UUID?
    private let serverID: @MainActor () -> UUID?
    private let networkAvailable: @MainActor () -> Bool
    private let directory: URL?
    private let accountRevision: @MainActor () -> UInt64
    private let cacheScope: @MainActor () -> String?
    private var installedRevision: UInt64?

    init(serverID: @escaping @MainActor () -> UUID? = { nil }, networkAvailable: @escaping @MainActor () -> Bool = { true }, directory: URL? = nil, defaults: UserDefaults = .standard, accountRevision: @escaping @MainActor () -> UInt64 = { 0 }, cacheScope: @escaping @MainActor () -> String? = { nil }) {
        self.serverID = serverID
        self.networkAvailable = networkAvailable
        self.directory = directory
        self.defaults = defaults
        self.accountRevision = accountRevision
        self.cacheScope = cacheScope
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.luma/library-index", isDirectory: true)
    }

    nonisolated struct Snapshot: Codable, Sendable {
        var artists: [IndexedArtist]
        var albums: [IndexedAlbum]
        var playlists: [IndexedPlaylist]
        var songs: [DisplayableSong]
        var date: Date
        var albumCatalog: [AlbumID3]? = nil
        var atmosMatches: [String: String]? = nil
        var atmosMatchingVersion: Int? = nil
    }

    @ObservationIgnored var onSnapshot: (@MainActor (Snapshot, UUID) -> Void)?
    @ObservationIgnored private var installedSnapshot: Snapshot?
    var searchableSnapshot: Snapshot? {
        guard loadedServerID == serverID(), installedRevision == accountRevision() else { return nil }
        return installedSnapshot
    }

    private var playlistRefreshTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var indexTaskServerID: UUID?
    private var indexTaskRevision: UInt64?
    private var persistedIndexDate: Date?
    private var catalogURL: URL? {
        serverID().flatMap { id in
            let suffix = cacheScope().map { "-" + $0 } ?? ""
            return directory?.appendingPathComponent("\(id)\(suffix).sqlite")
        }
    }

    nonisolated struct IndexedArtist: Sendable, Codable {
        let id: String
        let name: String
        let coverArtId: String?
    }

    nonisolated struct IndexedAlbum: Sendable, Codable {
        let id: String
        let name: String
        let artist: String?
        let artistId: String?
        let albumArtistIDs: [String]
        let relatedArtistIDs: [String]
        let relatedArtistNames: [String]
        let coverArtId: String?

        init(id: String, name: String, artist: String?, artistId: String? = nil, albumArtistIDs: [String] = [],
             relatedArtistIDs: [String] = [], relatedArtistNames: [String] = [], coverArtId: String?) {
            self.id = id
            self.name = name
            self.artist = artist
            self.artistId = artistId
            self.albumArtistIDs = albumArtistIDs
            self.relatedArtistIDs = relatedArtistIDs
            self.relatedArtistNames = relatedArtistNames
            self.coverArtId = coverArtId
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            artist = try values.decodeIfPresent(String.self, forKey: .artist)
            artistId = try values.decodeIfPresent(String.self, forKey: .artistId)
            albumArtistIDs = try values.decodeIfPresent([String].self, forKey: .albumArtistIDs) ?? []
            relatedArtistIDs = try values.decodeIfPresent([String].self, forKey: .relatedArtistIDs) ?? []
            relatedArtistNames = try values.decodeIfPresent([String].self, forKey: .relatedArtistNames) ?? []
            coverArtId = try values.decodeIfPresent(String.self, forKey: .coverArtId)
        }
    }

    nonisolated struct IndexedPlaylist: Sendable, Codable {
        let id: String
        let name: String
        let coverArtId: String?
        var summary: String? = nil
        var trackCount: Int? = nil
        var owner: String? = nil
    }

    nonisolated struct LocalHits: Sendable {
        var artists: [IndexedArtist]
        var albums: [IndexedAlbum]
        var playlists: [IndexedPlaylist]
        var songs: [DisplayableSong] = []
        var relatedIDs: Set<String> = []
        var rankedIDs: [String] = []
        var suggestions: [String] = []
        var isEmpty: Bool { artists.isEmpty && albums.isEmpty && playlists.isEmpty && songs.isEmpty }
    }

    /// Rebuilds the in-memory index. Safe to call repeatedly; overlapping runs are cancelled.
    func rebuild(using library: any LibraryServiceProtocol) {
        startIndexTask(using: library, refreshExisting: true)
    }

    private func startIndexTask(using library: any LibraryServiceProtocol, refreshExisting: Bool) {
        indexTask?.cancel()
        generation &+= 1
        isPreparing = true
        lastError = nil
        lastBuildSucceeded = false
        let token = generation
        let revision = accountRevision()
        indexTaskServerID = serverID()
        indexTaskRevision = revision
        indexTask = Task { [weak self] in
            await self?.runRebuild(using: library, token: token, revision: revision, refreshExisting: refreshExisting)
        }
    }

    func clear() {
        playlistRefreshTask?.cancel()
        playlistRefreshTask = nil
        installedSnapshot = nil; installedRevision = nil
        variants = AtmosVariantCatalogue()
        detailVariants = [:]
        detailServerID = nil
        indexTask?.cancel()
        indexTask = nil
        indexTaskServerID = nil
        generation &+= 1
        // Logout clears every account; keep no persisted catalog from a previously selected server.
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Logger.library.error("Unable to clear stored library indexes: \(error, privacy: .public)") }
        }
        loadedServerID = nil
        persistedIndexDate = nil
        songs = []
        songTokens = []
        artistTokens = []; albumTokens = []; playlistTokens = []
        artists = []
        albums = []
        playlists = []
        entryCount = 0
        lastIndexedAt = nil
        isIndexing = false
        progress = 0
        isPreparing = false
        lastError = nil
        lastBuildSucceeded = false
    }

    /// Playlist mutations refresh only that endpoint, not all library songs.
    /// Wait for an existing full sync so its older response cannot overwrite this edit.
    func refreshPlaylistMetadata(using service: any PlaylistServiceProtocol) {
        playlistRefreshTask?.cancel()
        let revision = accountRevision(), server = serverID()
        playlistRefreshTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                await self.indexTask?.value
                guard revision == self.accountRevision(), server == self.serverID(),
                      var snapshot = self.searchableSnapshot else { return }
                let token = self.generation
                let list = try await service.listPlaylists()
                snapshot.playlists = list.map {
                    IndexedPlaylist(id: $0.id, name: $0.name, coverArtId: $0.coverArt,
                        summary: $0.comment, trackCount: $0.songCount, owner: $0.owner)
                }
                snapshot.date = Date()
                let updated = snapshot, file = self.catalogURL
                let prepared = try await Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    let tokens = updated.playlists.map { HangulRomanization.searchTokens($0.name) }
                    var staged: URL?
                    if let file {
                        let output = file.deletingLastPathComponent().appendingPathComponent(".catalog-\(UUID()).sqlite")
                        do {
                            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.copyItem(at: file, to: output) }
                            try LibraryCatalogStore.save(updated, to: output)
                            staged = output
                        } catch { StagedFileWrite.discard(output); throw error }
                    }
                    return (tokens, staged)
                }.value
                defer { if let staged = prepared.1 { StagedFileWrite.discard(staged) } }
                guard !Task.isCancelled, token == self.generation, revision == self.accountRevision(), server == self.serverID() else { return }
                if let staged = prepared.1, let file { try StagedFileWrite.commit(staged, to: file) }
                self.installedSnapshot = updated
                self.playlists = updated.playlists
                self.playlistTokens = prepared.0
                self.lastIndexedAt = updated.date
                if file != nil { self.persistedIndexDate = updated.date }
                self.entryCount = self.artists.count + self.albums.count + self.playlists.count + self.songs.count
                if let server { self.onSnapshot?(updated, server) }
            } catch is CancellationError {
            } catch { Logger.library.error("Playlist metadata refresh failed") }
        }
    }

    /// Awaits a full index rebuild, updating progress as each catalog phase completes.
    /// Used by the onboarding preparation screen.
    @discardableResult
    func rebuildAndWait(using library: any LibraryServiceProtocol) async -> Bool {
        rebuild(using: library)
        await indexTask?.value
        return lastBuildSucceeded
    }

    /// Restore a persisted index silently. Fetch the catalog only when no usable index exists;
    /// confirmed library changes and explicit refreshes use `rebuild` instead.
    func ensureIndexed(using library: any LibraryServiceProtocol) {
        if loadedServerID == serverID(), installedRevision == accountRevision(), lastIndexedAt != nil { return }
        if indexTask != nil, indexTaskServerID == serverID(), indexTaskRevision == accountRevision() { return }
        if lastError != nil, loadedServerID == serverID(), indexTaskRevision == accountRevision() { return }
        startIndexTask(using: library, refreshExisting: false)
    }

    @discardableResult
    func ensureIndexedAndWait(using library: any LibraryServiceProtocol) async -> Bool {
        ensureIndexed(using: library)
        await indexTask?.value
        return hasUsableIndex
    }

    /// Loads the account-scoped SQLite snapshot without requiring a network refresh.
    /// Spotlight may ask the app to reindex before the normal UI boot path restores memory state.
    func loadPersistedSnapshot(serverID expectedServerID: UUID, scope expectedScope: String) async -> Snapshot? {
        guard serverID() == expectedServerID, cacheScope() == expectedScope,
              let file = directory?.appendingPathComponent("\(expectedServerID)-\(expectedScope).sqlite") else {
            return nil
        }
        let token = generation
        let stored = await Task.detached(priority: .utility) {
            try? LibraryCatalogStore.load(from: file)
        }.value
        guard token == generation, serverID() == expectedServerID, cacheScope() == expectedScope,
              !Task.isCancelled else { return nil }
        return stored
    }

    func search(query: String, limit: Int = 20) -> LocalHits {
        guard hasUsableIndex else { return LocalHits(artists: [], albums: [], playlists: []) }
        if persistedIndexDate == lastIndexedAt, let url = catalogURL,
           let hits = try? LibraryCatalogStore.search(query, limit: limit, at: url) { return hits }
        return Self.match(query: query, limit: limit, artists: artists, albums: albums,
                   playlists: playlists, songs: songs, artistTokens: artistTokens,
                   albumTokens: albumTokens, playlistTokens: playlistTokens, songTokens: songTokens)
    }

    /// Capture immutable, copy-on-write arrays, then scan away from keyboard/layout work.
    func searchInBackground(query: String, limit: Int = 80, seed: LocalHits? = nil) async -> LocalHits {
        guard hasUsableIndex else { return seed ?? LocalHits(artists: [], albums: [], playlists: []) }
        let revision = accountRevision()
        let token = generation
        let indexedEntryCount = entryCount
        let store = persistedIndexDate == lastIndexedAt ? catalogURL : nil
        let worker = Task.detached(priority: .userInitiated) {
            [artists, albums, playlists, songs, artistTokens, albumTokens, playlistTokens, songTokens] in
            if let store, let hits = try? LibraryCatalogStore.search(query, limit: limit, at: store, seed: seed) { return hits }
            let startedAt = ProcessInfo.processInfo.systemUptime
            let hits = Self.match(query: query, limit: limit, artists: artists, albums: albums,
                                  playlists: playlists, songs: songs, artistTokens: artistTokens,
                                  albumTokens: albumTokens, playlistTokens: playlistTokens, songTokens: songTokens, seed: seed)
            let elapsedMilliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            Logger.library.debug("Local search took \(elapsedMilliseconds) ms for \(indexedEntryCount) entries (limit \(limit))")
            return hits
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard token == generation, revision == accountRevision(), hasUsableIndex, !Task.isCancelled else {
            return LocalHits(artists: [], albums: [], playlists: [])
        }
        return result
    }

    nonisolated private static func match(
        query: String, limit: Int, artists: [IndexedArtist], albums: [IndexedAlbum],
        playlists: [IndexedPlaylist], songs: [DisplayableSong], artistTokens: [[String]],
        albumTokens: [[String]], playlistTokens: [[String]], songTokens: [[String]], seed: LocalHits? = nil
    ) -> LocalHits {
        let queryTokens = HangulRomanization.searchTokens(query)
        guard !queryTokens.isEmpty else {
            return LocalHits(artists: [], albums: [], playlists: [])
        }

        func matches(_ tokens: [String]) -> Bool {
            queryTokens.contains { query in tokens.contains { $0.contains(query) } }
        }
        func collect<T>(_ values: [T], tokens: [[String]]) -> [T] {
            guard limit > 0 else { return [] }
            var result: [T] = []
            for (value, terms) in zip(values, tokens) {
                if Task.isCancelled { break }
                guard matches(terms) else { continue }
                result.append(value)
                if result.count == limit { break }
            }
            return result
        }
        let matchedArtists = collect(artists, tokens: artistTokens)
        let matchedAlbums = collect(albums, tokens: albumTokens)
        let matchedPlaylists = collect(playlists, tokens: playlistTokens)

        var hits = seed.flatMap { $0.isEmpty ? nil : $0 } ?? LocalHits(
            artists: matchedArtists, albums: matchedAlbums, playlists: matchedPlaylists,
            songs: collect(songs, tokens: songTokens))
        var artistIDs = Set(hits.artists.map(\.id))
        hits.artists += matchedArtists.filter { artistIDs.insert($0.id).inserted }
        let directAlbums = Set(hits.albums.filter { album in
            queryTokens.contains { album.name.localizedStandardContains($0) }
        }.map(\.id))
        let ownedAlbums = Set(albums.filter { $0.artistId.map(artistIDs.contains) == true || $0.albumArtistIDs.contains(where: artistIDs.contains) }.map(\.id))
        var relatedAlbums = ownedAlbums
        var seenSongs = Set(hits.songs.map(\.id))
        for song in songs {
            if Task.isCancelled { break }
            let contributors = (song.contributingArtists ?? []) + (song.albumArtists ?? [])
            let artistMatch = song.artistId.map(artistIDs.contains) == true
                || contributors.contains { artistIDs.contains($0.id) }
            if artistMatch, let albumID = song.albumId { relatedAlbums.insert(albumID) }
            guard artistMatch || song.albumId.map({ ownedAlbums.contains($0) || directAlbums.contains($0) }) == true else { continue }
            if hits.songs.count < limit, seenSongs.insert(song.id).inserted { hits.songs.append(song) }
            if seenSongs.contains(song.id), !queryTokens.contains(where: { song.title.localizedStandardContains($0) }) {
                hits.relatedIDs.insert("song:" + song.id)
            }
        }
        var seenAlbums = Set(hits.albums.map(\.id))
        for album in albums where relatedAlbums.contains(album.id) {
            if Task.isCancelled { break }
            if hits.albums.count < limit, seenAlbums.insert(album.id).inserted { hits.albums.append(album) }
            if seenAlbums.contains(album.id), !directAlbums.contains(album.id) { hits.relatedIDs.insert("album:" + album.id) }
        }
        return hits
    }

    /// Compact catalog digest for on-device AI prompts (capped).
    func catalogDigest(limit: Int = 40) -> String {
        let artistNames = artists.prefix(limit).map(\.name)
        let albumNames = albums.prefix(limit).map(\.name)
        guard !artistNames.isEmpty || !albumNames.isEmpty else { return "" }
        return """
        Library sample — artists: \(artistNames.joined(separator: ", ")).
        Albums: \(albumNames.joined(separator: ", ")).
        """
    }

    private func install(_ snapshot: Snapshot, token: UInt64, server: UUID?, revision: UInt64) async -> Bool {
        // Reopen the persisted search tokens without repeating romanization at launch.
        let tokenStore = persistedIndexDate == snapshot.date ? catalogURL : nil
        let worker = Task.detached(priority: .utility) {
            let catalog = snapshot.albumCatalog ?? snapshot.albums.map {
                AlbumID3(id: $0.id, name: $0.name, songCount: 0, duration: 0, artist: $0.artist, coverArt: $0.coverArtId)
            }
            let catalogByID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let storedMatches = snapshot.atmosMatchingVersion == AtmosVariantCatalogue.matchingVersion ? snapshot.atmosMatches : nil
            let variants = AtmosVariantCatalogue(songs: snapshot.songs, albums: catalog, storedMatches: storedMatches)
            let songRelations = Dictionary(grouping: snapshot.songs.compactMap { song -> (String, DisplayableSong)? in
                guard let albumID = song.albumId else { return nil }
                return (albumID, song)
            }, by: \.0).mapValues { songs in
                var ids = Set<String>()
                var names = Set<String>()
                for song in songs.map(\.1) {
                    if let id = song.artistId, !id.isEmpty { ids.insert(id) }
                    if let name = song.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { names.insert(name) }
                }
                return (ids.sorted(), names.sorted())
            }
            let presented = AtmosAlbumPolicy.presented(catalog).map {
                let relation = songRelations[$0.id] ?? ([], [])
                return IndexedAlbum(id: $0.id, name: $0.name, artist: $0.artist,
                    artistId: $0.artistId, albumArtistIDs: ($0.artists ?? []).map(\.id), relatedArtistIDs: relation.0,
                    relatedArtistNames: relation.1, coverArtId: $0.coverArt)
            }
            let storedTokens = tokenStore.flatMap { try? LibraryCatalogStore.storedTokens(at: $0) } ?? [:]
            func tokenize<T>(_ values: [T], kind: String, id: (T) -> String, text: (T) -> String) throws -> [[String]] {
                var result: [[String]] = []
                result.reserveCapacity(values.count)
                for value in values {
                    try Task.checkCancellation()
                    result.append(storedTokens[kind]?[id(value)] ?? HangulRomanization.searchTokens(text(value)))
                }
                return result
            }
            return (try tokenize(snapshot.artists, kind: "artist", id: { $0.id }) { $0.name },
                    try tokenize(presented, kind: "album", id: { $0.id }) {
                        [$0.name, $0.artist ?? "", $0.relatedArtistNames.joined(separator: " ")].joined(separator: " ")
                    },
                    try tokenize(snapshot.playlists, kind: "playlist", id: { $0.id }) { $0.name },
                    try tokenize(snapshot.songs, kind: "song", id: { $0.id }) {
                        let albumArtist = $0.albumId.flatMap { catalogByID[$0]?.artist } ?? ""
                        return [$0.title, $0.artist ?? "", albumArtist, $0.albumName ?? "", $0.genre ?? ""].joined(separator: " ")
                    }, variants, presented)
        }
        guard let tokens = try? await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: { worker.cancel() }) else { return false }
        guard token == generation, server == serverID(), revision == accountRevision(), !Task.isCancelled else { return false }
        artists = snapshot.artists
        albums = tokens.5
        variants = tokens.4
        detailVariants = [:]
        detailServerID = nil
        playlists = snapshot.playlists
        songs = snapshot.songs
        (artistTokens, albumTokens, playlistTokens, songTokens) = (tokens.0, tokens.1, tokens.2, tokens.3)
        entryCount = artists.count + albums.count + playlists.count + songs.count
        lastIndexedAt = snapshot.date
        installedSnapshot = snapshot
        installedRevision = revision
        if let server { onSnapshot?(snapshot, server) }
        RuntimeDiagnostics.mark(.libraryReady)
        return true
    }

    private func runRebuild(using library: any LibraryServiceProtocol, token: UInt64, revision: UInt64, refreshExisting: Bool) async {
        guard token == generation, revision == accountRevision(), !Task.isCancelled else { return }
        let id = serverID()
        if loadedServerID != id || (installedRevision != nil && installedRevision != revision) {
            variants = AtmosVariantCatalogue()
            artists = []; albums = []; playlists = []; songs = []; songTokens = []
            artistTokens = []; albumTokens = []; playlistTokens = []
            entryCount = 0; lastIndexedAt = nil; installedSnapshot = nil; installedRevision = nil
        }
        loadedServerID = id
        if isIndexing { isIndexing = false }
        progress = 0
        defer {
            if token == generation {
                if isIndexing { isIndexing = false }
                isPreparing = false
                indexTask = nil
                indexTaskServerID = nil
            }
        }
        let file = catalogURL
        let scope = cacheScope()
        let migrationKey = "luma.libraryIndex.accountScope." + (id?.uuidString ?? "none")
        let previousScope = defaults.string(forKey: migrationKey)
        let canMigrateLegacy = scope == nil || previousScope == nil || previousScope == scope
        let legacyFile = canMigrateLegacy ? id.flatMap { directory?.appendingPathComponent("\($0).json") } : nil
        let legacySQLite = canMigrateLegacy && scope != nil ? id.flatMap { directory?.appendingPathComponent("\($0).sqlite") } : nil
        if let scope { defaults.set(scope, forKey: migrationKey) }
        if lastIndexedAt == nil, let file {
            let (stored, alreadySQLite) = await Task.detached(priority: .utility) { () -> (Snapshot?, Bool) in
                if let stored = try? LibraryCatalogStore.load(from: file) { return (stored, true) }
                if let legacySQLite, let stored = try? LibraryCatalogStore.load(from: legacySQLite) { return (stored, false) }
                guard let legacyFile, let data = try? Data(contentsOf: legacyFile),
                      let stored = try? JSONDecoder().decode(Snapshot.self, from: data) else { return (nil, false) }
                return (stored, false)
            }.value
            guard token == generation, revision == accountRevision(), id == serverID(), !Task.isCancelled else { return }
            if let stored {
                // Migrate a legacy JSON without fetching the server or deleting its backup.
                if !alreadySQLite {
                    let staged = try? await Task.detached(priority: .utility) {
                        let staged = file.deletingLastPathComponent().appendingPathComponent(".catalog-\(UUID()).sqlite")
                        do { try LibraryCatalogStore.save(stored, to: staged); return staged }
                        catch { StagedFileWrite.discard(staged); throw error }
                    }.value
                    if let staged {
                        defer { StagedFileWrite.discard(staged) }
                        guard token == generation, revision == accountRevision(), id == serverID(), !Task.isCancelled else { return }
                        try? StagedFileWrite.commit(staged, to: file)
                    }
                }
                persistedIndexDate = FileManager.default.fileExists(atPath: file.path) ? stored.date : nil
                guard await install(stored, token: token, server: id, revision: revision) else { return }
                progress = 1
            }
        }
        if !refreshExisting, lastIndexedAt != nil {
            lastBuildSucceeded = true
            return
        }
        guard networkAvailable() else {
            if lastIndexedAt == nil { lastError = .noNetwork }
            return
        }
        isIndexing = true
        progress = 0
        do {
            async let artistsTask = library.artists()
            async let albumsTask = library.albumsForIndex()
            async let playlistsTask = library.playlists()
            let artistIndexes = try await artistsTask
            let albumList = try await albumsTask
            let playlistList = try await playlistsTask
            var indexedSongs: [DisplayableSong] = []
            var seen = Set<String>()
            var offset = 0
            while true {
                try Task.checkCancellation()
                guard token == generation, revision == accountRevision(), id == serverID() else { return }
                let page = try await library.librarySongs(offset: offset, count: 500)
                let fresh = page.filter { seen.insert($0.id).inserted }
                guard !fresh.isEmpty else { break }
                indexedSongs += fresh.map { DisplayableSong(from: $0) }
                offset += page.count
                // Some servers cap counts below the request. Stop on empty/repeated data, not a short page.
            }
            try Task.checkCancellation()
            guard token == generation, revision == accountRevision(), id == serverID() else { return }
            var snapshot = Snapshot(
                artists: artistIndexes.flatMap(\.artist).map { IndexedArtist(id: $0.id, name: $0.name, coverArtId: $0.coverArt) },
                albums: albumList.map {
                    IndexedAlbum(id: $0.id, name: $0.name, artist: $0.artist,
                        artistId: $0.artistId, albumArtistIDs: ($0.artists ?? []).map(\.id), coverArtId: $0.coverArt)
                },
                playlists: playlistList.map { IndexedPlaylist(id: $0.id, name: $0.name, coverArtId: $0.coverArt, summary: $0.comment, trackCount: $0.songCount, owner: $0.owner) },
                songs: indexedSongs, date: Date(), albumCatalog: albumList
            )
            guard await install(snapshot, token: token, server: id, revision: revision) else { return }
            snapshot.atmosMatches = variants.matches
            snapshot.atmosMatchingVersion = AtmosVariantCatalogue.matchingVersion
            progress = 1
            if let file {
                // Encode and bulk-write on a worker. Only the atomic rename runs with the
                // MainActor generation check, so logout cannot be followed by an old file commit.
                let staged = try await Task.detached(priority: .utility) {
                    let staged = file.deletingLastPathComponent().appendingPathComponent(".catalog-\(UUID()).sqlite")
                    do {
                        if (try? LibraryCatalogStore.load(from: file)) != nil { try FileManager.default.copyItem(at: file, to: staged) }
                        try LibraryCatalogStore.save(snapshot, to: staged)
                        return staged
                    } catch { StagedFileWrite.discard(staged); throw error }
                }.value
                defer { Task.detached(priority: .utility) { StagedFileWrite.discard(staged) } }
                guard token == generation, revision == accountRevision(), id == serverID(), !Task.isCancelled else { return }
                try StagedFileWrite.commit(staged, to: file)
                persistedIndexDate = snapshot.date
            }
            LibraryIndexSchema.markPrepared()
            lastBuildSucceeded = true
        } catch is CancellationError {
        } catch {
            guard token == generation, revision == accountRevision(), id == serverID(), !Task.isCancelled,
                  (error as? URLError)?.code != .cancelled else { return }
            lastError = UserFacingError.from(error)
            Logger.library.debug("Library index rebuild failed: \(error, privacy: .public)")
        }
    }

}

// MARK: - Library index schema version

/// Tracks whether the in-memory library index has been built for the current schema
/// version. Users who upgraded from a build that predates library indexing start with an
/// empty index, so RootView routes them to the "Preparing Luma" screen once to index
/// their catalog before Home appears.
enum LibraryIndexSchema {
    static let versionKey = "luma.libraryIndex.schemaVersion"
    /// Bump when the index contents change shape so existing installs re-index once.
    static let currentVersion = 2

    static var needsPreparation: Bool {
        UserDefaults.standard.integer(forKey: versionKey) < currentVersion
    }

    static func markPrepared() {
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }
}
