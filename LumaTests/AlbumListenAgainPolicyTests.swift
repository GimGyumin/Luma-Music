import Foundation
import Testing
@testable import Luma

@Suite("Album listen-again policy")
struct AlbumListenAgainPolicyTests {
    @Test func singleTrackNeverQualifiesEvenWhenRepeated() {
        #expect(!AlbumListenAgainPolicy.qualifies(
            distinctTracks: 1, completedTracks: 8, totalListenedSeconds: 2_400,
            averageCompletion: 1
        ))
    }

    @Test func twoDistinctTracksWithACompletionQualify() {
        #expect(AlbumListenAgainPolicy.qualifies(
            distinctTracks: 2, completedTracks: 1, totalListenedSeconds: 60,
            averageCompletion: 0.4
        ))
    }

    @Test func sufficientAlbumListeningQualifiesWithoutACompletionFlag() {
        #expect(AlbumListenAgainPolicy.qualifies(
            distinctTracks: 3, completedTracks: 0, totalListenedSeconds: 180,
            averageCompletion: 0.3
        ))
    }

    @Test func rankingIsRecentThenPlayCountThenStableID() {
        let now = Date(timeIntervalSince1970: 10_000)
        let a = AlbumListenAgainRecommendation(albumId: "a", albumTitle: "A", artistName: "",
            lastPlayed: now, playCount: 2, distinctTrackCount: 2, completedTrackCount: 1, totalListenedSeconds: 200)
        let b = AlbumListenAgainRecommendation(albumId: "b", albumTitle: "B", artistName: "",
            lastPlayed: now.addingTimeInterval(-10), playCount: 9, distinctTrackCount: 4, completedTrackCount: 4, totalListenedSeconds: 900)
        let c = AlbumListenAgainRecommendation(albumId: "c", albumTitle: "C", artistName: "",
            lastPlayed: now, playCount: 2, distinctTrackCount: 2, completedTrackCount: 1, totalListenedSeconds: 200)
        #expect(AlbumListenAgainPolicy.ranked([b, a, c], limit: 3).map(\.albumId) == ["a", "c", "b"])
    }
}
