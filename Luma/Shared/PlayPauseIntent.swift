// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Playback bridge for widget row controls. The app installs the closure during
/// container setup; widget taps never need to foreground the app to resolve a row.
nonisolated enum WidgetPlaybackBridge {
    nonisolated(unsafe) static var playTrack: (@Sendable (String, String?) async -> Void)?
}

/// Plays a specific recently played track from the large widget. String-only
/// parameters keep the intent cheap to construct inside a WidgetKit view.
struct WidgetPlayTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Track"
    static var openAppWhenRun: Bool { false }

    @Parameter var trackID: String
    @Parameter var serverID: String?

    init() {
        trackID = ""
        serverID = nil
    }

    init(trackID: String, serverID: String?) {
        self.trackID = trackID
        self.serverID = serverID
    }

    func perform() async throws -> some IntentResult {
        for _ in 0..<20 {
            if WidgetPlaybackBridge.playTrack != nil { break }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        await WidgetPlaybackBridge.playTrack?(trackID, serverID)
        return .result()
    }
}

nonisolated struct PlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play / Pause"
    /// Widget playback controls must never foreground the app.
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        // A widget tap can arrive while the host app is finishing its background
        // launch. Give the bridge a short window to be installed instead of
        // silently dropping the command and letting the system foreground the app.
        for _ in 0..<20 {
            if NowPlayingBridge.performTogglePlayPause != nil { break }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        await NowPlayingBridge.performTogglePlayPause?()
        return .result()
    }
}
