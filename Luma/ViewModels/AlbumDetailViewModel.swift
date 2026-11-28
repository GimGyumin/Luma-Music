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
    private var localAtmosIDs: Set<String> = []
    @ObservationIgnored private var localAtmosCheck = 0
    /// Album headers call audio quality and Atmos-ID helpers from multiple body
    /// sections. Cache the per-song preferred variants until the displayed song
    /// list changes, instead of resolving every song on every render.
    @ObservationIgnored private var cachedAtmosSignature: [String] = []
    @ObservationIgnored private var cachedAtmosAlternatives: [DisplayableSong] = []
    @ObservationIgnored private var cachedAtmosServerId: UUID?

    var audioQualities: [AudioQualityKind] { audioQualities(for: songs) }

    // The album badge describes available formats independently of the playback toggle.
    func audioQualities(for displayedSongs: [DisplayableSong]) -> [AudioQualityKind] {
        guard let serverId = serverState.activeServer?.id else {
            return AudioQualityClassifier.albumQualities(in: displayedSongs)
        }
        let canStream = serverState.isOnline
            && streamingSettings?.allowsRemoteDolbyAtmos(isCellular: serverState.isCellularConnection) == true
        let alternatives = atmosAlternatives(for: displayedSongs, serverId: serverId)
            .filter { canStream || localAtmosIDs.contains($0.id) }
        return AudioQualityClassifier.albumQualities(in: displayedSongs + alternatives)
    }
    func atmosAlternativeIDs(for displayedSongs: [DisplayableSong]) -> [String] {
        guard let serverId = serverState.activeServer?.id else { return [] }
        return Array(Set(atmosAlternatives(for: displayedSongs, serverId: serverId).map(\.id))).sorted()
    }

    private func atmosAlternatives(
        for displayedSongs: [DisplayableSong],
        serverId: UUID
    ) -> [DisplayableSong] {
        let signature = displayedSongs.map(\.id)
        if signature == cachedAtmosSignature, serverId == cachedAtmosServerId {
            return cachedAtmosAlternatives
        }
        let alternatives = displayedSongs.compactMap {
            libraryIndex?.preferredAtmosSong(for: $0, serverId: serverId)
        }
        cachedAtmosSignature = signature
        cachedAtmosAlternatives = alternatives
        cachedAtmosServerId = serverId
        return alternatives
    }

    /// A new album payload can change variant metadata without changing song IDs.
    /// Drop the cache at payload boundaries so the next header read resolves it again.
    private func invalidateAtmosAlternatives() {
        cachedAtmosSignature = []
        cachedAtmosAlternatives = []
        cachedAtmosServerId = nil
    }

    func refreshLocalAtmosAvailability(for displayedSongs: [DisplayableSong]) async {
        localAtmosCheck &+= 1
        let check = localAtmosCheck
        guard !presentationSuspended, let serverId = serverState.activeServer?.id else { return }
        let revision = serverState.accountRevision
        let ids = atmosAlternativeIDs(for: displayedSongs)
        var available: Set<String> = []
        for id in ids {
            if await downloadService.downloadedOriginalURL(forSongId: id, serverId: serverId) != nil {
                available.insert(id)
            }
            guard check == localAtmosCheck, !Task.isCancelled else { return }
        }
        guard check == localAtmosCheck, !Task.isCancelled, !presentationSuspended,
              serverState.activeServer?.id == serverId, serverState.accountRevision == revision else { return }
        localAtmosIDs = available
    }

    /// Other editions of this album (remasters / anniversary / deluxe), same artist.
    var otherAlbumVersions: [AlbumID3] = []
    /// Other albums by the same artist (excludes the current album and `otherAlbumVersions`).
    var moreAlbumsByArtist: [AlbumID3] = []
    var isLoadingMoreAlbums = false
    var isOffline: Bool = false
    var isLoading = true
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
    private let streamingSettings: StreamingSettings?
    nonisolated struct LoadKey: Equatable, Sendable {
        let identity: ServerRequestIdentity?
        let isOnline: Bool
        let isReachable: Bool

        @MainActor init(_ state: ServerState) {
            identity = state.activeServer.flatMap { try? state.requestIdentity(for: $0.id) }
            isOnline = state.isOnline
            isReachable = state.isServerReachable
        }
    }

    @ObservationIgnored private var downloadBadgeRevision = 0
    @ObservationIgnored private var activeLoadKey: LoadKey?
    @ObservationIgnored private var completedLoadKey: LoadKey?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var needsPresentationReload = false
    @ObservationIgnored private var presentationSuspended = false
    var acceptsPresentationUpdates: Bool { !presentationSuspended }

    /// Called at willDisappear, before the zoom snapshot is taken. Do not publish
    /// loading flags here: leave the outgoing image exactly as it was.
    func suspendPendingLoad() {
        presentationSuspended = true
        needsPresentationReload = needsPresentationReload || activeLoadKey != nil
        activeLoadKey = nil
        loadGeneration &+= 1
    }

    func resumePendingLoadIfNeeded() async {
        guard !Task.isCancelled else { return }
        presentationSuspended = false
        if needsPresentationReload {
            await load()
        } else {
            await loadIfNeeded()
        }
    }

    init(
        albumId: String,
        libraryService: any LibraryServiceProtocol,
        downloadService: any DownloadServiceProtocol,
        toastService: ToastService,
        serverState: ServerState,
        libraryIndex: LibraryIndexService? = nil,
        streamingSettings: StreamingSettings? = nil
    ) {
        self.albumId = albumId
        self.libraryService = libraryService
        self.downloadService = downloadService
        self.toastService = toastService
        self.serverState = serverState
        self.libraryIndex = libraryIndex
        self.streamingSettings = streamingSettings
    }

    func loadIfNeeded() async {
        let key = LoadKey(serverState)
        guard key != completedLoadKey else { return }
        await load()
    }

    func load() async {
        let key = LoadKey(serverState)
        guard !Task.isCancelled, !presentationSuspended, activeLoadKey != key else { return }
        needsPresentationReload = false
        activeLoadKey = key
        completedLoadKey = nil
        let generation = loadGeneration + 1
        loadGeneration = generation
        isLoading = true
        error = nil
        defer {
            if generation == loadGeneration {
                activeLoadKey = nil
                isLoading = false
                if !Task.isCancelled, key == LoadKey(serverState), isPrimaryContentReady, error == nil,
                   !key.isOnline || !isOffline {
                    completedLoadKey = key
                }
            }
        }

        if key.isOnline {
            await loadFromAPI(generation: generation, key: key)
        } else {
            isOffline = true
            if !(await loadFromLocal(generation: generation, key: key)),
               isCurrentLoad(generation, key: key), !isPrimaryContentReady {
                error = .unexpected
            }
        }

        guard isCurrentLoad(generation, key: key) else { return }
        isLoading = false
        let badgeRevision = downloadBadgeRevision
        let downloading = await downloadService.isDownloadingAlbum(displayAlbumID)
        guard isCurrentLoad(generation, key: key), badgeRevision == downloadBadgeRevision else { return }
        isDownloadingAlbum = downloading
    }

    private func isCurrentLoad(_ generation: Int, key: LoadKey) -> Bool {
        generation == loadGeneration && !Task.isCancelled && key == LoadKey(serverState)
    }

    private func loadFromAPI(generation: Int, key: LoadKey) async {
        do {
            guard let serverId = key.identity?.serverID else { throw LumaError.serverNotConfigured }

            // Publish the base album before the display-composition pass. `displayAlbum`
            // also resolves the artist and every paired Atmos album, which is useful but
            // must not gate the first track list (and the page transition/lyrics clock)
            // behind an otherwise unrelated network waterfall.
            let baseAlbum = try await libraryService.album(id: albumId)
            guard isCurrentLoad(generation, key: key) else { return }
            // Empty-success guard: behind a captive proxy / Cloudflare-WARP edge the server
            // is reachable but answers 200 with no songs. That never throws, so the catch
            // below can't help — treat an empty result exactly like a failure and prefer the
            // downloaded copy before clobbering the UI with an empty state.
            if (baseAlbum.song ?? []).isEmpty, await loadFromLocal(generation: generation, key: key) { return }
            guard isCurrentLoad(generation, key: key) else { return }
            try await applyAlbumPayload(baseAlbum, generation: generation, key: key)
            guard isCurrentLoad(generation, key: key) else { return }

            // Enrich with variant-exclusive tracks after the base page is on screen.
            // The cache makes the repeated `album(id:)` lookup cheap; only the artist
            // and variant requests remain, and they no longer delay the first frame.
            // A normal album with no known Atmos sibling skips the artist round trip
            // entirely; the local index already tells us whether composition is useful.
            let indexedVariants = libraryIndex?.variantAlbums(for: baseAlbum) ?? []
            let shouldResolveVariants = AtmosAlbumPolicy.isAtmos(baseAlbum.name)
                || !indexedVariants.isEmpty
            if shouldResolveVariants, baseAlbum.artistId != nil,
               let displayAlbum = try? await libraryService.displayAlbum(id: albumId),
               isCurrentLoad(generation, key: key),
               !hasSameTrackList(displayAlbum, baseAlbum) {
                try? await applyAlbumPayload(displayAlbum, generation: generation, key: key)
            }
            guard isCurrentLoad(generation, key: key) else { return }

            // Local file validation and whole-library download reconciliation must not gate album display.
            async let downloadTask: Void = refreshDownloadBadges(serverId: serverId, generation: generation, key: key)
            // Footer credits and More By do not depend on the editorial description.
            // Let them publish even while albumInfo or a description provider is slow.
            async let moreByTask: Void = loadMoreAlbumsByArtist(generation: generation)
            async let recordLabelTask: Void = enrichRecordLabelIfNeeded(generation: generation)
            async let copyrightTask: Void = loadNativeCopyrightIfNeeded(album: baseAlbum, generation: generation)

            let albumInfo = try? await libraryService.albumInfo(id: albumId)
            guard isCurrentLoad(generation, key: key) else { return }
            albumDescription = Self.resolveAlbumDescription(
                infoNotes: albumInfo?.notes,
                songs: baseAlbum.song ?? []
            )
            await enrichDescriptionIfNeeded(musicBrainzId: albumInfo?.musicBrainzId, generation: generation)
            await recordLabelTask
            await copyrightTask
            await moreByTask
            await downloadTask
        } catch {
            guard isCurrentLoad(generation, key: key) else { return }
            if UserFacingError.isCancellation(error) {
                if !isPrimaryContentReady { self.error = .unexpected }
                return
            }
            // Server unreachable (airplane mode with stale isOnline, VPN-satisfied path,
            // server down): fall back to the downloaded copy before surfacing an error.
            if await loadFromLocal(generation: generation, key: key) { return }
            guard isCurrentLoad(generation, key: key) else { return }
            self.error = UserFacingError.from(error)
        }
    }

    /// Applies a raw or display-composed album payload. Only one value snapshot crosses
    /// to the main actor; song normalization stays in `DisplayableSong.prepare`'s worker.
    private func applyAlbumPayload(
        _ album: AlbumID3,
        generation: Int,
        key: LoadKey
    ) async throws {
        let prepared = try await DisplayableSong.prepare(
            album.song ?? [],
            downloadedIDs: Set(songs.lazy.filter(\.isDownloaded).map(\.id)),
            fallbackCoverArtID: album.coverArt,
            sortedBy: Self.albumTrackOrder
        )
        guard isCurrentLoad(generation, key: key) else { return }
        loadedAlbum = album
        albumName = album.name
        artistName = album.artist
        year = album.year
        genre = album.genre
        releaseDate = album.releaseDate ?? album.originalReleaseDate
        recordLabels = (album.recordLabels ?? []).compactMap { label in
            let name = label.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        trackCopyright = Self.findTrackCopyright((album.song ?? []).map(\.comment))
        totalDurationSeconds = album.duration
        songCount = album.songCount
        coverArtId = album.coverArt
        artistId = album.artistId
        songs = prepared
        invalidateAtmosAlternatives()
        isOffline = false
        isPrimaryContentReady = true
        isLoading = false
    }

    private func hasSameTrackList(_ lhs: AlbumID3, _ rhs: AlbumID3) -> Bool {
        guard lhs.id == rhs.id else { return false }
        let left = (lhs.song ?? []).map(\.id)
        let right = (rhs.song ?? []).map(\.id)
        return left == right
    }

    private func refreshDownloadBadges(serverId: UUID, generation: Int, key: LoadKey) async {
        let badgeRevision = downloadBadgeRevision
        let ids = await downloadService.downloadedSongIds(serverId: serverId)
        guard isCurrentLoad(generation, key: key), badgeRevision == downloadBadgeRevision,
              songs.contains(where: { $0.isDownloaded != ids.contains($0.id) }) else { return }
        songs = songs.map { $0.withDownloaded(ids.contains($0.id)) }
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

    private func loadMoreAlbumsByArtist(generation: Int) async {
        guard !presentationSuspended, !Task.isCancelled else { return }
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
    private func loadFromLocal(generation: Int, key: LoadKey) async -> Bool {
        guard let serverId = key.identity?.serverID,
              let data = await downloadService.localAlbumData(albumId: displayAlbumID, serverId: serverId),
              isCurrentLoad(generation, key: key), !data.songs.isEmpty else { return false }
        albumName = data.albumName
        artistName = data.artistName
        coverArtId = data.coverArtId
        songCount = data.songs.count
        songs = data.songs
        invalidateAtmosAlternatives()
        // Downloaded tracks preserve their ID3 comments even though LocalAlbumData
        // has no album-level label field. Also clear a previous credit if absent.
        trackCopyright = Self.findTrackCopyright(data.songs.map(\.comment))
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
        downloadBadgeRevision &+= 1
        isDownloadingAlbum = true
        defer {
            isDownloadingAlbum = false
            downloadBadgeRevision &+= 1
        }
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
        downloadBadgeRevision &+= 1
        defer { downloadBadgeRevision &+= 1 }
        if let id = loadedAlbum?.id { await downloadService.cancelAlbumDownload(albumId: id, serverId: serverId) }
        for song in songs {
            await downloadService.cancelDownload(songId: song.id, serverId: serverId)
        }
        isDownloadingAlbum = false
    }

    func downloadSong(id: String) async {
        guard let song = loadedAlbum?.song?.first(where: { $0.id == id }),
              let serverId = serverState.activeServer?.id else { return }
        downloadBadgeRevision &+= 1
        downloadingIds.insert(id)
        defer {
            downloadingIds.remove(id)
            downloadBadgeRevision &+= 1
        }
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
        downloadBadgeRevision &+= 1
        isDownloadingAlbum = true
        defer {
            isDownloadingAlbum = false
            downloadBadgeRevision &+= 1
        }
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
        downloadBadgeRevision &+= 1
        defer { downloadBadgeRevision &+= 1 }
        try? await downloadService.remove(albumId: displayAlbumID, serverId: serverId)
        songs = songs.map { $0.withDownloaded(false) }
    }
}
