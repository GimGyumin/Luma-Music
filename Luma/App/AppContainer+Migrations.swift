// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftData

// MARK: - Listening history migration

extension AppContainer {
    private nonisolated static let listeningEventsMigratedKey = "luma.listeningEventsMigrated.v1"

    /// Copies legacy `PlaybackEvent` rows from the main store into the CloudKit listening store once.
    nonisolated static func migratePlaybackEventsIfNeeded(
        from main: ModelContainer, to listening: ModelContainer, defaults: UserDefaults = .standard,
        fetch: (ModelContext) throws -> [PlaybackEvent] = { try $0.fetch(FetchDescriptor<PlaybackEvent>()) }
    ) {
        guard !defaults.bool(forKey: listeningEventsMigratedKey) else { return }

        let source = ModelContext(main)
        let destination = ModelContext(listening)
        let legacy: [PlaybackEvent]
        let existingIDs: Set<UUID>
        do {
            legacy = try fetch(source)
            existingIDs = Set(try fetch(destination).map(\.id))
        } catch {
            // A failed read is not an empty store. Leave the marker unset so startup can retry.
            Logger.stats.error("Playback migration read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if legacy.isEmpty {
            defaults.set(true, forKey: listeningEventsMigratedKey)
            return
        }

        var migrated = 0
        for event in legacy where !existingIDs.contains(event.id) {
            destination.insert(
                PlaybackEvent(
                    id: event.id,
                    trackId: event.trackId,
                    trackTitle: event.trackTitle,
                    albumId: event.albumId,
                    albumTitle: event.albumTitle,
                    artistId: event.artistId,
                    artistName: event.artistName,
                    genre: event.genre,
                    timestamp: event.timestamp,
                    durationListened: event.durationListened,
                    trackDuration: event.trackDuration,
                    wasCompleted: event.wasCompleted,
                    serverId: event.serverId
                )
            )
            migrated += 1
        }

        do {
            try destination.save()
            defaults.set(true, forKey: listeningEventsMigratedKey)
            Logger.stats.info("Migrated \(migrated, privacy: .public) playback events into CloudKit listening store")
        } catch {
            Logger.stats.error("Failed to migrate playback events: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Cover art cache invalidation

extension AppContainer {
    private static let coverArtCacheVersionKey = "luma.coverArtCacheVersion"
    private static let currentCoverArtCacheVersion = 5

    /// Invalidate resized derivatives after a decode-format change. Originals, offline
    /// artwork and completion records are independent of the thumbnail pipeline.
    static func invalidateCoverArtCacheIfNeeded(
        artworkCache: ArtworkImageCache, coverArtsDirectory: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        let stored = defaults.integer(forKey: coverArtCacheVersionKey)
        guard stored < currentCoverArtCacheVersion else { return }
        artworkCache.clearCache()
        let directory = coverArtsDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.luma/coverarts")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasSuffix("@thumb") || file.lastPathComponent.hasSuffix("@hero") {
            try? FileManager.default.removeItem(at: file)
        }
        URLCache.shared.removeAllCachedResponses()
        defaults.set(currentCoverArtCacheVersion, forKey: coverArtCacheVersionKey)
        Logger.player.info("ArtworkImageCache: invalidated resized derivatives (version \(stored) → \(currentCoverArtCacheVersion)); original covers retained")
    }

}

// MARK: - Legacy cover art sweep

extension AppContainer {
    private static let artworkLegacySweepKey = "luma.artworkLegacySweep_v2"

    /// One-shot background sweep that deletes untagged cover art files written by
    /// pre-tier builds (plain `{id}` filenames with no `@thumb` / `@hero` suffix).
    ///
    /// These full-res JPEGs can be 2–4 MB each; decoding them at the 240px thumb
    /// size took ~1100ms per file on a background thread, starving the audio decode
    /// thread and causing audible crackling during queue load. ArtworkImageCache no
    /// longer reads them (since the legacy fallback was removed), but they still
    /// waste disk space and could confuse future disk-hit logic. Deleting them here
    /// forces a clean re-download at the correct tier size.
    static func sweepLegacyCoverArtFiles() {
        // Untagged files can be the only offline cover. Original and legacy downloads are retained.
        UserDefaults.standard.set(true, forKey: artworkLegacySweepKey)
    }

}

// MARK: - Audio extension migration

extension AppContainer {
    private static let audioExtMigrationKey = "luma.audioExtMigration_v1"

    /// One-shot migration that fixes downloaded tracks saved with a `.mpeg` extension.
    ///
    /// Root cause: the original DownloadService derived the file extension from the HTTP
    /// Content-Type header. `audio/mpeg` → `.mpeg`, which AVPlayer maps to a video UTI
    /// (public.mpeg) instead of public.mp3, causing silent playback failure for MP3 files.
    ///
    /// This migration:
    /// 1. Purges the ephemeral CacheService (all entries may carry .mpeg).
    /// 2. Renames permanent downloaded files from .mpeg to the correct extension using
    ///    the server-declared `suffix` stored in DownloadedTrack, falling back to a
    ///    MIME-type map when suffix is absent.
    /// 3. Updates the SwiftData filePath records for each successfully renamed file.
    static func migrateAudioExtensionsIfNeeded(
        modelContainer: ModelContainer,
        cacheService: any CacheServiceProtocol
    ) async {
        guard !UserDefaults.standard.bool(forKey: audioExtMigrationKey) else { return }

        await cacheService.clearAll()
        Logger.migration.info("[ExtMigration] Ephemeral audio cache cleared")

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadsDir = docs.appendingPathComponent("app.luma/audio", isDirectory: true)

        let ctx = ModelContext(modelContainer)
        let tracks = (try? ctx.fetch(FetchDescriptor<DownloadedTrack>())) ?? []

        var renamedCount = 0
        var skippedCount = 0

        for track in tracks {
            guard track.filePath.hasSuffix(".mpeg") else { continue }
            let desiredExt: String
            if let s = track.suffix, !s.isEmpty {
                desiredExt = s
            } else {
                desiredExt = Self.audioExtFromMime(track.mimeType)
            }
            guard desiredExt != "mpeg" else { continue }

            let oldPath = track.filePath
            let newPath = String(oldPath.dropLast(".mpeg".count)) + ".\(desiredExt)"
            let oldURL = downloadsDir.appendingPathComponent(oldPath)
            let newURL = downloadsDir.appendingPathComponent(newPath)

            guard FileManager.default.fileExists(atPath: oldURL.path) else {
                Logger.migration.warning("[ExtMigration] File missing, skipping: '\(oldPath, privacy: .public)'")
                skippedCount += 1
                continue
            }
            do {
                if FileManager.default.fileExists(atPath: newURL.path) {
                    try FileManager.default.removeItem(at: newURL)
                }
                try FileManager.default.moveItem(at: oldURL, to: newURL)
                track.filePath = newPath
                let songID = track.songId, serverID = track.serverId
                let assets = (try? ctx.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
                    $0.songId == songID && $0.serverId == serverID
                }))) ?? []
                for asset in assets where asset.filePath == oldPath { asset.filePath = newPath }
                renamedCount += 1
                Logger.migration.info("[ExtMigration] '\(oldPath, privacy: .public)' → '\(newPath, privacy: .public)'")
            } catch {
                Logger.migration.error("[ExtMigration] Rename failed '\(oldPath, privacy: .public)': \(error, privacy: .public)")
                skippedCount += 1
            }
        }

        try? ctx.save()
        UserDefaults.standard.set(true, forKey: audioExtMigrationKey)
        Logger.migration.info("[ExtMigration] Complete: \(renamedCount) renamed, \(skippedCount) skipped")
    }

    // v3: v2 was burned on installs that ran it against an EMPTY download set (fresh install) —
    // it set the done-flag on a clean-but-empty pass, so the scan→remux path was never exercised.
    // The version bump re-runs the migration; both keys bump together so the attempt counter resets.
    private static let m4aFaststartMigrationKey = "luma.m4aFaststartMigration_v3"
    private static let m4aFaststartAttemptsKey = "luma.m4aFaststartMigration_v3_attempts"
    private static let m4aFaststartMaxAttempts = 3

    /// Migration that faststart-remuxes already-downloaded m4a tracks so they play offline through
    /// AudioStreaming (which cannot open non-faststart M4A). Fire-and-forget at boot.
    ///
    /// Retry-safe (unlike v1): the done-flag is set ONLY on a clean pass — save succeeded AND no
    /// track failed to remux. Failed tracks (e.g. a transient export failure at boot) are retried
    /// on the next launch, up to `m4aFaststartMaxAttempts` passes, after which it gives up so a
    /// genuinely irrecoverable file can't trigger an eternal boot-time retry.
    ///
    /// Detection is CONTENT-based (`ftyp` sniff), not extension-based, so a mis-served m4a that an
    /// earlier migration renamed `.mp3` is still caught. A remux REWRITES the bytes, so
    /// `DownloadedTrack.fileSize` is refreshed from the remuxed file (with the same `?? 0` fallback
    /// as the download path, so `downloadedURL`'s `fileSize == 0` escape covers a size-read miss
    /// instead of persisting a stale, mismatched size). Scope: DownloadedTrack only (CachedTrack = Phase 2).
    static func migrateM4AFaststartIfNeeded(modelContainer: ModelContainer) async {
        guard !UserDefaults.standard.bool(forKey: m4aFaststartMigrationKey) else { return }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadsDir = docs.appendingPathComponent("app.luma/audio", isDirectory: true)

        let ctx = ModelContext(modelContainer)
        let tracks = (try? ctx.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
        let remuxer = AudioFaststartRemuxer()

        var remuxedCount = 0
        var failedCount = 0
        var m4aCount = 0
        for track in tracks {
            let fileURL = downloadsDir.appendingPathComponent(track.filePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            // Content sniff, not extension — catches a container with a wrong/renamed extension.
            guard AudioFaststartRemuxer.isM4AContainer(atPath: fileURL.path) else { continue }
            m4aCount += 1
            ManagedAudioStore.shared.acquire(fileURL)
            defer { ManagedAudioStore.shared.release(fileURL) }
            switch await remuxer.remuxToFaststartIfNeeded(at: fileURL) {
            case .remuxed:
                // Bytes changed — refresh fileSize from the remuxed file (?? 0 mirrors the
                // download path, where downloadedURL's `== 0` escape tolerates a read miss).
                let newSize = FileStat.read(fileURL)?.size ?? 0
                track.fileSize = newSize
                let songID = track.songId, serverID = track.serverId
                let assets = (try? ctx.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
                    $0.songId == songID && $0.serverId == serverID
                }))) ?? []
                for asset in assets where asset.filePath == track.filePath {
                    asset.fileSize = newSize
                    asset.transferIdentity = nil
                }
                remuxedCount += 1
                Logger.migration.info("[M4AFaststart] faststart-remuxed '\(track.songId, privacy: .public)'")
            case .failed:
                failedCount += 1
                Logger.migration.warning("[M4AFaststart] export failed '\(track.songId, privacy: .public)' — will retry next boot")
            case .skipped:
                break   // already faststart or not an MP4 container — nothing to do
            }
        }

        // Persist the fileSize updates; only mark done on a clean pass so failures are retried.
        var saveOK = true
        do {
            try ctx.save()
        } catch {
            saveOK = false
            Logger.migration.error("[M4AFaststart] save failed: \(error, privacy: .public) — not marking done, will retry")
        }

        let attempts = UserDefaults.standard.integer(forKey: m4aFaststartAttemptsKey) + 1
        UserDefaults.standard.set(attempts, forKey: m4aFaststartAttemptsKey)
        let giveUp = attempts >= m4aFaststartMaxAttempts
        if saveOK && (failedCount == 0 || giveUp) {
            UserDefaults.standard.set(true, forKey: m4aFaststartMigrationKey)
            if failedCount > 0 {
                Logger.migration.warning("[M4AFaststart] giving up after \(attempts) attempts with \(failedCount) still failing")
            }
        }
        Logger.migration.info("[M4AFaststart] Complete: \(remuxedCount) remuxed, \(failedCount) failed of \(m4aCount) m4a (\(tracks.count) total), attempt \(attempts)")
    }

    private static func audioExtFromMime(_ mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/mpeg", "audio/mp3":        return "mp3"
        case "audio/flac", "audio/x-flac":     return "flac"
        case "audio/aac", "audio/x-aac",
             "audio/aacp":                      return "aac"
        case "audio/mp4", "audio/m4a",
             "audio/x-m4a":                     return "m4a"
        case "audio/ogg":                       return "ogg"
        case "audio/opus":                      return "opus"
        case "audio/wav", "audio/x-wav":       return "wav"
        case "audio/aiff", "audio/x-aiff":     return "aiff"
        case "audio/eac3", "audio/ec3", "audio/ac3": return "ec3"
        default:                                return "mpeg"
        }
    }
}
