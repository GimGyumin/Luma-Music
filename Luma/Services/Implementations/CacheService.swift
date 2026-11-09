// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import OSLog
import CryptoKit
import Synchronization

/// Streaming cache for recently-played tracks. FIFO eviction removes the oldest files until
/// their total size fits the user-selected storage capacity.
///
/// One inventory and Documents audio directory serves automatic storage and saved music.
/// Pins are protected from FIFO eviction and clearing automatic storage.
///
/// Populated via the streaming hook in PlayerService (phase 2). MediaResolver reads from this cache
/// between permanent downloads and remote streaming.
actor CacheService: CacheServiceProtocol {
    private let modelContainer: ModelContainer
    private let mediaIdentityService: MediaIdentityService?
    private let cacheDirectory: URL
    private let downloadsDirectory: URL
    private let legacyDirectory: URL?
    private let legacyDownloadsDirectory: URL?
    private var migrationCompleted = false
    private(set) var maxBytes: Int64
    /// Playback-owned cache files. The count is re-entrant because a transition
    /// can resolve the same URL twice before the old source is released.
    private var activePlaybackPaths: [String: Int] = [:]
    private(set) var lastMaintenanceDate: Date?

    nonisolated static let defaultMaxBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    nonisolated static let minMaxBytes: Int64 = 512 * 1_024 * 1_024
    nonisolated static let maxMaxBytes: Int64 = 16 * 1_024 * 1_024 * 1_024
    private nonisolated static let lastMaintenanceKey = "luma.cache.lastMaintenanceAt"

    init(
        modelContainer: ModelContainer,
        maxBytes: Int64 = CacheService.defaultMaxBytes,
        cacheDirectory: URL? = nil,
        mediaIdentityService: MediaIdentityService? = nil,
        downloadsDirectory: URL? = nil,
        legacyCacheDirectory: URL? = nil,
        legacyDownloadsDirectory: URL? = nil
    ) {
        self.modelContainer = modelContainer
        self.mediaIdentityService = mediaIdentityService
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let shared = documents.appendingPathComponent("app.luma/audio", isDirectory: true)
        self.downloadsDirectory = downloadsDirectory ?? cacheDirectory ?? shared
        self.legacyDownloadsDirectory = legacyDownloadsDirectory ?? (cacheDirectory == nil ? documents.appendingPathComponent("app.luma/downloads") : nil)
        self.maxBytes = max(Self.minMaxBytes, min(Self.maxMaxBytes, maxBytes))

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = cacheDirectory ?? shared
        self.legacyDirectory = legacyCacheDirectory ?? (cacheDirectory == nil ? caches.appendingPathComponent("app.luma/audio") : nil)
        let timestamp = UserDefaults.standard.double(forKey: Self.lastMaintenanceKey)
        self.lastMaintenanceDate = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil

        do {
            try FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
            CacheDirectoryBackupPolicy.excludeFromBackup(self.cacheDirectory)
        } catch {
            Logger.cache.debug("CacheService: failed to create cache directory — \(error)")
        }
    }

    /// Preserve old assets before retiring the separate cache/download folders.
    func prepareUnifiedAudio() {
        guard !migrationCompleted else { return }
        ManagedAudioStore.shared.withLock {
            let context = ModelContext(modelContainer)
            var cached = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
            var retired: [URL] = []
            var needsRetry = false
            for entry in cached {
                let target = cacheDirectory.appendingPathComponent(entry.filePath)
                if !FileManager.default.fileExists(atPath: target.path), let legacyDirectory {
                    let old = legacyDirectory.appendingPathComponent(entry.filePath)
                    if FileManager.default.fileExists(atPath: old.path) {
                        try? LocalAudioFileStore.install(old, at: target, sharesImmutableSource: true)
                        if FileManager.default.fileExists(atPath: target.path) { retired.append(old) }
                        else { needsRetry = true }
                    }
                }
                if let legacyDirectory, FileManager.default.fileExists(atPath: target.path) {
                    retired.append(legacyDirectory.appendingPathComponent(entry.filePath))
                }
            }
            let pins = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
            for pin in pins {
                let target = cacheDirectory.appendingPathComponent(pin.filePath)
                if !FileManager.default.fileExists(atPath: target.path), let legacyDownloadsDirectory {
                    let old = legacyDownloadsDirectory.appendingPathComponent(pin.filePath)
                    if FileManager.default.fileExists(atPath: old.path) {
                        if (try? LocalAudioFileStore.install(old, at: target, sharesImmutableSource: true)) != nil { retired.append(old) }
                        else { needsRetry = true }
                    }
                }
                guard FileManager.default.fileExists(atPath: target.path) else { continue }
                if let legacyDownloadsDirectory { retired.append(legacyDownloadsDirectory.appendingPathComponent(pin.filePath)) }
                let entry = cached.first { $0.songId == pin.songId && $0.serverId == pin.serverId }
                    ?? CachedTrack(songId: pin.songId, serverId: pin.serverId, filePath: pin.filePath,
                                   fileSize: pin.fileSize, mimeType: pin.mimeType, cachedAt: pin.downloadedAt)
                if !cached.contains(where: { $0.id == entry.id }) { context.insert(entry); cached.append(entry) }
                if entry.filePath != pin.filePath {
                    retired.append(cacheDirectory.appendingPathComponent(entry.filePath))
                    entry.transferIdentity = nil
                }
                entry.filePath = pin.filePath; entry.fileSize = pin.fileSize; entry.mimeType = pin.mimeType
                entry.isPinned = true
            }
            do {
                try context.save()
                migrationCompleted = !needsRetry
                for old in retired { removeUnreferenced(old) }

            } catch { context.rollback() }
        }
    }

    private func removeUnreferenced(_ url: URL) {
        ManagedAudioStore.shared.withLock {
            guard !ManagedAudioStore.shared.isLeased(url) else { return }
            // Paths outside the shared directory are retired legacy aliases, not active assets.
            if let path = cacheRelativePath(for: url) {
                guard activePlaybackPaths[path] == nil else { return }
                let context = ModelContext(modelContainer)
                let entries = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
                let pins = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
                guard !entries.contains(where: { $0.filePath == path }), !pins.contains(where: { $0.filePath == path }) else { return }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Configuration

    /// Updates the byte capacity and immediately evicts oldest entries when necessary.
    func setMaxBytes(_ value: Int64) async {
        maxBytes = max(Self.minMaxBytes, min(Self.maxMaxBytes, value))
        evictToFitLimit()
    }

    // MARK: - Metadata

    /// Best-effort display metadata for the Downloads surfaces. The audio row
    /// is written by the store call first; this never creates an entry by itself.
    func recordMetadata(_ song: DisplayableSong, serverId: UUID) async {
        let context = ModelContext(modelContainer)
        let songId = song.id
        let sid = serverId
        var descriptor = FetchDescriptor<CachedTrack>(predicate: #Predicate {
            $0.songId == songId && $0.serverId == sid
        })
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first else { return }
        entry.title = song.title
        entry.artist = song.artist
        entry.artistId = song.artistId
        entry.albumId = song.albumId
        entry.album = song.albumName
        entry.trackNumber = song.trackNumber
        entry.discNumber = song.discNumber
        entry.durationSeconds = song.duration > 0 ? Int(song.duration) : nil
        entry.coverArtId = song.coverArtId
        entry.genre = song.genre
        entry.year = song.year
        entry.audioFormat = song.audioFormat
        try? context.save()
    }

    // MARK: - Lookup

    func cachedURL(forSongId songId: String, serverId: UUID) async -> URL? {
        let trace = DiagnosticsCenter.shared.begin(.cacheRead)
        var result = DiagnosticsResult.success
        var hit = false
        defer {
            if hit { trace.increment(.cacheHits) }
            trace.finish(result)
        }
        prepareUnifiedAudio()
        let candidates = await mediaIdentityService?.candidateRemoteIDsInBackground(
            for: songId, serverId: serverId, entityType: .song
        ) ?? [songId]
        guard !Task.isCancelled else {
            result = .cancelled
            return nil
        }
        let entry: (songId: String, filePath: String, fileSize: Int64, mimeType: String)? = {
            let context = ModelContext(modelContainer)
            let sid = serverId
            var descriptor = FetchDescriptor<CachedTrack>(predicate: #Predicate {
                $0.serverId == sid && candidates.contains($0.songId)
            })
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor))?.first.map { ($0.songId, $0.filePath, $0.fileSize, $0.mimeType) }
        }()
        guard let entry, let url = cacheURL(for: entry.filePath) else { return nil }
        // A local file's extension selects the demuxer for AVPlayer. Older builds mapped
        // `audio/aac` to `.m4a`, so raw ADTS AAC was handed to the MP4 parser and failed
        // with -11829/-12860. Treat the mismatch as an invalid entry so the resolver
        // streams instead; the next transfer rewrites it with the correct extension.
        let expectedExtension = audioExtension(mimeType: entry.mimeType)
        if expectedExtension != "bin",
           url.pathExtension.lowercased() != expectedExtension {
            Logger.cache.warning("[LOCAL-AUDIO] cached extension mismatch '\(entry.filePath, privacy: .public)' — \(entry.mimeType, privacy: .public) expects .\(expectedExtension, privacy: .public)")
            DiagnosticsCenter.shared.report(.cache)
            invalidate(songId: entry.songId, serverId: serverId)
            return nil
        }
        // Self-healing covers missing, empty, and size-mismatched files — a partial or
        // corrupt cache file must fall through to stream, never reach the player.
        let diskSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard diskSize > 0, diskSize == entry.fileSize else {
            Logger.cache.warning("Cache record exists but file missing or invalid (disk \(diskSize) bytes, record \(entry.fileSize)): \(entry.filePath, privacy: .public)")
            DiagnosticsCenter.shared.report(.cache)
            invalidate(songId: entry.songId, serverId: serverId)
            return nil
        }
        do { try LocalAudioFileStore.validate(url, size: entry.fileSize, mimeType: entry.mimeType, songID: entry.songId) }
        catch {
            Logger.cache.warning("[LOCAL-AUDIO] rejecting invalid cached payload")
            DiagnosticsCenter.shared.report(.cache)
            invalidate(songId: entry.songId, serverId: serverId)
            return nil
        }
        hit = true
        markAccessed(songId: entry.songId, serverId: serverId)
        return url
    }

    func recordTransfer(_ key: MediaTransferKey) async {
        let context = ModelContext(modelContainer)
        let song = key.songID, server = key.accountID
        guard let entry = try? context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
            $0.songId == song && $0.serverId == server
        })).first else { return }
        entry.transferIdentity = try? JSONEncoder().encode(key)
        try? context.save()
    }

    func completedTransfer(for key: MediaTransferKey) async -> CachedMediaTransfer? {
        let context = ModelContext(modelContainer)
        let song = key.songID, server = key.accountID
        guard let entry = try? context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
            $0.songId == song && $0.serverId == server
        })).first, let identity = entry.transferIdentity,
              (try? JSONDecoder().decode(MediaTransferKey.self, from: identity)) == key else { return nil }
        let mime = entry.mimeType
        guard let url = await cachedURL(forSongId: song, serverId: server) else { return nil }
        let fresh = ModelContext(modelContainer)
        guard let current = try? fresh.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
            $0.songId == song && $0.serverId == server
        })).first, current.transferIdentity == identity, cacheDirectory.appendingPathComponent(current.filePath).standardizedFileURL == url.standardizedFileURL else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return try? CachedMediaTransfer(url: url, response: URLResponse(url: url, mimeType: mime,
            expectedContentLength: size, textEncodingName: nil))
    }

    func touch(songId: String, serverId: UUID) async {
        markAccessed(songId: songId, serverId: serverId)
    }

    /// Avoid a SwiftData write on every progress tick. Five minutes is more than
    /// enough to keep the current track out of age-based cleanup.
    private func markAccessed(songId: String, serverId: UUID, now: Date = Date()) {
        let context = ModelContext(modelContainer)
        let sid = serverId
        guard let entry = try? context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
            $0.songId == songId && $0.serverId == sid
        })).first else { return }
        if let previous = entry.lastAccessedAt, now.timeIntervalSince(previous) < 5 * 60 { return }
        entry.lastAccessedAt = now
        try? context.save()
    }

    // MARK: - Storage

    /// Stores audio data in the cache. Upserts the SwiftData record, then runs FIFO eviction.
    func store(data: Data, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL {
        let trace = DiagnosticsCenter.shared.begin(.cacheWrite)
        var result = DiagnosticsResult.failure
        defer { trace.finish(Task.isCancelled ? .cancelled : result) }
        try Task.checkCancellation()
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        guard Int64(data.count) <= maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let ext = audioExtension(mimeType: mimeType)
        let relativePath = storageName(songId: songId, serverId: serverId) + "." + ext
        let fileURL = cacheDirectory.appendingPathComponent(relativePath)

        let staging = try StagedFileWrite.stage(data, beside: fileURL)
        defer { StagedFileWrite.discard(staging) }
        try LocalAudioFileStore.validate(staging, size: Int64(data.count), mimeType: mimeType, songID: songId)
        try ManagedAudioStore.shared.withLock {
            prepareUnifiedAudio()
            try rejectPinnedReplacement(songId: songId, serverId: serverId)
            try StagedFileWrite.commit(staging, to: fileURL)
            try registerFile(fileURL, size: Int64(data.count), songId: songId, serverId: serverId, mimeType: mimeType)
        }
        result = .success
        return fileURL
    }

    func store(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL {
        try storeFile(sourceURL, songId: songId, serverId: serverId, mimeType: mimeType, transferKey: nil)
    }

    func storeTransferred(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID,
                          mimeType: String, key: MediaTransferKey) async throws -> URL {
        try storeFile(sourceURL, songId: songId, serverId: serverId, mimeType: mimeType, transferKey: key)
    }

    private func storeFile(_ sourceURL: URL, songId: String, serverId: UUID, mimeType: String,
                           transferKey: MediaTransferKey?) throws -> URL {
        let trace = DiagnosticsCenter.shared.begin(.cacheWrite)
        var result = DiagnosticsResult.failure
        defer { trace.finish(Task.isCancelled ? .cancelled : result) }
        try Task.checkCancellation()
        let sourceSize = (try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard sourceSize > 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard sourceSize <= maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let fileURL = cacheDirectory.appendingPathComponent(storageName(songId: songId, serverId: serverId) + "." + audioExtension(mimeType: mimeType))
        let stagingURL = cacheDirectory.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        // Copy into the destination filesystem before atomically publishing it. A failed copy
        // or cancelled download must never replace a complete, playable cache entry.
        try LocalAudioFileStore.install(sourceURL, at: stagingURL, sharesImmutableSource: false)
        let size = (try FileManager.default.attributesOfItem(atPath: stagingURL.path)[.size] as? Int64) ?? 0
        guard size > 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard size <= maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try LocalAudioFileStore.validate(stagingURL, size: size, mimeType: mimeType, songID: songId)
        try Task.checkCancellation()
        try ManagedAudioStore.shared.withLock {
            prepareUnifiedAudio()
            try rejectPinnedReplacement(songId: songId, serverId: serverId)
            try StagedFileWrite.commit(stagingURL, to: fileURL)
            try registerFile(fileURL, size: size, songId: songId, serverId: serverId, mimeType: mimeType, transferKey: transferKey)
        }
        result = .success
        return fileURL
    }

    private func storageName(songId: String, serverId: UUID) -> String {
        SHA256.hash(data: Data((serverId.uuidString + "\u{0}" + songId).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func rejectPinnedReplacement(songId: String, serverId: UUID) throws {
        let context = ModelContext(modelContainer)
        let pins = try context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
            $0.songId == songId && $0.serverId == serverId
        }))
        guard pins.isEmpty else { throw CancellationError() }
    }

    private func registerFile(_ fileURL: URL, size fileSize: Int64, songId: String, serverId: UUID, mimeType: String,
                              transferKey: MediaTransferKey? = nil) throws {
        let relativePath = fileURL.lastPathComponent

        let oldPath: String? = try {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let existing = try context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
                $0.songId == songId && $0.serverId == sid
            })).first
            let oldPath = existing?.filePath
            if let existing {
                guard existing.isPinned != true else { throw CancellationError() }
                existing.filePath = relativePath
                existing.fileSize = fileSize
                existing.mimeType = mimeType
                existing.cachedAt = Date()
                existing.lastAccessedAt = Date()
                existing.transferIdentity = try transferKey.map { try JSONEncoder().encode($0) }
            } else {
                let entry = CachedTrack(songId: songId, serverId: serverId, filePath: relativePath,
                                        fileSize: fileSize, mimeType: mimeType)
                entry.transferIdentity = try transferKey.map { try JSONEncoder().encode($0) }
                context.insert(entry)
            }
            try context.save()
            return oldPath
        }()
        if let oldPath, oldPath != relativePath {
            removeUnreferenced(cacheDirectory.appendingPathComponent(oldPath))
        }

        evictToFitLimit()
        Logger.cache.info("Cached '\(songId, privacy: .public)' (\(fileSize) bytes, \(mimeType, privacy: .public))")
    }

    private func audioExtension(mimeType: String) -> String {
        let normalized = mimeType
            .split(separator: ";", maxSplits: 1)
            .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? "bin"
        switch normalized {
        case "audio/mpeg", "audio/mp3":          return "mp3"
        case "audio/flac", "audio/x-flac":       return "flac"
        // `audio/aac` is an ADTS elementary stream, not an MP4 container. Using `.m4a`
        // here made AVFoundation select the MP4 parser and fail with -11829/-12860.
        case "audio/aac", "audio/x-aac",
             "audio/aacp":                        return "aac"
        case "audio/mp4", "audio/m4a",
             "audio/x-m4a":                       return "m4a"
        case "audio/ogg":                         return "ogg"
        case "audio/opus":                        return "opus"
        case "audio/wav", "audio/x-wav":         return "wav"
        case "audio/aiff", "audio/x-aiff":       return "aiff"
        default:                                  return "bin"
        }
    }

    // MARK: - Eviction

    /// File mutations and their short-lived contexts stay on this actor without suspension.
    /// Hopping to MainActor between the two allowed a newer store to be deleted by an older clear.
    func enforceAutomaticLimit() { evictToFitLimit() }

    // MARK: - Playback ownership

    func retainPlayback(url: URL) async {
        guard let path = cacheRelativePath(for: url) else { return }
        activePlaybackPaths[path, default: 0] += 1
    }

    func releasePlayback(url: URL) async {
        guard let path = cacheRelativePath(for: url),
              let count = activePlaybackPaths[path] else { return }
        if count <= 1 { activePlaybackPaths.removeValue(forKey: path) }
        else { activePlaybackPaths[path] = count - 1 }
    }

    private func cacheRelativePath(for url: URL) -> String? {
        // Keep the lease key in the same lexical form as `CachedTrack.filePath`.
        // Safety against symlink/path escape is enforced by `cacheURL(for:)` at
        // deletion time, not by changing the key on the playback hot path.
        let root = cacheDirectory.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else { return nil }
        return String(candidate.dropFirst(root.count + 1))
    }

    private func cacheURL(for relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else { return nil }
        let root = cacheDirectory.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { return nil }
        return candidate
    }

    // MARK: - Smart maintenance

    func performMaintenance(policy: CacheMaintenancePolicy,
                            reason: CacheMaintenanceReason) async -> CacheMaintenanceResult {
        guard !Task.isCancelled else { return .empty(reason) }
        let trace = DiagnosticsCenter.shared.begin(.cacheMaintenance)
        defer { trace.finish(.success) }
        let now = Date()
        prepareUnifiedAudio()

        let available = readAvailableStorageBytes()
        let maxAge = policy.effectiveMaximumAge(freeBytes: available)
        let target = policy.targetBytes(for: maxBytes, freeBytes: available)
        let context = ModelContext(modelContainer)
        let tracks = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
        let downloads = Set(((try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? [])
            .map(\.filePath))
        var scanned = 0
        var protected = 0
        var candidates: [CachedTrack] = []
        var total = Int64(0)
        let ageThreshold = now.addingTimeInterval(-maxAge)
        let recentThreshold = now.addingTimeInterval(-policy.recentProtection)

        for track in tracks {
            guard !Task.isCancelled else { return .empty(reason) }
            scanned += 1
            total += max(0, track.fileSize)
            let isDownload = track.isPinned == true || downloads.contains(track.filePath)
            let lastUsed = track.lastAccessedAt ?? track.cachedAt
            let isActive = activePlaybackPaths[track.filePath] != nil
                || ManagedAudioStore.shared.isLeased(cacheDirectory.appendingPathComponent(track.filePath))
            if isDownload || isActive || lastUsed >= recentThreshold {
                protected += 1
                continue
            }
            if lastUsed < ageThreshold {
                candidates.append(track)
            }
        }

        // Capacity cleanup is LRU, but still rechecks every protection at delete time.
        if total > target {
            let ordered = tracks
                .filter { track in
                    track.isPinned != true && !downloads.contains(track.filePath)
                        && activePlaybackPaths[track.filePath] == nil
                        && !ManagedAudioStore.shared.isLeased(cacheDirectory.appendingPathComponent(track.filePath))
                }
                .sorted { ($0.lastAccessedAt ?? $0.cachedAt) < ($1.lastAccessedAt ?? $1.cachedAt) }
            var projected = total
            for track in ordered where projected > target {
                if !candidates.contains(where: { $0.id == track.id }) { candidates.append(track) }
                projected -= max(0, track.fileSize)
            }
        }

        let sizes = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, max(0, $0.fileSize)) })
        let paths = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.filePath) })
        try? remove(candidates, in: context)
        let freed = sizes.reduce(Int64(0)) { result, pair in
            guard let path = paths[pair.key], let url = cacheURL(for: path),
                  !FileManager.default.fileExists(atPath: url.path) else { return result }
            return result + pair.value
        }
        lastMaintenanceDate = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastMaintenanceKey)
        return CacheMaintenanceResult(reason: reason, scannedCount: scanned,
            removedCount: candidates.count, freedBytes: freed, protectedCount: protected,
            finishedAt: now, availableBytes: available)
    }

    var availableStorageBytes: Int64? {
        get async { readAvailableStorageBytes() }
    }

    private func readAvailableStorageBytes() -> Int64? {
        let values = try? cacheDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let value = values?.volumeAvailableCapacityForImportantUsage { return value }
        return (try? FileManager.default.attributesOfFileSystem(forPath: cacheDirectory.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private func evictToFitLimit() {
        let context = ModelContext(modelContainer)
        do {
            prepareUnifiedAudio()
            let tracks = try context.fetch(FetchDescriptor<CachedTrack>()).filter { $0.isPinned != true }
            let ordered = tracks.sorted { ($0.lastAccessedAt ?? $0.cachedAt) < ($1.lastAccessedAt ?? $1.cachedAt) }
            var remaining = ordered.reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
            var victims: [CachedTrack] = []
            for track in ordered where remaining > maxBytes {
                victims.append(track)
                remaining -= max(0, track.fileSize)
            }
            try remove(victims, in: context)
        } catch {
            Logger.cache.error("Cache eviction failed — \(error)")
        }
    }

    /// Manually invalidates a single entry (file + record). No-op if not cached.
    func invalidate(songId: String, serverId: UUID) {
        let context = ModelContext(modelContainer)
        do {
            let tracks = try context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
                $0.songId == songId && $0.serverId == serverId
            }))
            try remove(tracks, in: context)
        } catch {
            Logger.cache.error("Cache invalidation failed — \(error)")
        }
    }

    /// The file path identifies legacy/renamed IDs too. Never invalidate another account
    /// or a record that now points to a different cached representation.
    func invalidate(songId: String, serverId: UUID, matching url: URL) async {
        guard url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            == cacheDirectory.standardizedFileURL.resolvingSymlinksInPath().path else { return }
        let path = url.lastPathComponent
        let context = ModelContext(modelContainer)
        do {
            let entries = try context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
                $0.serverId == serverId && $0.filePath == path
            }))
            try remove(entries, in: context)
        } catch { Logger.cache.error("Failed cached-file invalidation: \(error)") }
    }

    /// Delete metadata first. A failed save leaves playable files intact; a failed unlink
    /// is logged rather than discarding the record before the save can be checked.
    private func remove(_ tracks: [CachedTrack], in context: ModelContext) throws {
        guard !tracks.isEmpty else { return }
        let ids = Set(tracks.map(\.id))
        try ManagedAudioStore.shared.withLock {
            let fresh = ModelContext(modelContainer)
            let downloads = Set(((try? fresh.fetch(FetchDescriptor<DownloadedTrack>())) ?? []).map(\.filePath))
            let victims = try fresh.fetch(FetchDescriptor<CachedTrack>()).filter { track in
                guard ids.contains(track.id), track.isPinned != true,
                      !downloads.contains(track.filePath),
                      activePlaybackPaths[track.filePath] == nil,
                      let url = cacheURL(for: track.filePath) else { return false }
                return !ManagedAudioStore.shared.isLeased(url)
            }
            let paths = Set(victims.map(\.filePath))
            victims.forEach { fresh.delete($0) }
            try fresh.save()
            for path in paths {
                if let url = cacheURL(for: path) { removeUnreferenced(url) }
            }
        }
    }

    func clearAll() async {
        await clearAudioTracksOnly()
        await clearLyricsCache()
    }

    func clearAudioTracksOnly() async {
        prepareUnifiedAudio()
        let context = ModelContext(modelContainer)
        do { try remove(context.fetch(FetchDescriptor<CachedTrack>()), in: context) }
        catch { Logger.cache.error("Audio cleanup failed: \(error)") }
    }

    func clearLyricsCache() async {
        let context = ModelContext(modelContainer)
        do { try context.delete(model: CachedLyrics.self); try context.save() }
        catch { Logger.cache.error("Lyrics cleanup failed: \(error)") }
    }

    func clearAllForServer(_ serverId: UUID) async {
        prepareUnifiedAudio()
        let context = ModelContext(modelContainer)
        do {
            try remove(context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate { $0.serverId == serverId })), in: context)
            let lyrics = try context.fetch(FetchDescriptor<CachedLyrics>(predicate: #Predicate { $0.serverId == serverId }))
            lyrics.forEach { context.delete($0) }
            try context.save()
        } catch { Logger.cache.error("Server cache cleanup failed: \(error)") }
    }

    // MARK: - Reporting

    var lyricsUsedBytes: Int64 {
        get async {
            let context = ModelContext(modelContainer)
            let lyrics = (try? context.fetch(FetchDescriptor<CachedLyrics>())) ?? []
            return lyrics.reduce(Int64(0)) { $0 + Int64($1.jsonPayload.count) }
        }
    }

    var lyricsCount: Int {
        get async {
            (try? ModelContext(modelContainer).fetchCount(FetchDescriptor<CachedLyrics>())) ?? 0
        }
    }

    /// Total bytes used by all cached tracks. Used by Settings UI.
    var reclaimableBytes: Int64 {
        get async {
            prepareUnifiedAudio()
            let tracks = (try? ModelContext(modelContainer).fetch(FetchDescriptor<CachedTrack>())) ?? []
            return tracks.filter { $0.isPinned != true }.reduce(0) { $0 + $1.fileSize }
        }
    }

    var usedBytes: Int64 {
        get async {
            prepareUnifiedAudio()
            let tracks = (try? ModelContext(modelContainer).fetch(FetchDescriptor<CachedTrack>())) ?? []
            var seen = Set<String>()
            return tracks.reduce(Int64(0)) { total, track in
                let url = cacheDirectory.appendingPathComponent(track.filePath)
                guard let identity = ArtworkContentStore.fileIdentity(url), seen.insert(identity).inserted else { return total }
                return total + track.fileSize
            }
        }
    }

    var trackCount: Int {
        get async {
            prepareUnifiedAudio()
            return (try? ModelContext(modelContainer).fetchCount(FetchDescriptor<CachedTrack>())) ?? 0
        }
    }
}

/// Backup metadata can synchronously wait on filesystem services. Never perform
/// it on the caller of CacheService.init (normally MainActor), or hold the cache
/// actor while it completes. Concurrent containers share one pending operation.
private nonisolated enum CacheDirectoryBackupPolicy {
    private static let pending = Mutex<Set<URL>>([])
    private static let queue = DispatchQueue(label: "app.luma.cache-backup-metadata", qos: .utility)

    static func excludeFromBackup(_ directory: URL) {
        guard pending.withLock({ $0.insert(directory).inserted }) else { return }
        queue.async {
            defer { _ = pending.withLock { $0.remove(directory) } }
            var url = directory
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try? url.setResourceValues(resources)
        }
    }
}
