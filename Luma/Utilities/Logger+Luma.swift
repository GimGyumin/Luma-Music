// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import OSLog

// All properties are `nonisolated` to prevent SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
// from implicitly isolating them, which would cause concurrency warnings when accessed
// from non-MainActor contexts (actors, background tasks, etc.). Logger is Sendable.
extension Logger {
    nonisolated static let server     = Logger(subsystem: "app.luma.server",     category: "ServerService")
    nonisolated static let player     = Logger(subsystem: "app.luma.player",     category: "PlayerService")
    nonisolated static let library    = Logger(subsystem: "app.luma.library",    category: "LibraryService")
    nonisolated static let cache      = Logger(subsystem: "app.luma.cache",      category: "CacheService")
    nonisolated static let download   = Logger(subsystem: "app.luma.download",   category: "DownloadService")
    nonisolated static let resolver   = Logger(subsystem: "app.luma.resolver",   category: "MediaResolver")
    nonisolated static let nowPlaying = Logger(subsystem: "app.luma.nowplaying", category: "NowPlayingService")
    nonisolated static let keychain   = Logger(subsystem: "app.luma.keychain",   category: "KeychainService")
    nonisolated static let network     = Logger(subsystem: "app.luma.network",    category: "NetworkMonitor")
    nonisolated static let ui         = Logger(subsystem: "app.luma.ui",         category: "UI")
    nonisolated static let favorites   = Logger(subsystem: "app.luma.favorites",  category: "FavoritesService")
    nonisolated static let pin         = Logger(subsystem: "app.luma.pin",        category: "PinService")
    nonisolated static let session     = Logger(subsystem: "app.luma.session",    category: "PlaybackSessionService")
    nonisolated static let playlist    = Logger(subsystem: "app.luma.playlist",   category: "PlaylistService")
    nonisolated static let radio       = Logger(subsystem: "app.luma.radio",      category: "RadioService")
    nonisolated static let discover      = Logger(subsystem: "app.luma.discover",      category: "DiscoverViewModel")
    nonisolated static let dominantColor = Logger(subsystem: "app.luma.dominantColor", category: "DominantColorExtractor")
    nonisolated static let stats         = Logger(subsystem: "app.luma.stats",         category: "StatsService")
    nonisolated static let wrapped       = Logger(subsystem: "app.luma.wrapped",       category: "WrappedPlaylistService")
    nonisolated static let wrappedStory  = Logger(subsystem: "app.luma.wrappedstory",  category: "WrappedStoryPlayer")
    nonisolated static let lyrics        = Logger(subsystem: "app.luma.lyrics",        category: "LyricsService")
    nonisolated static let widget           = Logger(subsystem: "app.luma.widget",           category: "WidgetSyncService")
    nonisolated static let recommendations  = Logger(subsystem: "app.luma.recommendations",  category: "RecommendationService")
    nonisolated static let listenBrainz     = Logger(subsystem: "app.luma.listenbrainz",     category: "ListenBrainz")
    nonisolated static let integrations       = Logger(subsystem: "app.luma.integrations",       category: "Integrations")
    nonisolated static let externalArtwork    = Logger(subsystem: "app.luma.externalartwork",    category: "ExternalArtworkCache")
    nonisolated static let artistArtwork      = Logger(subsystem: "app.luma.artistartwork",      category: "ExternalArtistImageResolver")
    nonisolated static let httpTransport      = Logger(subsystem: "app.luma.transport",          category: "CustomHeadersTransport")
    nonisolated static let artworkCache       = Logger(subsystem: "app.luma.artworkcache",       category: "ArtworkCache")
    nonisolated static let settings           = Logger(subsystem: "app.luma.settings",           category: "Settings")
    nonisolated static let boot               = Logger(subsystem: "app.luma.boot",               category: "Boot")
    nonisolated static let migration          = Logger(subsystem: "app.luma.migration",          category: "Migration")
    nonisolated static let crossfade          = Logger(subsystem: "app.luma.crossfade",          category: "Crossfade")
    nonisolated static let siri               = Logger(subsystem: "app.luma.siri",               category: "Siri")
    nonisolated static let performance        = Logger(subsystem: "app.luma.performance",        category: "PerformanceGovernor")
}
