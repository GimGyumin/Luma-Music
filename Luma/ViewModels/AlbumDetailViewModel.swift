// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

@Observable
@MainActor
final class AlbumDetailViewModel {
    var albumName: String = ""
    var artistName: String? = nil
    var year: Int? = nil
    var genre: String? = nil
    var releaseDate: ItemDate? = nil
    var recordLabels: [String] = []
    /// Copyright / ℗ text carried in a track's ID3 `comment` tag when the server does not
    /// expose an album-level `recordLabels`/copyright field.
    var trackCopyright: String? = nil
    var albumDescription: String? = nil
    var totalDurationSeconds: Int = 0
    var songCount: Int = 0
    var coverArtId: String? = nil
    var artistId: String? = nil
    var songs: [DisplayableSong] = []
    private var availableAtmosSongs: [DisplayableSong] = []
    var audioQualities: [AudioQualityKind] { AudioQualityClassifier.albumQualities(in: songs + availableAtmosSongs) }
    /// Other editions of this album (remasters / anniversary / deluxe), same artist.
    var otherAlbumVersions: [AlbumID3] = []
    /// Other albums by the same artist (excludes the current album and `otherAlbumVersions`).
    var moreAlbumsByArtist: [AlbumID3] = []
    var isLoadingMoreAlbums = false
    var isOffline: Bool = false
    var isLoading = false
    /// Core album metadata and tracks are ready to render. Secondary description,
    /// label and "more by" enrichment may continue after this becomes true.
    var isPrimaryContentReady = false
    var error: UserFacingError?
    var isDownloadingAlbum = false
    var downloadingIds: Set<String> = []

    private var loadedAlbum: AlbumID3?
    var displayAlbumID: String { loadedAlbum?.id ?? libraryIndex?.primaryAlbumID(for: albumId) ?? albumId }
    private let albumId: String
    private let libraryService: any LibraryServiceProtocol
    private let downloadService: any DownloadServiceProtocol
    private let toastService: ToastService
    private let serverState: ServerState
    private let libraryIndex: LibraryIndexService?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var needsPresentationReload = false
    @ObservationIgnored private var presentationSuspended = false
    var acceptsPresentationUpdates: Bool { !presentationSuspended }

    /// Called at willDisappear, before the zoom snapshot is taken. Do not publish
    /// loading flags here: leave the outgoing image exactly as it was.
    func suspendPendingLoad() {
        presentationSuspended = true
        needsPresentationReload = needsPresentationReload || isLoading || isLoadingMoreAlbums
        loadGeneration &+= 1
    }

    func resumePendingLoadIfNeeded() async {
        guard !Task.isCancelled else { return }
        presentationSuspended = false
        guard needsPresentationReload else { return }
        await load()
    }

    init(
        albumId: String,
        libraryService: any LibraryServiceProtocol,
        downloadService: any DownloadServiceProtocol,
        toastService: ToastService,
        serverState: ServerState,
        libraryIndex: LibraryIndexService? = nil
    ) {
        self.albumId = albumId
        self.libraryService = libraryService
        self.downloadService = downloadService
        self.toastService = toastService
        self.serverState = serverState
        self.libraryIndex = libraryIndex
    }

    func load() async {
        guard !Task.isCancelled, !presentationSuspended else { return }
        needsPresentationReload = false
        let generation = loadGeneration + 1
        loadGeneration = generation
        isLoading = true
        // Refreshes keep the already-published album visible. Optional enrichment or a
        // cancelled navigation task must not turn a usable page back into a loading cover.
        error = nil
        if serverState.isOnline {
            // A local album may contain only downloaded tracks. Publish it only as an
            // offline/failure fallback, never as the initial online catalog snapshot.
            await loadFromAPI(generation: generation)
        } else {
            isOffline = true
            _ = await loadFromLocal()
        }
        guard generation == loadGeneration else { return }
        let downloading = await downloadService.isDownloadingAlbum(displayAlbumID)
        guard generation == loadGeneration else { return }
        isLoading = false
        isDownloadingAlbum = downloading
    }

    private func loadFromAPI(generation: Int) async {
        do {
            let apiAlbum = try await libraryService.displayAlbum(id: albumId)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            // Empty-success guard: behind a captive proxy / Cloudflare-WARP edge the server
            // is reachable but answers 200 with no songs. That never throws, so the catch
            // below can't help — treat an empty result exactly like a failure and prefer the
            // downloaded copy before clobbering the UI with an empty state.
            if (apiAlbum.song ?? []).isEmpty, await loadFromLocal() { return }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            loadedAlbum = apiAlbum
            guard let serverId = serverState.activeServer?.id else { return }
            let downloadedIds = await downloadService.downloadedSongIds(serverId: serverId)
            let prepared = try await DisplayableSong.prepare(
                apiAlbum.song ?? [], downloadedIDs: downloadedIds,
                fallbackCoverArtID: apiAlbum.coverArt, sortedBy: Self.albumTrackOrder
            )
            guard generation == loadGeneration, !Task.isCancelled, serverState.activeServer?.id == serverId else { return }
            albumName = apiAlbum.name
            artistName = apiAlbum.artist
            year = apiAlbum.year
            genre = apiAlbum.genre
            releaseDate = apiAlbum.releaseDate ?? apiAlbum.originalReleaseDate
            recordLabels = (apiAlbum.recordLabels ?? []).compactMap { label in
                let name = label.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }
            trackCopyright = Self.findTrackCopyright((apiAlbum.song ?? []).map(\.comment))
            totalDurationSeconds = apiAlbum.duration
            songCount = apiAlbum.songCount
            coverArtId = apiAlbum.coverArt
            artistId = apiAlbum.artistId
            songs = prepared
            availableAtmosSongs = prepared.compactMap { libraryIndex?.preferredAtmosSong(for: $0, serverId: serverId) }
            isOffline = false
            isPrimaryContentReady = true

            // Footer credits and More By do not depend on the editorial description.
            // Let them publish even while albumInfo or a description provider is slow.
            async let moreByTask: Void = loadMoreAlbumsByArtist(generation: generation)
            async let recordLabelTask: Void = enrichRecordLabelIfNeeded(generation: generation)
            async let copyrightTask: Void = loadNativeCopyrightIfNeeded(album: apiAlbum, generation: generation)

            let albumInfo = try? await libraryService.albumInfo(id: albumId)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            albumDescription = Self.resolveAlbumDescription(
                infoNotes: albumInfo?.notes,
                songs: apiAlbum.song ?? []
            )
            await enrichDescriptionIfNeeded(musicBrainzId: albumInfo?.musicBrainzId, generation: generation)
            await recordLabelTask
            await copyrightTask
            await moreByTask
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if UserFacingError.isCancellation(error) { return }
            // Server unreachable (airplane mode with stale isOnline, VPN-satisfied path,
            // server down): fall back to the downloaded copy before surfacing an error.
            if await loadFromLocal() { return }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            self.error = UserFacingError.from(error)
        }
    }

    // Compatibility entry points; parsing has no UI, service or actor dependencies.
    nonisolated static func findTrackCopyright(_ comments: [String?]) -> String? {
        AlbumMetadataParser.findTrackCopyright(comments)
    }
    nonisolated static func splitComment(_ raw: String?) -> (copyright: String?, description: String?) {
        AlbumMetadataParser.splitComment(raw)
    }
    nonisolated static func resolveAlbumDescription(infoNotes: String?, songs: [Song]) -> String? {
        AlbumMetadataParser.resolveAlbumDescription(infoNotes: infoNotes, songs: songs)
    }
    nonisolated static func descriptionFromSongComments(_ songs: [Song]) -> String? {
        AlbumMetadataParser.descriptionFromSongComments(songs)
    }
    nonisolated static func plainTextDescription(from raw: String?) -> String? {
        AlbumMetadataParser.plainTextDescription(from: raw)
    }

    private func loadNativeCopyrightIfNeeded(album: AlbumID3, generation: Int) async {
        guard trackCopyright == nil, !Task.isCancelled else { return }
        let identity = serverState.activeServer?.id
        let revision = serverState.accountRevision
        let credit = await libraryService.albumCopyright(id: album.id, songIDs: (album.song ?? []).map(\.id))
        guard generation == loadGeneration, !Task.isCancelled,
              identity == serverState.activeServer?.id, revision == serverState.accountRevision else { return }
        if let credit { trackCopyright = credit }
    }

    /// Server returned no `recordLabels` → fetch the label from MusicBrainz (free, no key)
    /// when metadata enrichment is enabled. Supplies the "℗" footer line.
    private func enrichRecordLabelIfNeeded(generation: Int) async {
        guard generation == loadGeneration, recordLabels.isEmpty,
              trackCopyright == nil, !Task.isCancelled else { return }
        let enrich = UserDefaults.standard.object(forKey: AppleMusicSettings.enrichKey) as? Bool ?? true
        guard enrich else { return }
        let name = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let label = await ExternalDescriptionService.shared.albumRecordLabel(
            albumName: name,
            artistName: artistName
        ) {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            recordLabels = [label]
        }
    }

    /// Disk cache (with TTL refresh) → Apple Music editorialNotes → Wikipedia / MusicBrainz.
    private func enrichDescriptionIfNeeded(musicBrainzId: String?, generation: Int) async {
        guard !Task.isCancelled else { return }
        let enrich = UserDefaults.standard.object(forKey: AppleMusicSettings.enrichKey) as? Bool ?? true
        guard enrich else { return }
        let existing = albumDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Short Last.fm stubs ("n/a", one sentence) should not block richer external copy.
        guard existing.isEmpty || AlbumMetadataParser.isStubDescription(existing) else { return }
        let name = albumName
        guard !name.isEmpty else { return }

        let cached = await DescriptionCache.shared.lookup(
            kind: .album,
            name: name,
            artist: artistName,
            musicBrainzId: musicBrainzId
        )
        guard generation == loadGeneration, !Task.isCancelled else { return }
        if let cached {
            albumDescription = cached.text
            if !cached.needsRefresh { return }
        }

        // Prefer Apple Music catalog copy when a developer JWT is configured.
        if let apple = await AppleMusicCatalogService.shared.albumEditorialNotes(
            albumName: name,
            artistName: artistName
        ), let plain = Self.plainTextDescription(from: apple) {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            albumDescription = plain
            await DescriptionCache.shared.store(
                plain,
                kind: .album,
                name: name,
                artist: artistName,
                musicBrainzId: musicBrainzId,
                source: .external
            )
            return
        }

        if let external = await ExternalDescriptionService.shared.albumDescription(
            albumName: name,
            artistName: artistName,
            musicBrainzId: musicBrainzId
        ), let plain = Self.plainTextDescription(from: external) {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            albumDescription = plain
            await DescriptionCache.shared.store(
                plain,
                kind: .album,
                name: name,
                artist: artistName,
                musicBrainzId: musicBrainzId,
                source: .external
            )
        }
    }

    func loadMoreAlbumsByArtist(generation: Int? = nil) async {
        guard !presentationSuspended, !Task.isCancelled else { return }
        let generation = generation ?? loadGeneration
        guard let artistId, !artistId.isEmpty else {
            otherAlbumVersions = []
            moreAlbumsByArtist = []
            return
        }
        isLoadingMoreAlbums = true
        defer {
            if generation == loadGeneration { isLoadingMoreAlbums = false }
        }
        do {
            let artist = try await libraryService.artist(id: artistId)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            let siblings = await libraryService.presentedAlbums(artist.album ?? [])
                .filter { $0.id != (loadedAlbum?.id ?? albumId) }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            let versions = AlbumVersionMatcher.otherVersions(
                of: albumName,
                excludingId: albumId,
                among: siblings
            )
            let versionIds = Set(versions.map(\.id))
            otherAlbumVersions = ArtistAlbumCategorizer.sortedByNewest(versions)
            moreAlbumsByArtist = ArtistAlbumCategorizer.sortedByNewest(
                siblings.filter { !versionIds.contains($0.id) }
            )
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            otherAlbumVersions = []
            moreAlbumsByArtist = []
        }
    }

    nonisolated static func albumTrackOrder(_ lhs: DisplayableSong, _ rhs: DisplayableSong) -> Bool {
        let ld = lhs.discNumber ?? 1
        let rd = rhs.discNumber ?? 1
        if ld != rd { return ld < rd }
        return (lhs.trackNumber ?? Int.max) < (rhs.trackNumber ?? Int.max)
    }

    /// Returns true when a downloaded copy with at least one track was loaded.
    /// Sets isOffline only on success — a transient online failure must not flip
    /// the UI into offline mode while songs from a previous load are still shown.
    @discardableResult
    private func loadFromLocal() async -> Bool {
        let generation = loadGeneration
        guard let serverId = serverState.activeServer?.id,
              let data = await downloadService.localAlbumData(albumId: displayAlbumID, serverId: serverId),
              generation == loadGeneration, !Task.isCancelled,
              serverId == serverState.activeServer?.id, !data.songs.isEmpty else { return false }
        albumName = data.albumName
        artistName = data.artistName
        coverArtId = data.coverArtId
        songCount = data.songs.count
        songs = data.songs
        // Downloaded tracks preserve their ID3 comments even though LocalAlbumData
        // has no album-level label field. Also clear a previous credit if absent.
        trackCopyright = Self.findTrackCopyright(data.songs.map(\.comment))
        availableAtmosSongs = []
        isPrimaryContentReady = true
        // Offline records carry no year/genre/artistId — clear stale online values so a re-load after going
        // offline (the long-lived VM re-runs load() on connectivity change) doesn't keep showing them.
        year = nil
        genre = nil
        releaseDate = nil
        recordLabels = []
        albumDescription = nil
        otherAlbumVersions = []
        moreAlbumsByArtist = []
        totalDurationSeconds = 0
        artistId = nil
        isOffline = true
        return true
    }

    func downloadAlbum() async {
        guard let album = loadedAlbum, let serverId = serverState.activeServer?.id else { return }
        isDownloadingAlbum = true
        defer { isDownloadingAlbum = false }
        do {
            try await downloadService.download(album: album, serverId: serverId)
        } catch {
            if !UserFacingError.isCancellation(error) {
                toastService.showError(UserFacingError.from(error).displayMessage)
            }
        }
        let downloadedIds = await downloadService.downloadedSongIds(serverId: serverId)
        songs = songs.map { $0.withDownloaded(downloadedIds.contains($0.id)) }
    }

    func cancelAlbumDownload() async {
        guard let serverId = serverState.activeServer?.id else { return }
        if let id = loadedAlbum?.id { await downloadService.cancelAlbumDownload(albumId: id, serverId: serverId) }
        for song in songs {
            await downloadService.cancelDownload(songId: song.id, serverId: serverId)
        }
        isDownloadingAlbum = false
    }

    func downloadSong(id: String) async {
        guard let song = loadedAlbum?.song?.first(where: { $0.id == id }),
              let serverId = serverState.activeServer?.id else { return }
        downloadingIds.insert(id)
        defer { downloadingIds.remove(id) }
        do {
            try await downloadService.download(song: song, serverId: serverId)
        } catch {
            toastService.showError(UserFacingError.from(error).displayMessage)
        }
        let allDownloaded = await downloadService.downloadedSongIds(serverId: serverId)
        if let idx = songs.firstIndex(where: { $0.id == id }) {
            songs[idx] = songs[idx].withDownloaded(allDownloaded.contains(id))
        }
    }

    func downloadMissingTracks() async {
        guard let album = loadedAlbum,
              let serverId = serverState.activeServer?.id,
              let allSongs = album.song else { return }
        let downloadedIds = Set(songs.filter { $0.isDownloaded }.map(\.id))
        let missing = allSongs.filter { !downloadedIds.contains($0.id) }
        guard !missing.isEmpty else { return }
        isDownloadingAlbum = true
        defer { isDownloadingAlbum = false }
        var anyFailed = false
        for song in missing {
            do {
                try await downloadService.download(song: song, serverId: serverId)
            } catch {
                anyFailed = true
            }
        }
        let allDownloaded = await downloadService.downloadedSongIds(serverId: serverId)
        songs = songs.map { $0.withDownloaded(allDownloaded.contains($0.id)) }
        if anyFailed, !songs.contains(where: { $0.isDownloaded }) {
            toastService.showError(UserFacingError.downloadFailed.displayMessage)
        }
    }

    func deleteDownload() async {
        guard let serverId = serverState.activeServer?.id else { return }
        try? await downloadService.remove(albumId: displayAlbumID, serverId: serverId)
        songs = songs.map { $0.withDownloaded(false) }
    }
}
