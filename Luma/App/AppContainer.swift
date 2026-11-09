// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// DI root. Creates and wires all services in dependency order.
/// Passed into the SwiftUI environment via \.appContainer.
/// All stored service references are protocol existentials — fully mockable in tests.
@MainActor
final class AppContainer {
    // Observable state objects — created here so they exist on the MainActor
    // before actors are initialized (actors receive them via init injection).
    let playerState = PlayerState()
    let serverState = ServerState()
    let cacheSettings = CacheSettings()
    let streamingSettings = StreamingSettings()

    let modelContainer: ModelContainer
    /// CloudKit-backed store for listening history (Wrapped / stats). Isolated from downloads/cache.
    let listeningModelContainer: ModelContainer
    let keychainService: any KeychainServiceProtocol
    let mediaIdentityService: MediaIdentityService
    let mediaIdentityReconciliationService: MediaIdentityReconciliationService
    let jellyfinService: JellyfinService
    let jellyfinDiscoveryService = JellyfinLANDiscoveryService()
    let serverService: any ServerServiceProtocol
    let libraryService: any LibraryServiceProtocol
    let homeDiscoveryFeed: HomeDiscoveryFeed
    let cacheService: any CacheServiceProtocol
    let streamingCacheMaintenance: StreamingCacheMaintenance
    let downloadService: any DownloadServiceProtocol
    let mediaResolver: any MediaResolverProtocol
    let playerService: any PlayerServiceProtocol
    let nowPlayingService: any NowPlayingServiceProtocol
    let favoritesService: any FavoritesServiceProtocol
    let pinService: any PinServiceProtocol
    let playlistService: any PlaylistServiceProtocol
    let radioService: any RadioServiceProtocol
    let toastService = ToastService()
    let networkMonitor = NetworkMonitor()
    /// Whether the **active server** (not just the device) is answering. Started by `LumaApp`
    /// once the container is published, alongside `networkMonitor`.
    let serverReachabilityMonitor: ServerReachabilityMonitor
    let sessionService: PlaybackSessionService
    /// Keeps the current artwork and palette across Now Playing presentations.
    let fullPlayerViewModel = FullPlayerViewModel()
    let dominantColorExtractor = DominantColorExtractor()
    let nowPlayingBackgroundPreparation = NowPlayingBackgroundPreparation()
    let artworkImageCache: ArtworkImageCache
    let replayHistory: ReplayHistorySync
    let statsService: StatsService
    private let _player: PlayerService
    let wrappedPlaylistService: WrappedPlaylistService
    let lyricsService: LyricsService
    let widgetSyncService: WidgetSyncService
    let recommendationService: RecommendationService
    let personalMixService: PersonalMixService
    let listenBrainzService: ListenBrainzService
    let externalProvidersStore = ExternalProvidersStore()
    let externalArtworkCache = ExternalArtworkCache()
    let externalArtistImageResolver = ExternalArtistImageResolver()
    let searchHistoryService: SearchHistoryService
    let libraryIndexService: LibraryIndexService
    /// Owns the iOS Live Activity shown while a preparation pass runs. Inert on macOS.
    let libraryPreparationLiveActivity = LibraryPreparationLiveActivityController()
    let libraryPreparationService: LibraryPreparationService
    let replayGainService = ReplayGainService()
    let replayGainSettings = ReplayGainSettings()
    let crossfadeSettings = CrossfadeSettings()
    let gaplessSettings = GaplessSettings()
    let storageManagementService: StorageManagementService
    let albumCoverPreloadService: AlbumCoverPreloadService
    /// Measures the link once per server so "Automatic" quality/route can adapt on a slow cellular
    /// connection without probing on every track.
    let networkSpeedProbe = NetworkSpeedProbe()

    /// `engine` exists so tests can drive a real `PlayerService` with a fake audio engine: the
    /// composition root is otherwise the only place that knows the concrete engine.
    init(inMemory: Bool = false, engine: (any PlaybackEngine)? = nil) throws {
        // In-memory databases must not share real downloads or artwork between tests.
        let temporaryStorage = inMemory ? FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-test-media-\(UUID())", isDirectory: true) : nil
        libraryIndexService = LibraryIndexService(
            serverID: { [serverState] in serverState.activeServer?.id },
            networkAvailable: { [serverState] in serverState.isOnline && serverState.isServerReachable },
            directory: inMemory ? nil : LibraryIndexService.defaultDirectory,
            accountRevision: { [serverState] in serverState.accountRevision },
            cacheScope: { [serverState] in
                guard let account = serverState.activeServer else { return nil }
                return SpotlightRecord.scope(serverID: account.id, address: account.baseURL, username: account.username)
            }
        )
        modelContainer = try ModelContainer.luma(inMemory: inMemory)
        listeningModelContainer = try ModelContainer.listening(inMemory: inMemory)
        sessionService = PlaybackSessionService(modelContainer: try ModelContainer.session(inMemory: inMemory))

        let sourceStore = modelContainer
        let historyStore = listeningModelContainer
        let historyPreparation: Task<Void, Never>? = inMemory ? nil : Task.detached(priority: .utility) {
            Self.migratePlaybackEventsIfNeeded(from: sourceStore, to: historyStore)
        }

        let keychain = KeychainService()
        keychainService = keychain
        mediaIdentityService = MediaIdentityService(modelContainer: modelContainer)

        let cache = CacheService(
            modelContainer: modelContainer,
            maxBytes: cacheSettings.maxCacheBytes,
            cacheDirectory: temporaryStorage?.appendingPathComponent("audio"),
            mediaIdentityService: mediaIdentityService
        )
        cacheService = cache
        streamingCacheMaintenance = StreamingCacheMaintenance(
            cacheService: cache,
            playerState: playerState,
            settings: cacheSettings
        )

        let server = ServerService(state: serverState, keychain: keychain, modelContainer: modelContainer, cacheService: cache)
        serverService = server
        let replay = ReplayHistorySync(server: server, directory: temporaryStorage) { account, url in
            await historyPreparation?.value
            try await StatsService.backupLocalHistory(container: historyStore, serverID: account.localReplayID, to: url)
        }
        replayHistory = replay
        let stats = StatsService(modelContainer: listeningModelContainer, preparation: historyPreparation, replay: replay,
            account: { [serverState] in serverState.activeServer }, songs: { [libraryIndexService] id in libraryIndexService.replaySongs(for: id) })
        statsService = stats
        // One bounded `ping` — no retries (the client builds with `retryPolicy: .none`) — is enough
        // to tell "the device has a route" apart from "the server answers", which is what the
        // server-backed tabs need to know.
        serverReachabilityMonitor = ServerReachabilityMonitor(
            serverState: serverState,
            probe: { try await server.testConnection() }
        )
        let jellyfinDeviceIdentity = JellyfinDeviceIdentity.current()
        jellyfinService = JellyfinService(
            serverService: server,
            keychain: keychain,
            modelContainer: modelContainer,
            deviceIdentity: jellyfinDeviceIdentity
        )
        let lyrics = LyricsService(
            serverService: server,
            modelContainer: modelContainer,
            mediaIdentityService: mediaIdentityService
        )
        lyricsService = lyrics
        wrappedPlaylistService = WrappedPlaylistService(serverService: server, statsService: stats)
        radioService = RadioService(serverService: server)

        let transfers = MediaTransferCoordinator()
        let download = DownloadService(
            serverService: server,
            modelContainer: modelContainer,
            toastService: toastService,
            mediaIdentityService: mediaIdentityService,
            jellyfinService: jellyfinService,
            journal: temporaryStorage.map { BackgroundDownloadJournal(directory: $0.appendingPathComponent("journal")) } ?? .shared,
            storageDirectory: temporaryStorage,
            transferCoordinator: transfers,
            cacheService: cache
        )
        downloadService = download

        let library = LibraryService(serverService: server, modelContainer: modelContainer, downloadService: download, statsService: stats, replay: replay, libraryIndex: libraryIndexService)
        libraryService = library
        homeDiscoveryFeed = HomeDiscoveryFeed(library: library, serverState: serverState, downloads: download)
        mediaIdentityReconciliationService = MediaIdentityReconciliationService(
            modelContainer: modelContainer,
            libraryService: library,
            identityService: mediaIdentityService
        )

        artworkImageCache = ArtworkImageCache(downloadService: download, libraryService: library, serverService: server)
        download.setOriginalArtworkLoader { @MainActor [weak artworkImageCache, serverState] id, serverID in
            guard serverState.activeServer?.id == serverID, let artworkImageCache else { return false }
            return await artworkImageCache.downloadOriginalAndCacheAsHero(coverArtId: id, cacheHero: false)
        }

        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Documents directory unavailable — cannot initialise AppContainer")
        }
        // Shared knowledge, computed once: the bulk cover pass probes this directory to see what a
        // previous run already wrote, and WidgetSyncService copies covers out of it.
        let coversDir = temporaryStorage?.appendingPathComponent("coverarts", isDirectory: true)
            ?? docs.appendingPathComponent("app.luma/coverarts", isDirectory: true)

        albumCoverPreloadService = AlbumCoverPreloadService(
            libraryService: library,
            artworkImageCache: artworkImageCache,
            dominantColorExtractor: dominantColorExtractor,
            playerState: playerState,
            serverState: serverState,
            coversDirectory: coversDir,
            songCoverProvider: { [libraryIndexService] in
                await libraryIndexService.ensureIndexedAndWait(using: library)
                guard libraryIndexService.lastIndexedAt != nil else { throw LumaError.timeout }
                return libraryIndexService.songArtworkSnapshot
            }
        )

        storageManagementService = StorageManagementService(
            modelContainer: modelContainer,
            cacheService: cache,
            downloadService: download,
            externalArtworkCache: externalArtworkCache,
            artworkImageCache: artworkImageCache,
            dominantColorExtractor: dominantColorExtractor,
            albumCoverPreloadService: albumCoverPreloadService
        )

        let resolver = MediaResolver(
            downloadService: download,
            cacheService: cache,
            serverService: server,
            serverState: serverState,
            streamingSettings: streamingSettings,
            mediaIdentityService: mediaIdentityService,
            jellyfinService: jellyfinService,
            speedProbe: networkSpeedProbe,
            libraryIndex: libraryIndexService
        )
        mediaResolver = resolver

        let lbClient = ListenBrainzClient(transport: URLSessionListenBrainzTransport())
        let lb = ListenBrainzService(client: lbClient, keychain: keychain)
        listenBrainzService = lb

        let player = PlayerService(state: playerState, mediaResolver: resolver, serverService: server, sessionService: sessionService, artworkImageCache: artworkImageCache, lyricsService: lyricsService, libraryService: library, cacheService: cache, downloadService: download, cacheSettings: cacheSettings, streamingSettings: streamingSettings, replayGainSettings: replayGainSettings, crossfadeSettings: crossfadeSettings, gaplessSettings: gaplessSettings, toastService: toastService, statsService: stats, listenBrainzService: lb, jellyfinService: jellyfinService, engine: engine ?? AudioStreamingPlayerEngine(), transferCoordinator: transfers)
        _player = player
        playerService = player

        favoritesService = FavoritesService(
            libraryService: library,
            serverState: serverState,
            modelContainer: modelContainer,
            mediaIdentityService: mediaIdentityService
        )

        let coverPreloadForNowPlaying = albumCoverPreloadService
        let coverIndexForNowPlaying = libraryIndexService
        let nowPlaying = NowPlayingService(
            playerService: player,
            artworkImageCache: artworkImageCache,
            serverState: serverState,
            favoritesService: favoritesService,
            preparedCoverIdProvider: { albumId in
                coverPreloadForNowPlaying.preparedCoverArtId(forAlbumId: albumId)
                    ?? albumId.map { coverIndexForNowPlaying.playbackCoverID(for: .init(id: "", title: "", albumId: $0)) }
            }
        )
        nowPlayingService = nowPlaying


        let pin = PinService(modelContainer: modelContainer, serverState: serverState)
        pinService = pin
        let playlist = PlaylistService(serverService: server, modelContainer: modelContainer, downloadService: download)
        playlistService = playlist

        let widgetSync = WidgetSyncService(
            dominantColorExtractor: dominantColorExtractor,
            modelContainer: modelContainer,
            artworkCache: artworkImageCache,
            coversDirectory: coversDir,
            serverState: serverState
        )
        widgetSyncService = widgetSync
        pin.setWidgetSyncService(widgetSync)
        // Any activity left over from a previous run would otherwise sit on the lock screen forever.
        let preparationArtwork = PreparationArtworkStore(cache: artworkImageCache)
        libraryPreparationLiveActivity.artworkProvider = { id in await preparationArtwork.prepare(coverID: id) }
        libraryPreparationLiveActivity.reconcileOnLaunch()
        #if os(iOS)
        // ActivityKit only *starts* an activity from the foreground, so the controller is told when
        // that is true rather than importing UIKit into the Services layer.
        libraryPreparationLiveActivity.isAppActive = {
            UIApplication.shared.applicationState == .active
        }
        #endif
        // Progress publisher for the in-app preparation screen and the iOS Live Activity. The
        // background window is opportunistic: iOS decides when a `BGProcessingTask` runs, and such a
        // pass may only *update* an activity it did not start.
        libraryPreparationService = LibraryPreparationService(
            liveActivity: libraryPreparationLiveActivity,
            serverName: { [serverState] in serverState.activeServer?.displayName ?? "" },
            requestBackgroundContinuation: {
                #if os(iOS)
                LumaApp.scheduleLibraryPreparation()
                #endif
            }
        )
        // The full cover download is the one pass that also runs outside this service — onboarding's
        // first download, the launch-time resume, and the manual download in storage settings. It
        // reports through the same entry point so all of them share the screen and the Live Activity.
        albumCoverPreloadService.reportPreparation = { [libraryPreparationService] snapshot in
            libraryPreparationService.receiveExternalProgress(snapshot)
        }
        albumCoverPreloadService.requestBackgroundContinuation = {
            #if os(iOS)
            LumaApp.scheduleLibraryPreparation()
            #endif
        }

        NowPlayingBridge.performTogglePlayPause = { [weak player] in await player?.togglePlayPause() }
        WidgetPlaybackBridge.playTrack = { [weak player, library, serverState] trackID, serverID in
            guard let player else { return }
            if let serverID {
                let activeID = await MainActor.run { serverState.activeServer?.id.uuidString }
                guard activeID == serverID else { return }
            }
            do {
                let song = try await library.song(id: trackID)
                try await player.play(tracks: [DisplayableSong(from: song)], startIndex: 0)
            } catch {
                // A widget tap is best-effort; the app remains responsible for
                // exposing its normal error UI when the user opens it.
            }
        }

        if #available(iOS 27.0, macOS 27.0, *) {
            SiriBridge.playbackProvider = { [playerService] in playerService }
            SiriBridge.favoritesProvider = { [favoritesService] in favoritesService }
            SiriBridge.playlistProvider = { [playlistService] in playlistService }
            SiriBridge.statsProvider = { [stats] in stats }
            SiriBridge.libraryProvider = { [library] in library }
            SiriBridge.lyricsProvider = { [lyrics] in lyrics }
            SiriBridge.cacheProvider = { [cache] in cache }
            SiriBridge.openURLAction = { url in
                #if os(iOS)
                await MainActor.run { UIApplication.shared.open(url) }
                #elseif os(macOS)
                _ = await MainActor.run { NSWorkspace.shared.open(url) }
                #endif
            }
        }

        let subsonicProvider = SubsonicRecommendationProvider(libraryService: library)
        let lbProvider = ListenBrainzRecommendationProvider(client: lbClient, service: lb, libraryService: library)
        recommendationService = RecommendationService(providers: [lbProvider, subsonicProvider])
        personalMixService = PersonalMixService(libraryService: library, statsService: stats, serverState: serverState)

        searchHistoryService = SearchHistoryService(container: modelContainer)

        // Siri / Apple Intelligence catalog — iOS 27 only. Kept out of the
        // stored-property list because the types are availability-gated; the
        // bridge closure retains the catalog (and its metadata store) directly.
        if #available(iOS 27.0, macOS 27.0, *) {
            let metadataStore = LibraryMetadataStore(modelContainer: modelContainer)
            let catalog = SiriCatalogService(
                libraryService: library,
                metadataStore: metadataStore,
                libraryIndex: libraryIndexService,
                serverState: serverState,
                mediaIdentityService: mediaIdentityService
            )
            SiriBridge.catalogProvider = { [catalog] in catalog }
            SiriBridge.catalogIdentityProvider = { [serverState] in
                await MainActor.run {
                    guard let id = serverState.activeServer?.id else { return nil }
                    return try? serverState.requestIdentity(for: id)
                }
            }
            LumaNativeSearch.shared.accountScope = { [weak serverState] in
                guard let state = serverState, !state.isSigningOut, let account = state.activeServer else { return nil }
                return (account.id, SpotlightRecord.scope(serverID: account.id, address: account.baseURL, username: account.username))
            }
            LumaNativeSearch.shared.persistedSnapshotProvider = { [weak libraryIndexService] serverID, scope in
                await libraryIndexService?.loadPersistedSnapshot(serverID: serverID, scope: scope)
            }
            LumaNativeSearch.shared.configureArtwork(SpotlightArtworkStore(downloads: downloadService))
            LumaNativeSearch.shared.isPlaying = { [playerState] in playerState.playbackState.hasPlaybackIntent }
            let spotlightLocalState = SpotlightLocalStateStore(container: modelContainer)
            LumaNativeSearch.shared.localState = { [downloadService] serverID in
                async let favorites = spotlightLocalState.favorites(serverID: serverID)
                async let downloaded = downloadService.downloadedSongIds(serverId: serverID)
                return try await SpotlightLocalState(favoriteKeys: favorites, downloadedSongs: downloaded)
            }
            libraryIndexService.onSnapshot = { snapshot, serverID in
                LumaNativeSearch.shared.accept(snapshot, serverID: serverID)
            }

        }

        // Defer non-critical disk/network work so it can't race Home's first paint.
        Task(priority: .utility) { [playlist] in
            await AppBootGate.waitForHome()
            await playlist.retryMissingPlaylistDownloads()
        }
        Task(priority: .utility) {
            await AppBootGate.waitForHome()
            await listenBrainzService.loadPersistedState()
        }
        // Library index rebuild is deferred to Search first use — avoid allAlbums(500)
        // contending with Home covers / soft-refresh / personal mixes.
        Task(priority: .background) {
            await externalArtworkCache.runGarbageCollection()
        }
        Task(priority: .background) { [mediaIdentityReconciliationService, jellyfinService, serverState] in
            await AppBootGate.waitForHome()
            guard let serverID = await MainActor.run(body: { serverState.activeServer?.id }) else { return }
            _ = await jellyfinService.capabilities()
            await mediaIdentityReconciliationService.reconcileDownloads(serverID: serverID)
        }
    }

    /// Awaited by LumaApp's `.task` before the UI appears, ensuring
    /// PlayerService→NowPlayingService and PlayerService→WidgetSyncService
    /// wiring is complete before any user interaction is possible.
    func setup() async {
        Self.removeLegacyAMLLData()
        let started = ContinuousClock.now
        await _player.setNowPlayingService(nowPlayingService)
        await _player.setWidgetSyncService(widgetSyncService)
        await _player.setReplayGainService(replayGainService)
        await _player.crossfadeSettingsDidChange()
        await _player.gaplessSettingsDidChange()
        // Register MPRemoteCommandCenter before Siri or background playback can begin.
        // Waiting for Home/session restoration leaves a cold Siri launch without a fully
        // initialized Now Playing session, so Apple Watch sees stale or empty metadata.
        await nowPlayingService.start()
        let elapsed = RuntimeDiagnostics.milliseconds(started.duration(to: .now))
        Logger.boot.notice("[BOOT] setup() done duration_ms=\(elapsed, privacy: .public)")
        RuntimeDiagnostics.mark(.setupReady)
    }

    /// The AMLL TTML Database integration was removed. Drop its cached files and
    /// preferences once so upgrades reclaim the disk space and privacy settings.
    private static func removeLegacyAMLLData() {
        let defaults = UserDefaults.standard
        for key in [
            "luma.amll.enabled",
            "luma.amll.autoSearch",
            "luma.amll.preferOverExisting",
            "luma.amll.allowCellular",
            "luma.amll.wifiOnlyDownloads",
            "luma.amll.offlineCache"
        ] {
            defaults.removeObject(forKey: key)
        }
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        let directory = support
            .appendingPathComponent("app.luma", isDirectory: true)
            .appendingPathComponent("amll", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Call after the user re-enters a missing Keychain password so cached API clients
    /// don't keep failing with `credentialsMissing`.
    func invalidateAPIClientsAfterCredentialChange() async {
        await libraryService.invalidateClientCache()
        await playlistService.invalidateClientCache()
        await radioService.invalidateClientCache()
        DiscoverSectionsCache.clear()
        libraryIndexService.rebuild(using: libraryService)
        albumCoverPreloadService.reconcileChangedCovers()
        if #available(iOS 27.0, macOS 27.0, *) {
            await warmSiriLibrary()
        }
    }

    /// Warms the Siri catalog (song store + Spotlight index) once per server so the
    /// first Siri request on a fresh install / fresh login can resolve entities.
    @available(iOS 27.0, macOS 27.0, *)
    func warmSiriLibrary() async {
        await SiriBridge.catalogProvider?()?.warmLibraryForSiri()
    }

    /// Rebuilds the in-memory library index (artists/albums/playlists) and warms the
    /// Siri catalog. The onboarding preparation screen drives this and shows progress
    /// via libraryIndexService.progress.
    @discardableResult
    func indexLibraryForOnboarding() async -> Bool {
        let ready = await libraryIndexService.rebuildAndWait(using: libraryService)
        guard ready else { return false }
        await albumCoverPreloadService.prepareCachedThemes(albumCovers: libraryIndexService.albumArtworkSnapshot)
        if #available(iOS 27.0, macOS 27.0, *) {
            await warmSiriLibrary()
        }
        return true
    }

    /// Each track may carry distinct embedded artwork, even within one album.
    func playbackCoverId(for song: DisplayableSong?) -> String? {
        song.map { libraryIndexService.playbackCoverID(for: $0) }
    }

    /// All cover ids that can describe the current track. The explicit track
    /// cover comes first (distinct artwork), then the album cover recorded during
    /// library preparation (the id a download stores), then playback/effective.
    func playbackCoverCandidates(for song: DisplayableSong?) -> [String] {
        guard let song else { return [] }
        var ids: [String] = []
        if let own = song.explicitCoverArtId { ids.append(own) }
        if let prepared = preparedCoverId(forAlbumId: song.albumId) { ids.append(prepared) }
        if let playback = playbackCoverId(for: song) { ids.append(playback) }
        ids.append(song.effectiveCoverArtId)
        return ArtworkIdentity.distinct(ids)
    }

    /// Resolves the best *local* artwork for the full player. Permanent downloaded
    /// originals are checked across every candidate before a tiered streaming
    /// derivative; a thumb-only copy must not beat the downloaded album cover.
    func localPlaybackArtwork(for song: DisplayableSong?) async -> (id: String, image: PlatformImage)? {
        let ids = playbackCoverCandidates(for: song)
        for id in ids {
            if let image = await artworkImageCache.loadPlainDiskCover(coverArtId: id, tier: .hero) {
                return (id, image)
            }
        }
        for id in ids {
            if let image = await artworkImageCache.load(coverArtId: id, tier: .hero, allowNetwork: false) {
                return (id, image)
            }
        }
        return nil
    }

    /// Album-id → prepared cover id, for surfaces that only carry the album id (lock screen).
    /// Returns nil when the album was never prepared, so callers fall back to the song's own id.
    func preparedCoverId(forAlbumId albumId: String?) -> String? {
        guard let prepared = albumCoverPreloadService.preparedCoverArtId(forAlbumId: albumId)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !prepared.isEmpty else { return nil }
        return prepared
    }

    /// Developer / diagnostics UserDefaults keys (in-app Settings buttons).
    enum DeveloperSettingsKey {
        /// When true, OnboardingView must not auto-skip for an existing server.
        static let forceOnboardingReplay = "luma.debug.forceOnboardingReplay"
    }

    /// Clears ephemeral caches (audio, lyrics, artwork memory, descriptions, translations).
    /// Does **not** remove offline downloads or server credentials.
    func resetAllCachedData() async {
        await cacheService.clearAll()
        await DescriptionCache.shared.clear()
        TranslationCache.shared.clear()
        await storageManagementService.clearArtworkCaches()
        await storageManagementService.clear(.discover)
        Logger.boot.info("Developer: reset all cached data")
        toastService.showSuccess(String(localized: "Cached data cleared", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }

    /// Clears all caches, streaming artwork tiers, and resets in-app preferences to defaults.
    /// Does **not** remove servers, credentials, listening stats, or search history.
    func resetCachesAndAppSettings() async {
        await cacheService.clearAudioTracksOnly()
        await cacheService.clearLyricsCache()
        await storageManagementService.clear(.descriptions)
        await storageManagementService.clear(.translations)
        await storageManagementService.clear(.discover)
        await storageManagementService.clearArtworkCaches()
        URLCache.shared.removeAllCachedResponses()
        resetAppSettingsToDefaults()
        Logger.boot.info("Reset caches and app settings")
        toastService.showSuccess(String(localized: "Cache and settings reset", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }

    @MainActor
    private func resetAppSettingsToDefaults() {
        artworkImageCache.resetArtworkPreferences()
        let defaults = UserDefaults.standard
        let keys = [
            "luma.cache.maxTracks",
            "luma.cache.maxMegabytes",
            "luma.cache.format",
            "luma.cache.cellular",
            "luma.cache.autoCleanup",
            "luma.cache.lastMaintenanceAt",
            "luma.streaming.wifi",
            "luma.streaming.cellular",
            "luma.streaming.download",
            StreamingSettings.losslessAudioKey,
            "luma.download.automaticAfterStreaming",
            "luma.download.automaticOverCellular",
            "luma.lyrics.largerText",
            "luma.visuals.animatedArtwork",
            BulkArtworkPreference.key,
            IntegrationIntroPreference.listenBrainzKey,
            IntegrationIntroPreference.externalAppsKey,
            "luma.history.enabled",
            "luma.replayGain.enabled",
            "luma.replayGain.mode",
            "luma.replayGain.preAmp",
            "luma.replayGain.preventClipping",
            "luma.crossfade.duration",
            "luma.crossfade.disableForGapless",
            GaplessSettings.enabledKey,
            AppleMusicSettings.enrichKey,
            AppleMusicSettings.hapticsKey,
            AppleMusicSettings.hapticsIntensityKey,
            "isTranslationEnabled",
            "isAutoTranslateEnabled",
            "translationProvider",
            "targetLanguage",
            "translationStrategyPreference",
            "openAIAPIKey",
            LyricsSourcePreference.userDefaultsKey,
            "luma.player.autoExtendEnabled",
            "luma.dominantColor.cache.v8",
        ]
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        LyricsTranslationSettings.registerDefaults()
        AppleMusicSettings.registerDefaults()
        cacheSettings.reloadFromDefaults()
        streamingSettings.reloadFromDefaults()
        replayGainSettings.reloadFromDefaults()
        crossfadeSettings.reloadFromDefaults()
        gaplessSettings.reloadFromDefaults()
        LyricsTranslationSettings.shared.reloadFromDefaults()
        AppleMusicSettings.shared.reloadFromDefaults()
        #if os(iOS)
        MusicHapticsController.shared.refresh()
        #endif
        Task {
            await cacheService.setMaxBytes(cacheSettings.maxCacheBytes)
            await playerService.replayGainSettingsDidChange()
            await playerService.crossfadeSettingsDidChange()
            await playerService.gaplessSettingsDidChange()
        }
    }

    /// Wipes every saved server + Keychain credentials, then re-opens the full onboarding
    /// flow (including Apple Account–style sign-in). Offline downloads are left alone.
    func replayOnboarding() async {
        await playerService.stop()

        #if canImport(UIKit)
        await MainActor.run {
            _ = UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
        #endif

        let serverIds = serverState.servers.map(\.id)
        for id in serverIds {
            do {
                try await serverService.removeServer(id: id)
            } catch {
                Logger.boot.error(
                    "Developer replay: failed to remove server \(id.uuidString, privacy: .public) — \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        await invalidateAPIClientsAfterCredentialChange()

        let defaults = UserDefaults.standard
        defaults.set(true, forKey: DeveloperSettingsKey.forceOnboardingReplay)
        defaults.set(false, forKey: "onboardingComplete")
        Logger.boot.info("Developer: wiped \(serverIds.count, privacy: .public) server(s) and replaying onboarding")
    }
}
