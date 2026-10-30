import Foundation
import OSLog

extension PlayerService {
    /// Event-only diagnostics; never called on a render thread or at the progress-tick rate.
    /// The UI sample is labelled separately: it is not evidence of rendered audio position.
    func recordPlaybackDiagnostic(event: String, source: String, target: Double? = nil,
                                  error: PlaybackFailure? = nil) {
        let context = playbackContext
        let before = engineProgress()
        let playerID = systemPlayback.isActive ? systemEngine.playerIdentity
            : (engine as? AudioStreamingPlayerEngine)?.playerIdentity
        let identity = playerID.map { String(describing: $0) } ?? "fake-or-unallocated"
        let stream = currentSource.map {
            SpotlightRecord.digest(Data((RuntimeDiagnostics.sessionID + $0.url.absoluteString).utf8))
        } ?? "none"
        let intent = String(describing: transport.intent)
        let buffer = String(describing: activeEngine.state)
        let network = lastPlaybackNetworkPath.map {
            "online=\($0.online),wifi=\($0.wifi),cellular=\($0.cellular),constrained=\($0.constrained)"
        } ?? "unknown"
        let code = error.map { "\($0.domain):\($0.code)" } ?? "none"
        let after = target ?? before
        Task { @MainActor [state] in
            let track = state.currentTrack.map {
                SpotlightRecord.digest(Data((RuntimeDiagnostics.sessionID + $0.id).utf8))
            } ?? "none"
            Logger.player.notice("[PLAYBACK-DIAG] session_id=\(RuntimeDiagnostics.sessionID, privacy: .public) track_id=\(track, privacy: .public) playback_generation=\(context.epoch, privacy: .public) command=\(context.command, privacy: .public) player_instance_id=\(identity, privacy: .public) event=\(event, privacy: .public) event_source=\(source, privacy: .public) position_before=\(before, privacy: .public) position_after_target=\(after, privacy: .public) ui_position=\(state.position, privacy: .public) playback_intent=\(intent, privacy: .public) queue_revision=\(state.queueRevision, privacy: .public) stream_url_identity=\(stream, privacy: .public) buffer_state=\(buffer, privacy: .public) network_state=\(network, privacy: .public) error_code=\(code, privacy: .public) recovery_reason=\(event == "recovery" ? source : "none", privacy: .public)")
        }
    }
}
