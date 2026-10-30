// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Resolves `LumaSongEntity` values for the system.
///
/// Conforming to `EntityStringQuery` is what lets Siri match a spoken phrase to
/// a song without Spotlight; Phase 7 additionally makes the entity
/// `IndexedEntity` for semantic search.
@available(iOS 27.0, macOS 27.0, *)
struct LumaSongQuery: EntityQuery {
    func entities(for identifiers: [LumaSongEntity.ID]) async throws -> [LumaSongEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        let identity = await SiriBridge.catalogIdentityProvider?()
        var songs: [LumaSongEntity] = []
        songs.reserveCapacity(identifiers.count)
        for rawIdentifier in identifiers {
            try Task.checkCancellation()
            guard let identifier = LumaEntityID(rawValue: rawIdentifier) else { continue }
            if let song = await catalog.song(id: identifier) {
                songs.append(song)
            }
        }
        guard identity == (await SiriBridge.catalogIdentityProvider?()) else { throw CancellationError() }
        return songs
    }

    func suggestedEntities() async throws -> [LumaSongEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.suggestedSongs(limit: 25)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension LumaSongQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [LumaSongEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.songs(matching: string, limit: 25)
    }
}
