import AppIntents
import CoreSpotlight
import Foundation

enum LumaSpotlight {
    static let indexName = "Luma"
}

@available(iOS 27.0, macOS 27.0, *)
extension LumaSongQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [LumaSongEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        await SiriBridge.waitUntilReady()
        try await LumaNativeSearch.shared.reindex(kind: .song, identifiers: identifiers)
    }
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await SiriBridge.waitUntilReady()
        try await LumaNativeSearch.shared.reindex(kind: .song, all: true)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension LumaAlbumQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [LumaAlbumEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        await SiriBridge.waitUntilReady()
        try await LumaNativeSearch.shared.reindex(kind: .album, identifiers: identifiers)
    }
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await SiriBridge.waitUntilReady()
        try await LumaNativeSearch.shared.reindex(kind: .album, all: true)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension LumaArtistQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [LumaArtistEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        await SiriBridge.waitUntilReady()
        try await LumaNativeSearch.shared.reindex(kind: .artist, identifiers: identifiers)
    }
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await SiriBridge.waitUntilReady()
        try await LumaNativeSearch.shared.reindex(kind: .artist, all: true)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension LumaPlaylistQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [LumaPlaylistEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        await SiriBridge.waitUntilReady()
        try await LumaNativeSearch.shared.reindex(kind: .playlist, identifiers: identifiers)
    }
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await SiriBridge.waitUntilReady()
        try await LumaNativeSearch.shared.reindex(kind: .playlist, all: true)
    }
}
