// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData

@Model
final class CachedTrack {
    var id: UUID
    var songId: String
    var serverId: UUID
    var filePath: String        // relative to Documents/app.luma/audio/
    var fileSize: Int64
    var mimeType: String
    var transferIdentity: Data?
    // Display metadata captured when the streaming cache is filled. Optional so
    // existing stores migrate without a versioned schema.
    var title: String?
    var artist: String?
    var artistId: String?
    var albumId: String?
    var album: String?
    var trackNumber: Int?
    var discNumber: Int?
    var durationSeconds: Int?
    var coverArtId: String?
    var genre: String?
    var year: Int?
    var audioFormat: String?
    /// The audio inventory includes automatic entries and user-protected pins.
    var isPinned: Bool?
    var cachedAt: Date
    /// Last successful playback/cache hit. Optional so existing stores migrate
    /// without a versioned schema; `cachedAt` remains the fallback.
    var lastAccessedAt: Date?

    init(
        id: UUID = UUID(),
        songId: String,
        serverId: UUID,
        filePath: String,
        fileSize: Int64,
        mimeType: String,
        cachedAt: Date = Date(),
        lastAccessedAt: Date? = nil
    ) {
        self.id = id
        self.songId = songId
        self.serverId = serverId
        self.filePath = filePath
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.cachedAt = cachedAt
        self.lastAccessedAt = lastAccessedAt ?? cachedAt
    }
}
