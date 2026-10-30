// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Resolves `LumaAlbumEntity` values for the system.
@available(iOS 27.0, macOS 27.0, *)
struct LumaAlbumQuery: EntityQuery {
    func entities(for identifiers: [LumaAlbumEntity.ID]) async throws -> [LumaAlbumEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        let identity = await SiriBridge.catalogIdentityProvider?()
        var albums: [LumaAlbumEntity] = []
        albums.reserveCapacity(identifiers.count)
        for rawIdentifier in identifiers {
            try Task.checkCancellation()
            guard let identifier = LumaEntityID(rawValue: rawIdentifier) else { continue }
            if let album = await catalog.album(id: identifier) {
                albums.append(album)
            }
        }
        guard identity == (await SiriBridge.catalogIdentityProvider?()) else { throw CancellationError() }
        return albums
    }

    func suggestedEntities() async throws -> [LumaAlbumEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.albums(matching: "", limit: 25)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension LumaAlbumQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [LumaAlbumEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.albums(matching: string, limit: 25)
    }
}
