// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import Testing
@testable import Luma

@Suite("Streaming cache maintenance")
struct CacheMaintenanceTests {
    private func makeCache() throws -> (CacheService, ModelContainer, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-cache-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try ModelContainer.luma(inMemory: true)
        let cache = CacheService(modelContainer: container,
                                 maxBytes: CacheService.minMaxBytes,
                                 cacheDirectory: directory,
                                 downloadsDirectory: directory)
        return (cache, container, directory)
    }

    private func insert(_ context: ModelContext, id: String, path: String,
                        size: Int64, accessed: Date, pinned: Bool = false) throws {
        let track = CachedTrack(songId: id, serverId: UUID(), filePath: path,
                                fileSize: size, mimeType: "audio/mpeg",
                                cachedAt: accessed, lastAccessedAt: accessed)
        track.isPinned = pinned ? true : nil
        context.insert(track)
        try context.save()
    }

    @Test func ttlRemovesOnlyOldUnprotectedEntries() async throws {
        let (cache, container, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Date().addingTimeInterval(-60 * 24 * 60 * 60)
        let recent = Date()
        let context = ModelContext(container)
        try insert(context, id: "old", path: "old.mp3", size: 100, accessed: old)
        try insert(context, id: "recent", path: "recent.mp3", size: 100, accessed: recent)
        try insert(context, id: "pinned", path: "pinned.mp3", size: 100, accessed: old, pinned: true)
        for path in ["old.mp3", "recent.mp3", "pinned.mp3"] {
            try Data("audio".utf8).write(to: directory.appendingPathComponent(path))
        }

        let result = await cache.performMaintenance(policy: .manual, reason: .manual)

        #expect(result.removedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.mp3").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recent.mp3").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pinned.mp3").path))
        let lastMaintenance = await cache.lastMaintenanceDate
        #expect(lastMaintenance != nil)
    }

    @Test func permanentDownloadIsNeverARemovalCandidate() async throws {
        let (cache, container, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Date().addingTimeInterval(-90 * 24 * 60 * 60)
        let context = ModelContext(container)
        let serverId = UUID()
        context.insert(DownloadedTrack(songId: "download", serverId: serverId,
                                       filePath: "download.mp3", fileSize: 100,
                                       mimeType: "audio/mpeg", downloadedAt: old,
                                       title: "Download"))
        try insert(context, id: "download", path: "download.mp3", size: 100, accessed: old)
        try Data("audio".utf8).write(to: directory.appendingPathComponent("download.mp3"))

        _ = await cache.performMaintenance(policy: .manual, reason: .manual)

        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("download.mp3").path))
    }

    @Test func activePlaybackAndLRUAreRespected() async throws {
        let (cache, container, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Date().addingTimeInterval(-60 * 24 * 60 * 60)
        let older = old.addingTimeInterval(-60 * 60)
        let context = ModelContext(container)
        // Record sizes exceed the 85% target even though the byte writes are tiny.
        try insert(context, id: "older", path: "older.mp3", size: 300 * 1_024 * 1_024, accessed: older)
        try insert(context, id: "old", path: "old.mp3", size: 300 * 1_024 * 1_024, accessed: old)
        for path in ["older.mp3", "old.mp3"] {
            try Data("audio".utf8).write(to: directory.appendingPathComponent(path))
        }
        let activeURL = directory.appendingPathComponent("older.mp3")
        await cache.retainPlayback(url: activeURL)

        let result = await cache.performMaintenance(policy: .manual, reason: .manual)
        #expect(result.removedCount == 1)
        #expect(FileManager.default.fileExists(atPath: activeURL.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.mp3").path))

        await cache.releasePlayback(url: activeURL)
        let afterRelease = await cache.performMaintenance(policy: .manual, reason: .manual)
        #expect(afterRelease.removedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: activeURL.path))
    }

    @Test func pathTraversalCannotEscapeCacheDirectory() async throws {
        let (cache, container, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.deletingLastPathComponent()
            .appendingPathComponent("luma-cache-escape-\(UUID().uuidString).mp3")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let context = ModelContext(container)
        try insert(context, id: "escape", path: "../\(outside.lastPathComponent)",
                   size: 100, accessed: Date().addingTimeInterval(-60 * 24 * 60 * 60))

        _ = await cache.performMaintenance(policy: .manual, reason: .manual)

        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}
