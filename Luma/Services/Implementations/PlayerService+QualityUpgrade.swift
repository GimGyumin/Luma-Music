// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog

extension PlayerService {
    /// NWPathMonitor calls this even in background playback and when `isOnline` stays true.
    /// Remember a cellular path through a brief offline interval; debounce Wi-Fi flapping.
    func handleNetworkPathChange(_ path: PlaybackNetworkPath) async {
        let current = await MainActor.run { serverService.state.playbackNetworkPath }
        guard current == path, lastPlaybackNetworkPath != path else { return }
        let previous = lastPlaybackNetworkPath
        lastPlaybackNetworkPath = path
        cancelQualityUpgrade()
        // A Wi-Fi-prepared Atmos alternative must be resolved again on a restricted path.
        let restrictsDolby = await MainActor.run {
            !streamingSettings.allowsRemoteDolbyAtmos(isCellular: path.cellular)
        }
        if restrictsDolby {
            cancelPendingPrefetch()
            cancelGaplessBridge()
            nextGaplessPreparationAttempt = .distantPast
        }
        // Any prefetch started while the path allowed originals (crossfade or cache warm) may be
        // downloading lossless bytes. On a limited path it has to resolve again under the new
        // policy; the progress ticker can re-schedule it.
        if (previous?.allowsLosslessUpgrade ?? false) && !path.allowsLosslessUpgrade {
            cancelPendingPrefetch()
        }
        // A gapless next track armed on Wi-Fi is the other half of the same problem: its stream
        // URL is already fixed, so it must be dropped explicitly when this path would transcode it.
        if path.usesCellularQuality {
            await dropPreparedOriginalIfLimitedPathWouldTranscode()
        }
        if path.usesCellularQuality { awaitingUnmeteredPlaybackPath = true }
        guard path.allowsLosslessUpgrade, awaitingUnmeteredPlaybackPath else { return }
        let revision = qualityUpgradeRevision
        qualityUpgradeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1_200)) } catch { return }
            await self?.upgradeCurrentStreamOnWiFi(revision: revision)
        }
    }

    /// Drops a next-track source prepared while the device still had a lossless-capable path,
    /// when the new limited path's quality policy would transcode it. The transition then
    /// resolves under that policy instead of opening a multi-MB original on a slow link.
    /// The track that is already audible is never touched — its buffer stays intact.
    private func dropPreparedOriginalIfLimitedPathWouldTranscode() async {
        guard let next = gaplessBridge.next, let source = gaplessBridge.source else { return }
        let preparedIsOriginal = !source.isLocal && !source.isLiveStream
            && !AudioQualityClassifier.isLossyTranscodeStream(source)
        guard preparedIsOriginal else { return }
        let (configured, measured) = await MainActor.run {
            (streamingSettings.formatForCurrentNetwork(isLimited: true),
             serverService.state.measuredBytesPerSecond)
        }
        guard AdaptiveQualityPolicy.preparedOriginalNeedsReplacement(
            configured: configured,
            sourceBitRateKbps: next.bitRate,
            measuredBytesPerSecond: measured,
            preparedIsOriginal: true
        ) else { return }
        Logger.player.notice(
            "[NETWORK] dropping prepared original '\(next.title, privacy: .public)' — limited path would transcode"
        )
        cancelPendingPrefetch()
        cancelGaplessBridge()
        nextGaplessPreparationAttempt = .distantPast
    }

    func cancelQualityUpgrade() {
        qualityUpgradeRevision &+= 1
        qualityUpgradeTask?.cancel()
        qualityUpgradeTask = nil
        systemEngine.cancelQualityReplacement()
    }

    private func upgradeCurrentStreamOnWiFi(revision: UInt64) async {
        guard revision == qualityUpgradeRevision else { return }
        defer { if revision == qualityUpgradeRevision { qualityUpgradeTask = nil } }
        let context = playbackContext
        let generation = systemPlayback.generation
        guard transport.permitsAudio, systemPlayback.isActive, seekState == .idle,
              !isTrackTransitionPending, !isFadingOut,
              let source = currentSource, !source.isLocal, !source.isLiveStream,
              AudioQualityClassifier.isLossyTranscodeStream(source) else { return }
        let snapshot = await MainActor.run { () -> (DisplayableSong, ServerRequestIdentity)? in
            guard serverService.state.playbackNetworkPath?.allowsLosslessUpgrade == true,
                  state.playbackState == .playing, let song = state.currentTrack,
                  state.duration - state.position > 15,
                  streamingSettings.allowsWiFiLosslessUpgrade,
                  let serverID = serverService.state.activeServer?.id,
                  let identity = try? serverService.state.requestIdentity(for: serverID) else { return nil }
            return (song, identity)
        }
        guard let (song, identity) = snapshot,
              qualityUpgradeIsCurrent(context, generation: generation, revision: revision) else { return }
        let actualSong = source.playbackSong ?? song
        guard PlaybackDecisionPolicy.preservesLosslessOriginal(song: actualSong) else { return }
        Logger.player.notice("[QUALITY-HANDOFF] event=preparing epoch=\(context.epoch, privacy: .public)")
        do {
            guard let replacement = try await mediaResolver.resolveLosslessUpgrade(song: actualSong, serverId: identity.serverID),
                  qualityUpgradeIsCurrent(context, generation: generation, revision: revision),
                  !replacement.isLiveStream, !AudioQualityClassifier.isLossyTranscodeStream(replacement) else { return }
            guard let token = await systemEngine.prepareLosslessReplacement(
                url: replacement.url, headers: replacement.customHeaders, timelineOffset: streamTimeOffset
            ) else {
                Logger.player.notice("[QUALITY-HANDOFF] event=kept_current preparation=\(self.systemEngine.qualityPreparationDiagnostic, privacy: .public)")
                return
            }
            defer { systemEngine.cancelQualityReplacement(id: token) }
            let permitted = await MainActor.run {
                serverService.state.requestIsCurrent(identity)
                    && serverService.state.playbackNetworkPath?.allowsLosslessUpgrade == true
                    && state.currentTrack == song && state.playbackState == .playing
                    && state.duration - state.position > 5
                    && streamingSettings.allowsWiFiLosslessUpgrade
            }
            guard permitted, qualityUpgradeIsCurrent(context, generation: generation, revision: revision) else { return }
            // Nothing below suspends until both source and clock have adopted the running decoder.
            guard systemEngine.commitLosslessReplacement(token) else { return }
            awaitingUnmeteredPlaybackPath = false
            cancelGaplessBridge()
            cancelPendingCacheDownload()
            cancelPendingPrefetch()
            currentSource = source.playbackSong.map { replacement.withPlaybackSong($0) } ?? replacement
            streamTimeOffset = 0
            lastObservedEngineProgress = systemEngine.progress
            progressStallMonitor = PlaybackStallMonitor()
            systemPlayback.resetTrackRecovery()
            didAdaptQualityForCurrentTrack = false
            startSystemPlayerProgressWatchdog(generation: generation)
            Logger.player.notice("[QUALITY-HANDOFF] event=committed epoch=\(context.epoch, privacy: .public) position_s=\(self.lastObservedEngineProgress, format: .fixed(precision: 2), privacy: .public)")
            guard await commitPresentation(context, { state in
                state.isDeliveringTranscodedAudio = false
                return true
            }) else { return }
            await pushPositionSnapshot(rate: 1)
            guard contextIsCurrent(context) else { return }
            await ensureGaplessPreparation()
            guard contextIsCurrent(context) else { return }
            if let oldSession = source.jellyfinPlaybackContext {
                await reportJellyfinStopped(oldSession, position: engineProgress())
            }
            guard contextIsCurrent(context) else { return }
            if let newSession = replacement.jellyfinPlaybackContext {
                await reportJellyfinStarted(newSession, position: engineProgress())
            }
        } catch {
            // A quality improvement is optional. Never turn failure of its second decoder into
            // a failure/pause/restart of the stream that the listener is already hearing.
            Logger.player.notice("[QUALITY-HANDOFF] event=kept_current reason=resolve_unavailable")
        }
    }

    private func qualityUpgradeIsCurrent(_ context: PlaybackContext, generation: UInt64, revision: UInt64) -> Bool {
        contextIsCurrent(context) && revision == qualityUpgradeRevision
            && systemPlayback.isActive && systemPlayback.generation == generation
            && transport.permitsAudio && seekState == .idle && !isTrackTransitionPending && !isFadingOut
    }
}
