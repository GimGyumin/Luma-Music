// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Keeps non-audio startup work from competing with the first decoded audio frame.
/// This never blocks playback: it only yields the current MainActor task until the
/// engine has confirmed audio, or until a bounded timeout.
@MainActor
enum PlaybackStartupGate {
    static func waitForFirstAudio(
        _ state: PlayerState,
        timeout: Duration = .seconds(4)
    ) async {
        guard state.playbackState.hasPlaybackIntent,
              state.playbackState != .playing else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard !Task.isCancelled else { return }
            if state.playbackState == .playing || !state.playbackState.hasPlaybackIntent {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
