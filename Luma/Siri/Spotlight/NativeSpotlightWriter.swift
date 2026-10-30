import AppIntents
import CoreSpotlight
import Foundation
import OSLog

/// Sole production owner of the named index. Entity association and attributes
/// are submitted together, never through a second indexAppEntities path.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class NativeSpotlightWriter: SpotlightIndexWriting {
    let index: CSSearchableIndex
    var artwork: SpotlightArtworkStore?

    init(indexName: String = LumaSpotlight.indexName) {
        index = CSSearchableIndex(name: indexName)
    }

    @MainActor func clientState() async throws -> Data? {
        // The non-batch API does not persist client state. The coordinator's
        // durable ledger remains the source of truth for retries.
        nil
    }
    @MainActor func reset() async throws { try await index.deleteAllSearchableItems() }

    @MainActor func apply(upserts: [SpotlightRecord], deletions: [String], scope: String, checkpoint: Data) async throws {
        let counts = Dictionary(grouping: upserts, by: \.kind).mapValues(\.count)
        Logger.siri.info(
            "[SPOTLIGHT] batch started total=\(upserts.count, privacy: .public) delete=\(deletions.count, privacy: .public) songs=\(counts[.song, default: 0], privacy: .public) albums=\(counts[.album, default: 0], privacy: .public) artists=\(counts[.artist, default: 0], privacy: .public) playlists=\(counts[.playlist, default: 0], privacy: .public)"
        )
        var items: [CSSearchableItem] = []
        for record in upserts {
            try Task.checkCancellation()
            let item = item(for: record, scope: scope)
            if let coverID = record.coverID, let artwork {
                item.attributeSet.thumbnailData = await artwork.thumbnail(coverID: coverID, serverID: record.serverID)
            }
            items.append(item)
            if items.count.isMultiple(of: 16) { await Task.yield() }
        }
        // Do not use Core Spotlight's optional begin/end batch mode here. Its
        // state is process-global inside the framework and can be invalidated
        // by a system repair or cancellation. The coordinator still serializes
        // these calls, while the non-batch APIs provide independent completion
        // boundaries that are safe to retry.
        do {
            let measurement = SpotlightWorkMeasurement("spotlight_xpc")
            defer { measurement.end(count: items.count + deletions.count) }
            if !deletions.isEmpty { try await index.deleteSearchableItems(withIdentifiers: deletions) }
            if !items.isEmpty { try await index.indexSearchableItems(items) }
            Logger.siri.info(
                "[SPOTLIGHT] batch succeeded total=\(upserts.count, privacy: .public) delete=\(deletions.count, privacy: .public)"
            )
        } catch {
            Logger.siri.error(
                "[SPOTLIGHT] batch failed total=\(upserts.count, privacy: .public) delete=\(deletions.count, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    func item(for record: SpotlightRecord, scope: String) -> CSSearchableItem {
        let item: CSSearchableItem
        switch record.kind {
        case .song:
            let song = DisplayableSong(id: record.localID, title: record.title, artist: record.artist,
                albumId: record.albumID, albumName: record.album, artistId: record.artistID,
                genre: record.genre, duration: record.duration ?? 0, isrc: record.isrc, displayComposer: record.composer)
            item = CSSearchableItem(appEntity: LumaSongEntity(song: song, serverId: record.serverID))
        case .album:
            var artists: [LumaArtistEntity] = []
            let relations = zip(record.relatedArtistIDs, record.relatedArtistNames)
            for (id, name) in relations {
                artists.append(LumaArtistEntity(
                    id: LumaEntityID(serverId: record.serverID, localId: id).rawValue, name: name))
            }
            if let id = record.albumArtistID, let name = record.albumArtist,
               !artists.contains(where: { $0.id == LumaEntityID(serverId: record.serverID, localId: id).rawValue }) {
                artists.insert(LumaArtistEntity(
                    id: LumaEntityID(serverId: record.serverID, localId: id).rawValue, name: name), at: 0)
            }
            item = CSSearchableItem(appEntity: LumaAlbumEntity(id: record.entityID, title: record.title,
                artistName: LumaEntityDisplay.artistName(record.artist), artists: artists))
        case .artist:
            item = CSSearchableItem(appEntity: LumaArtistEntity(id: record.entityID, name: record.title))
        case .playlist:
            item = CSSearchableItem(appEntity: LumaPlaylistEntity(id: record.entityID, title: record.title,
                owner: record.owner.map { .name($0) }, trackCount: record.trackCount ?? 0))
        }
        item.uniqueIdentifier = record.key
        item.domainIdentifier = scope
        item.expirationDate = .distantFuture
        let attributes = item.attributeSet
        attributes.title = record.title
        attributes.displayName = record.title
        attributes.artist = record.kind == .album ? (record.albumArtist ?? record.artist) : record.artist
        attributes.album = record.kind == .album ? record.title : record.album
        let searchableArtists = ([record.albumArtist, record.artist] + record.relatedArtistNames)
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        attributes.keywords = Array(Set(searchableArtists + [
            record.genre, record.year.map(String.init), record.kind.rawValue,
            record.isFavorite == true ? "Favorite" : nil,
            record.isDownloaded == true ? "Downloaded Offline" : nil
        ].compactMap { $0 }))
        attributes.musicalGenre = record.genre
        attributes.duration = record.duration.map { NSNumber(value: $0) }
        attributes.contentDescription = record.summary
        attributes.contentURL = record.link
        attributes.relatedUniqueIdentifier = record.albumID.map {
            "album:" + LumaEntityID(serverId: record.serverID, localId: $0).rawValue
        }
        attributes.setValue(record.isFavorite.map { NSNumber(value: $0) }, forCustomKey: CSCustomAttributeKey(keyName: "lumaFavorite")!)
        attributes.setValue(record.isDownloaded.map { NSNumber(value: $0) }, forCustomKey: CSCustomAttributeKey(keyName: "lumaDownloaded")!)
        // coverID participates in fingerprints, but remote/authenticated artwork
        // URLs must never enter the system index. Thumbnail support uses only a
        // separately prepared, local, bounded image when one is available.
        return item
    }
}
