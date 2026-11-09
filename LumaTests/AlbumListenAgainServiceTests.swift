import Testing
import Foundation
import SwiftData
@testable import Luma

@Suite("Album listen-again service")
struct AlbumListenAgainServiceTests {
    private func dto(albumId: String, track: String, completed: Bool = true,
                     listened: TimeInterval = 180, timestamp: Date = Date(),
                     serverId: String = "srv") -> PlaybackEventDTO {
        PlaybackEventDTO(
            trackId: track,
            trackTitle: track,
            albumId: albumId,
            albumTitle: albumId == "album-a" ? "Album A" : "Album B",
            artistId: "artist",
            artistName: "Artist",
            genre: nil,
            timestamp: timestamp,
            durationListened: listened,
            trackDuration: 200,
            wasCompleted: completed,
            serverId: serverId
        )
    }

    @Test func returnsOnlyAlbumsWithMultipleDistinctTracksAndNoDuplicates() async throws {
        let service = StatsService(modelContainer: try ModelContainer.luma(inMemory: true))
        let now = Date()
        await service.recordPlayback(dto(albumId: "album-a", track: "a1", timestamp: now))
        await service.recordPlayback(dto(albumId: "album-a", track: "a2",
                                         timestamp: now.addingTimeInterval(10)))
        await service.recordPlayback(dto(albumId: "album-b", track: "b1", timestamp: now,
                                         serverId: "srv"))

        let results = await service.albumListenAgainCandidates(serverId: "srv", limit: 3)
        #expect(results.count == 1)
        #expect(results[0].albumId == "album-a")
        #expect(results[0].distinctTrackCount == 2)
    }

    @Test func repeatedSingleTrackIsNotAnAlbumRecommendation() async throws {
        let service = StatsService(modelContainer: try ModelContainer.luma(inMemory: true))
        let now = Date()
        for index in 0..<5 {
            await service.recordPlayback(dto(albumId: "single", track: "only",
                                             timestamp: now.addingTimeInterval(Double(index) * 20)))
        }
        let results = await service.albumListenAgainCandidates(serverId: "srv", limit: 3)
        #expect(results.isEmpty)
    }

    @Test func homeAccessorReturnsAtMostOneAlbum() async throws {
        let service = StatsService(modelContainer: try ModelContainer.luma(inMemory: true))
        let now = Date()
        await service.recordPlayback(dto(albumId: "album-a", track: "a1", timestamp: now))
        await service.recordPlayback(dto(albumId: "album-a", track: "a2", timestamp: now.addingTimeInterval(1)))
        await service.recordPlayback(dto(albumId: "album-b", track: "b1", timestamp: now.addingTimeInterval(2)))
        await service.recordPlayback(dto(albumId: "album-b", track: "b2", timestamp: now.addingTimeInterval(3)))

        let recommendation = await service.albumListenAgainRecommendation(serverId: "srv")
        #expect(recommendation?.albumId == "album-b")
        // The Home card is a single value, not an array of cards.
        #expect(recommendation?.albumTitle == "Album B")
    }
}
