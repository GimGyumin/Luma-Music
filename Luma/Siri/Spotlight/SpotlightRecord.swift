import Foundation
import SwiftSonic
import CryptoKit

/// An allow-list of searchable metadata. Never contains server URLs, credentials,
/// comments, lyrics, file paths, listening history, or audio payloads.
nonisolated struct SpotlightRecord: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable { case song, album, artist, playlist }
    var kind: Kind
    var serverID: UUID
    var localID: String
    var title: String
    var artist: String? = nil
    var artistID: String? = nil
    var albumArtist: String? = nil
    var albumArtistID: String? = nil
    var relatedArtistNames: [String] = []
    var relatedArtistIDs: [String] = []
    var album: String? = nil
    var albumID: String? = nil
    var genre: String? = nil
    var year: Int? = nil
    var duration: Double? = nil
    var isrc: String? = nil
    var composer: String? = nil
    var summary: String? = nil
    var trackCount: Int? = nil
    var owner: String? = nil
    var coverID: String? = nil
    var isFavorite: Bool? = nil
    var isDownloaded: Bool? = nil

    var entityID: String { LumaEntityID(serverId: serverID, localId: localID).rawValue }
    var key: String { kind.rawValue + ":" + entityID }
    var link: URL? {
        let kind: LumaDeepLink.Kind = switch self.kind {
        case .song: .song; case .album: .album; case .artist: .artist; case .playlist: .playlist
        }
        return LumaDeepLink.url(kind: kind, id: .init(serverId: serverID, localId: localID))
    }
    func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Self.digest(try encoder.encode(self))
    }
    static func digest(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: SHA256.hash(data: data).flatMap { byte in
            [digits[Int(byte >> 4)], digits[Int(byte & 15)]]
        }, as: UTF8.self)
    }
    /// Scope is opaque on disk and in Spotlight; an account/address change under
    /// the same installation UUID must invalidate the previous index as well.
    static func scope(serverID: UUID, address: String, username: String) -> String {
        digest(Data([serverID.uuidString, address, username].joined(separator: "\u{0}").utf8))
    }
    static func records(from snapshot: LibraryIndexService.Snapshot, serverID: UUID) throws -> [Self] {
        let measurement = SpotlightWorkMeasurement("records")
        defer { measurement.end(count: snapshot.songs.count + snapshot.albums.count + snapshot.artists.count + snapshot.playlists.count) }
        var result: [Self] = []
        result.reserveCapacity(snapshot.songs.count + snapshot.albums.count + snapshot.artists.count + snapshot.playlists.count)
        let albumCatalog = Dictionary((snapshot.albumCatalog ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let artistNames = Dictionary(snapshot.artists.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        func contributors(_ song: DisplayableSong) -> [String: String] {
            var pairs = Dictionary((song.contributingArtists ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            if let id = song.artistId, let name = artistNames[id] ?? song.artist { pairs[id] = name }
            return pairs
        }
        var albumRelations: [String: [String: String]] = [:]
        for song in snapshot.songs {
            try Task.checkCancellation()
            if let id = song.albumId { albumRelations[id, default: [:]].merge(contributors(song), uniquingKeysWith: { first, _ in first }) }
        }
        for song in snapshot.songs {
            try Task.checkCancellation()
            let album = song.albumId.flatMap { albumCatalog[$0] }
            let related = contributors(song)
            let relatedIDs = related.keys.sorted()
            result.append(Self(kind: .song, serverID: serverID, localID: song.id, title: song.title,
                artist: song.artist, artistID: song.artistId,
                albumArtist: album?.artist, albumArtistID: album?.artistId,
                relatedArtistNames: relatedIDs.compactMap { related[$0] },
                relatedArtistIDs: relatedIDs,
                album: song.albumName, albumID: song.albumId,
                genre: song.genre, duration: song.duration, isrc: song.isrc, composer: song.displayComposer,
                coverID: song.explicitCoverArtId ?? album?.coverArt ?? song.effectiveCoverArtId))
        }
        for album in snapshot.albums {
            try Task.checkCancellation()
            let detail = albumCatalog[album.id]
            var relation = albumRelations[album.id] ?? [:]
            for artist in detail?.artists ?? [] { relation[artist.id] = artist.name }
            let relatedIDs = relation.keys.sorted()
            result.append(Self(kind: .album, serverID: serverID, localID: album.id, title: album.name,
                artist: album.artist, artistID: detail?.artistId ?? album.artistId,
                albumArtist: album.artist, albumArtistID: detail?.artistId ?? album.artistId,
                relatedArtistNames: relatedIDs.compactMap { relation[$0] }, relatedArtistIDs: relatedIDs,
                genre: detail?.genre, year: detail?.year,
                coverID: album.coverArtId))
        }
        result += snapshot.artists.map { Self(kind: .artist, serverID: serverID, localID: $0.id, title: $0.name, coverID: $0.coverArtId) }
        result += snapshot.playlists.map { Self(kind: .playlist, serverID: serverID, localID: $0.id, title: $0.name,
            summary: $0.summary, trackCount: $0.trackCount, owner: $0.owner, coverID: $0.coverArtId) }
        return result
    }
}
