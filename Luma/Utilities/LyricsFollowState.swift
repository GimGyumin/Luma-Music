// Luma — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.

/// UI ownership of the lyric viewport. This never changes the audio transport.
nonisolated enum LyricsFollowState: Equatable, Sendable {
    case followingPlayback, userDragging, userReading, seeking, reacquiringFollow, suspended

    var isBrowsing: Bool { self == .userDragging || self == .userReading }
    var allowsAutomaticScroll: Bool {
        self == .followingPlayback || self == .reacquiringFollow || self == .seeking
    }
}
