// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Single presentation rule for the quality badge shown in every player surface.
/// The surfaces differ only in whether they may display a live stream and whether
/// the alternate playback file is the authoritative quality source.
@MainActor
enum PlaybackQualityPresentation {
    static func quality(
        for state: PlayerState?,
        isExpensive: Bool,
        usesAlternateTrack: Bool = true,
        allowsLiveStream: Bool = false
    ) -> AudioQualityKind? {
        guard let state,
              allowsLiveStream || !state.isLiveStream,
              let track = state.currentTrack else { return nil }
        let source = usesAlternateTrack ? (state.currentPlaybackTrack ?? track) : track
        return AudioQualityClassifier.displayablePlaybackQuality(
            for: source,
            isExpensive: isExpensive,
            isTranscoding: state.isDeliveringTranscodedAudio
        )
    }
}
