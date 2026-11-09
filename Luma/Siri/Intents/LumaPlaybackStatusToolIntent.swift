import AppIntents
import Foundation

/// Siri AI tool that reports the live Luma playback state without opening the app.
///
/// This is a custom tool (no primary App Schema domain), so it can adopt the
/// iOS 27.3 `ToolIntent` trait while the existing schema intents stay available
/// to Siri's audio domain on iOS 27.0+.
@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct LumaPlaybackStatusToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Check What's Playing"
    static let description = IntentDescription(
        "Reports the song, artist, album, playback state, position, queue, shuffle, and repeat mode currently playing in Luma.",
        categoryName: "Playback"
    )
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        guard let player = await SiriBridge.playbackProvider?() else {
            throw LumaAudioIntentError.playerUnavailable
        }
        let state = player.state
        guard let track = state.currentTrack else {
            return .result(dialog: IntentDialog("Luma isn't playing anything right now."))
        }
        let artist = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let album = track.albumName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let position = Self.time(state.position)
        let duration = Self.time(state.duration)
        let transport: String
        switch state.playbackState {
        case .playing: transport = "playing"
        case .paused: transport = "paused"
        case .buffering: transport = "buffering"
        case .loading: transport = "loading"
        case .recovering: transport = "recovering"
        case .idle: transport = "stopped"
        case .error: transport = "stopped after an error"
        }
        var details = [String]()
        details.append("\(track.title)\(artist.isEmpty ? "" : " by \(artist)")")
        if !album.isEmpty { details.append("from \(album)") }
        details.append("\(transport) at \(position) of \(duration)")
        details.append("queue \(state.queue.count) tracks")
        details.append(state.isShuffled ? "shuffle on" : "shuffle off")
        switch state.repeatMode {
        case .off: details.append("repeat off")
        case .all: details.append("repeat all")
        case .one: details.append("repeat one")
        }
        return .result(dialog: IntentDialog(stringLiteral: details.joined(separator: ", ")))
    }

    private static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
