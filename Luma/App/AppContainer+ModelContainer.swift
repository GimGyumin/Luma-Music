// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftData

// MARK: - CloudKit

nonisolated enum LumaCloudKit {
    static let containerIdentifier = "iCloud.com.kyumin.Music.Luma"
}

// MARK: - ModelContainer factory

extension ModelContainer {
    /// Flip to `true` only after joining the Apple Developer Program and restoring iCloud/CloudKit
    /// entitlements — Personal Teams cannot provision iCloud.
    private static let isCloudKitSyncEnabled = false

    private static func cloudKitDatabase(inMemory: Bool) -> ModelConfiguration.CloudKitDatabase {
        guard isCloudKitSyncEnabled, !inMemory else { return .none }
        return .private(LumaCloudKit.containerIdentifier)
    }

    /// Creates the Luma ModelContainer.
    /// - Parameter inMemory: Pass `true` in tests — Swift Testing parallelises tests,
    ///   so each test must create its own in-memory container (never shared).
    ///
    /// Opening a persistent store is deliberately non-destructive. A transient failure such as
    /// a full disk or temporary file lock must never be interpreted as permission to erase data.
    static func luma(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            ServerConfig.self,
            CachedTrack.self,
            DownloadedTrack.self,
            DownloadedAlbum.self,
            DownloadedPlaylist.self,
            QueueSnapshot.self,
            FavoriteRecord.self,
            PinnedItem.self,
            PlaybackSession.self, // kept for schema-mismatch migration safety; see session() below
            PlaybackEvent.self,   // kept for migration into listening(); see listening() below
            CachedLyrics.self,
            SearchHistoryEntry.self,
            LibraryMetadataSong.self,
            PlaylistCoverChoice.self,
            RemoteIDAlias.self,
            RemoteMediaIdentity.self,
            JellyfinCapabilityRecord.self
        ])
        // Local-only: downloads/cache/favorites must not sync via iCloud.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        return try openStore(named: "default", schema: schema, configuration: config)
    }

    /// Opens a store and preserves it on failure so the app can offer an explicit recovery choice.
    private static func openStore(
        named name: String,
        schema: Schema,
        configuration: ModelConfiguration
    ) throws -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            Logger.boot.error(
                "SwiftData store '\(name, privacy: .public)' failed to open; preserving files: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    /// Removes the store file plus `-shm` / `-wal` sidecars used by SQLite.
    private static func removeSwiftDataStoreFiles(at url: URL) {
        let fm = FileManager.default
        for candidate in [
            url,
            URL(fileURLWithPath: url.path + "-shm"),
            URL(fileURLWithPath: url.path + "-wal")
        ] {
            guard fm.fileExists(atPath: candidate.path) else { continue }
            do {
                try fm.removeItem(at: candidate)
            } catch {
                Logger.boot.error(
                    "Failed to remove SwiftData file \(candidate.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Explicit last-resort wipe of all Luma SwiftData files (main + session + listening).
    /// Call only after the user confirms the destructive recovery action.
    static func resetAllLumaStores() {
        let configs: [ModelConfiguration] = [
            ModelConfiguration(isStoredInMemoryOnly: false),
            ModelConfiguration("luma-session", isStoredInMemoryOnly: false),
            ModelConfiguration("luma-listening", isStoredInMemoryOnly: false)
        ]
        for config in configs {
            removeSwiftDataStoreFiles(at: config.url)
        }
        Logger.boot.warning("Reset all Luma SwiftData store files")
    }

    /// CloudKit-backed store for `PlaybackEvent` (Wrapped / listening history).
    ///
    /// Isolated so downloads and cache stay device-local. `PlaybackEvent` remains in
    /// `luma()` only for one-time migration from older installs.
    static func listening(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([PlaybackEvent.self])
        do {
            let config = ModelConfiguration(
                "luma-listening",
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: cloudKitDatabase(inMemory: inMemory)
            )
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            // Portal / entitlement misconfig should not brick the app — fall back to local store.
            Logger.boot.error("CloudKit listening store unavailable, using local-only: \(error.localizedDescription, privacy: .public)")
            let config = ModelConfiguration(
                "luma-listening",
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .none
            )
            return try openStore(named: "luma-listening", schema: schema, configuration: config)
        }
    }

    /// Isolated container for playback session data (queue + position), synced via CloudKit.
    ///
    /// Separating PlaybackSession from the main container means
    /// PlaybackSessionService.savePosition() (every 5 s during playback) no longer
    /// posts change notifications to the main store coordinator. The main context's
    /// @Query<SearchHistoryEntry> never sees these saves, eliminating the continuous
    /// 5-second render cascade that previously fired during all active playback.
    ///
    /// PlaybackSession.self is retained in luma() purely to avoid a schema-mismatch
    /// migration error when opening existing stores from app versions where it lived
    /// in the main container. That table remains in the main store file but is never
    /// written to after this change.
    /// - Parameter inMemory: Pass `true` in tests.
    static func session(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([PlaybackSession.self])
        do {
            let config = ModelConfiguration(
                "luma-session",
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: cloudKitDatabase(inMemory: inMemory)
            )
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            Logger.boot.error("CloudKit session store unavailable, using local-only: \(error.localizedDescription, privacy: .public)")
            let config = ModelConfiguration(
                "luma-session",
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .none
            )
            return try openStore(named: "luma-session", schema: schema, configuration: config)
        }
    }
}
