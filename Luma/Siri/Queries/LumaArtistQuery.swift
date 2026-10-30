// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Resolves `LumaArtistEntity` values for the system.
@available(iOS 27.0, macOS 27.0, *)
struct LumaArtistQuery: EntityQuery {
    func entities(for identifiers: [LumaArtistEntity.ID]) async throws -> [LumaArtistEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        let identity = await SiriBridge.catalogIdentityProvider?()
        var artists: [LumaArtistEntity] = []
        artists.reserveCapacity(identifiers.count)
        for rawIdentifier in identifiers {
            try Task.checkCancellation()
            guard let identifier = LumaEntityID(rawValue: rawIdentifier) else { continue }
            if let artist = await catalog.artist(id: identifier) {
                artists.append(artist)
            }
        }
        guard identity == (await SiriBridge.catalogIdentityProvider?()) else { throw CancellationError() }
        return artists
    }

    func suggestedEntities() async throws -> [LumaArtistEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.artists(matching: "", limit: 25)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension LumaArtistQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [LumaArtistEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.artists(matching: string, limit: 25)
    }
}
