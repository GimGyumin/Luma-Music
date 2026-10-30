import Foundation
import Testing
import SwiftSonic
@testable import Luma

@Suite("Artist relationship search")
struct ArtistRelationshipSearchTests {
    @Test func coAlbumArtistOwnsAlbumButGuestCreditDoesNot() throws {
        let url = catalogURL(); defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = LibraryIndexService.Snapshot(
            artists: [.init(id: "second", name: "Second Artist", coverArtId: nil)],
            albums: [.init(id: "duo", name: "Joint Album", artist: "First & Second", artistId: "first",
                albumArtistIDs: ["first", "second"], coverArtId: nil)], playlists: [],
            songs: [.init(id: "solo", title: "Solo Track", albumId: "duo", artistId: "first")], date: Date())
        try LibraryCatalogStore.save(snapshot, to: url)
        let hits = try LibraryCatalogStore.search("Second Artist", limit: 20, at: url)
        #expect(hits.albums.map(\.id) == ["duo"])
        #expect(hits.songs.map(\.id) == ["solo"])
    }
    @Test func changedTrackCreditRefreshesUnchangedAlbumSearchTerms() throws {
        let url = catalogURL(); defer { try? FileManager.default.removeItem(at: url) }
        let album = LibraryIndexService.IndexedAlbum(id: "comp", name: "Compilation", artist: "Various", coverArtId: nil)
        var snapshot = LibraryIndexService.Snapshot(artists: [], albums: [album], playlists: [],
            songs: [.init(id: "track", title: "Duet", artist: "ObsoleteSinger", albumId: "comp")], date: Date())
        try LibraryCatalogStore.save(snapshot, to: url)
        #expect(try LibraryCatalogStore.search("ObsoleteSinger", limit: 20, at: url).albums.count == 1)
        snapshot.songs = [.init(id: "track", title: "Duet", artist: "ReplacementSinger", albumId: "comp")]
        try LibraryCatalogStore.save(snapshot, to: url)
        #expect(try LibraryCatalogStore.search("ObsoleteSinger", limit: 20, at: url).isEmpty)
        #expect(try LibraryCatalogStore.search("ReplacementSinger", limit: 20, at: url).albums.count == 1)
    }
    @Test func IDsFindAlbumsAndTracksWhoseCreditsUseAnotherDisplayName() throws {
        let url = catalogURL(); defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = LibraryIndexService.Snapshot(
            artists: [.init(id: "mj", name: "Michael Jackson", coverArtId: nil)],
            albums: [.init(id: "bad", name: "Bad", artist: "MJ", artistId: "mj", coverArtId: nil)],
            playlists: [], songs: [.init(id: "smooth", title: "Smooth Criminal", artist: "Guest credit",
                albumId: "bad", artistId: "guest")], date: Date())
        try LibraryCatalogStore.save(snapshot, to: url)
        let hits = try LibraryCatalogStore.search("Michael Jackson", limit: 20, at: url)
        #expect(hits.albums.map(\.id) == ["bad"])
        #expect(hits.songs.map(\.id) == ["smooth"])
        #expect(hits.relatedIDs == ["album:bad", "song:smooth"])
    }

    @Test func featuredArtistDoesNotClaimOtherCompilationTracks() throws {
        let url = catalogURL(); defer { try? FileManager.default.removeItem(at: url) }
        let guest = ArtistID3(id: "guest", name: "Guest Singer")
        let songs = [
            DisplayableSong(id: "duet", title: "Duet", artist: "Lead", albumId: "collection", artistId: "lead",
                contributingArtists: [guest]),
            DisplayableSong(id: "unrelated", title: "Other Track", artist: "Other", albumId: "collection", artistId: "other")
        ]
        let snapshot = LibraryIndexService.Snapshot(
            artists: [.init(id: "guest", name: guest.name, coverArtId: nil)],
            albums: [.init(id: "collection", name: "Summer", artist: "Various Artists", artistId: "various", coverArtId: nil)],
            playlists: [], songs: songs, date: Date())
        try LibraryCatalogStore.save(snapshot, to: url)
        let hits = try LibraryCatalogStore.search("Guest Singer", limit: 20, at: url)
        #expect(hits.albums.map(\.id) == ["collection"])
        #expect(hits.songs.map(\.id) == ["duet"])
        let albumHits = try LibraryCatalogStore.search("Summer", limit: 20, at: url)
        #expect(Set(albumHits.songs.map(\.id)) == ["duet", "unrelated"])
    }

    @Test func artistEntityIDsRemainPairedWithNames() throws {
        let snapshot = LibraryIndexService.Snapshot(artists: [],
            albums: [.init(id: "comp", name: "Compilation", artist: "Various", coverArtId: nil)],
            playlists: [], songs: [
                .init(id: "a", title: "A", artist: "Zulu", albumId: "comp", artistId: "1"),
                .init(id: "b", title: "B", artist: "Alpha", albumId: "comp", artistId: "2")
            ], date: Date())
        let records = try SpotlightRecord.records(from: snapshot, serverID: UUID())
        let album = try #require(records.first { $0.kind == .album })
        #expect(Dictionary(uniqueKeysWithValues: zip(album.relatedArtistIDs, album.relatedArtistNames)) == ["1": "Zulu", "2": "Alpha"])
        let firstSong = try #require(records.first { $0.localID == "a" && $0.kind == .song })
        #expect(!firstSong.relatedArtistIDs.contains("2"))
    }

    @Test @MainActor func relationshipResultsSurviveUIRanking() async {
        let album = LibraryIndexService.IndexedAlbum(id: "album", name: "Summer", artist: "Various", coverArtId: nil)
        let model = SearchViewModel(libraryService: SearchLibraryStub(), nativeSearch: { _, _ in
            .init(artists: [], albums: [album], playlists: [], relatedIDs: ["album:album"])
        })
        await model.search(query: "Guest Singer", serverReachable: false)
        #expect(model.rankedItems.map(\.id) == ["album:album"])
    }

    @Test func duplicateActivityDeliveryIsSuppressedButLaterTapIsAllowed() {
        let url = LumaDeepLink.url(kind: .song, id: .init(serverId: UUID(), localId: "song"))!
        let now = Date()
        var gate = NativeSearchActionGate()
        let first = gate.claim(url, now: now)
        let duplicate = gate.claim(url, now: now.addingTimeInterval(0.1))
        let later = gate.claim(url, now: now.addingTimeInterval(2))
        #expect(first)
        #expect(!duplicate)
        #expect(later)
    }
    private func catalogURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("artist-search-\(UUID()).sqlite")
    }

    @Test func participatingArtistFindsVariousArtistsAlbum() throws {
        let url = catalogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let song = DisplayableSong(
            id: "track-1", title: "Featured Track", artist: "Michael Jackson",
            albumId: "various-1", albumName: "Summer Collection", artistId: "artist-mj"
        )
        let album = LibraryIndexService.IndexedAlbum(
            id: "various-1", name: "Summer Collection", artist: "Various Artists",
            artistId: "artist-various", coverArtId: nil
        )
        let snapshot = LibraryIndexService.Snapshot(
            artists: [
                .init(id: "artist-mj", name: "Michael Jackson", coverArtId: nil),
                .init(id: "artist-various", name: "Various Artists", coverArtId: nil)
            ],
            albums: [album], playlists: [], songs: [song], date: Date()
        )
        try LibraryCatalogStore.save(snapshot, to: url)

        let hits = try LibraryCatalogStore.search("Michael Jackson", limit: 20, at: url)
        #expect(hits.artists.map(\.id) == ["artist-mj"])
        #expect(hits.albums.map(\.id) == ["various-1"])
        #expect(hits.songs.map(\.id) == ["track-1"])
        #expect(hits.relatedIDs.contains("album:various-1"))
    }

    @Test func relationshipMetadataChangesSpotlightFingerprint() throws {
        let server = UUID()
        let base = SpotlightRecord(kind: .album, serverID: server, localID: "album",
            title: "Summer Collection", albumArtist: "Various Artists",
            albumArtistID: "artist-various")
        var related = base
        related.relatedArtistIDs = ["artist-mj"]
        related.relatedArtistNames = ["Michael Jackson"]
        #expect(try base.fingerprint() != related.fingerprint())
    }
}
