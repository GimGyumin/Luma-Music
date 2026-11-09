import Foundation

/// A locally derived “listen again” album candidate. No server request or synthetic
/// album is created; the album id must come from a real listening event.
nonisolated struct AlbumListenAgainRecommendation: Identifiable, Hashable, Sendable {
    let albumId: String
    let albumTitle: String
    let artistName: String
    let lastPlayed: Date
    let playCount: Int
    let distinctTrackCount: Int
    let completedTrackCount: Int
    let totalListenedSeconds: TimeInterval

    var id: String { albumId }
    var coverArtId: String { albumId }
}

nonisolated enum AlbumListenAgainPolicy {
    static let lookbackDays = 120
    static let minimumDistinctTracks = 2
    static let minimumListenedSeconds: TimeInterval = 120

    /// A single track (even repeated) never proves that the album was listened to.
    /// Two distinct tracks plus either a completion or meaningful aggregate listening
    /// are required; a one-track single is deliberately not promoted as an album re-listen.
    static func qualifies(distinctTracks: Int, completedTracks: Int,
                          totalListenedSeconds: TimeInterval,
                          averageCompletion: Double) -> Bool {
        guard distinctTracks >= minimumDistinctTracks else { return false }
        return completedTracks >= 1
            || totalListenedSeconds >= minimumListenedSeconds
            || averageCompletion >= 0.5
    }

    static func ranked(_ recommendations: [AlbumListenAgainRecommendation],
                       limit: Int) -> [AlbumListenAgainRecommendation] {
        recommendations
            .sorted {
                if $0.lastPlayed != $1.lastPlayed { return $0.lastPlayed > $1.lastPlayed }
                if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
                return $0.albumId < $1.albumId
            }
            .prefix(max(0, limit))
            .map { $0 }
    }
}
