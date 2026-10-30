// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Resolves `LumaPlaylistEntity` values for the system.
@available(iOS 27.0, macOS 27.0, *)
struct LumaPlaylistQuery: EntityQuery {
    func entities(for identifiers: [LumaPlaylistEntity.ID]) async throws -> [LumaPlaylistEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        let identity = await SiriBridge.catalogIdentityProvider?()
        var playlists: [LumaPlaylistEntity] = []
        playlists.reserveCapacity(identifiers.count)
        for rawIdentifier in identifiers {
            try Task.checkCancellation()
            guard let identifier = LumaEntityID(rawValue: rawIdentifier) else { continue }
            if let playlist = await catalog.playlist(id: identifier) {
                playlists.append(playlist)
            }
        }
        guard identity == (await SiriBridge.catalogIdentityProvider?()) else { throw CancellationError() }
        return playlists
    }

    func suggestedEntities() async throws -> [LumaPlaylistEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.playlists(matching: "", limit: 25)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension LumaPlaylistQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [LumaPlaylistEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.playlists(matching: string, limit: 25)
    }
}
