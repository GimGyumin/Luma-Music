// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Testing
@testable import Luma

@MainActor
@Suite("Playback startup gate")
struct PlaybackStartupGateTests {
    @Test func waitsForAudioWithoutChangingPlaybackState() async {
        let state = PlayerState()
        state.playbackState = .loading
        let transition = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            state.playbackState = .playing
        }
        await PlaybackStartupGate.waitForFirstAudio(state, timeout: .milliseconds(500))
        await transition.value
        #expect(state.playbackState == .playing)
    }

    @Test func pausedOrIdleStateReturnsImmediately() async {
        let state = PlayerState()
        let clock = ContinuousClock()
        state.playbackState = .paused
        let started = clock.now
        await PlaybackStartupGate.waitForFirstAudio(state, timeout: .seconds(2))
        #expect(started.duration(to: clock.now) < .milliseconds(250))
        state.playbackState = .idle
        await PlaybackStartupGate.waitForFirstAudio(state, timeout: .seconds(2))
        #expect(started.duration(to: clock.now) < .milliseconds(250))
    }
}
