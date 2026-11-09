// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import AudioStreaming
import SwiftSonic
import OSLog
import AVFoundation

#if os(iOS)
import AVFAudio
import UIKit
#endif

// Actor-isolated implementation; PlayerService remains the single playback owner.
extension PlayerService {
    /// Temporary device audit tracing; normal launches never set this variable.
    func startPlaybackTrace(reason: String) {
        guard Self.playbackTraceEnabled else { return }
        let attempt = playbackEpoch
        let sourceKind: String = {
            guard let source = currentSource else { return "nil" }
            return source.isLocal ? "local" : "remote"
        }()
        print("[PB-TRACE] start attempt=\(attempt) reason=\(reason) track=\(currentSource?.playbackSong?.id ?? "nil") source=\(sourceKind)")
        Task { [weak self] in
            guard let self else { return }
            for tick in 0..<35 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                print(await self.playbackTraceSnapshot(attempt: attempt, tick: tick + 1))
            }
            print("[PB-TRACE] end attempt=\(attempt)")
        }
    }

    private func playbackTraceSnapshot(attempt: UInt64, tick: Int) async -> String {
        let ui = await MainActor.run {
            (state.playbackState, state.position, state.currentTrack?.id)
        }
        let engineState = activeEngine.state
        let progress = engineProgress()
        let native = systemPlayback.isActive
        let timeControl = native ? systemEngine.timeControlStatus.rawValue : -1
        let buffered = native ? systemEngine.bufferedDuration : -1
        let likely = native ? systemEngine.isLikelyToKeepUp : false
        let streamState = engine.state
        let streamProgress = engine.progress
        let cache = cacheDownloadTask != nil
        let auto = automaticDownloadWork.count
        return "[PB-TRACE] attempt=\(attempt) t=\(tick) ui=\(ui.0) uiPos=\(String(format: "%.2f", ui.1)) track=\(ui.2 ?? "nil") engine=\(engineState) progress=\(String(format: "%.2f", progress)) native=\(native) tc=\(timeControl) buffered=\(String(format: "%.1f", buffered)) likely=\(likely) stream=\(streamState) streamProgress=\(String(format: "%.2f", streamProgress)) cache=\(cache) auto=\(auto)"
    }

    /// Shared by explicit selections, native gapless handoffs and post-stall retries.
    /// A permanent transfer owns the copy only while it is actually scheduled/running.
    func scheduleEphemeralCache(song: DisplayableSong, source: MediaSource, serverId: UUID) {
        guard Self.isAutomaticCacheEnabled,
              cacheDownloadTask == nil,
              case .stream(let streamURL, let headers, _, _, _) = source,
              !source.isJellyfinUniversal, streamURL.pathExtension.lowercased() != "m3u8" else { return }
        let songID = source.playbackSong?.id ?? song.id
        let key = "\(serverId.uuidString):\(songID)"
        let epoch = playbackEpoch
        let id = UUID()
        cacheDownloadID = id
        if Self.playbackTraceEnabled {
            print("[PB-CACHE] scheduled song=\(songID) attempt=\(epoch)")
        }
        cacheDownloadTask = Task {
            defer {
                if cacheDownloadID == id { cacheDownloadTask = nil; cacheDownloadID = nil }
            }
            let (format, revision) = await MainActor.run {
                (cacheSettings.cacheFormat, (try? serverService.state.requestIdentity(for: serverId).revision) ?? 0)
            }
            if let file = await cacheService.cachedURL(forSongId: songID, serverId: serverId) {
                await cacheService.recordMetadata(song, serverId: serverId)
                if epoch == playbackEpoch, !Task.isCancelled { systemEngine.provideSpectrumFile(file, forStream: streamURL) }
                return
            }
            if let file = await downloadService.downloadedOriginalURL(forSongId: songID, serverId: serverId) {
                if epoch == playbackEpoch, !Task.isCancelled { systemEngine.provideSpectrumFile(file, forStream: streamURL) }
                return
            }
            guard LumaPerformance.budget.allowsAutomaticMediaDownloads,
                  !AudioQualityClassifier.shouldBypassEphemeralCache(source.playbackSong ?? song),
                  !automaticDownloadTasks.contains(key) else { return }
            let requestKey = "\(key):\(revision):\(format.rawValue)"
            if Self.playbackTraceEnabled {
                print("[PB-CACHE] wait-start song=\(songID) attempt=\(epoch) format=\(format.rawValue)")
            }
            guard Self.isAutomaticCacheEnabled,
                  cacheDownloadRetry.permits(requestKey), await MainActor.run(body: {
                serverService.state.isOnline
                    && (!serverService.state.isLimitedNetwork || cacheSettings.cacheOverCellular)
                    && serverService.state.activeServer?.id == serverId
            }),
               !(await downloadService.isDownloaded(songId: songID, serverId: serverId)),
               await waitForEstablishedPlayback(of: songID, epoch: epoch),
               epoch == playbackEpoch, !Task.isCancelled else { return }
            if Self.playbackTraceEnabled {
                print("[PB-CACHE] wait-passed song=\(songID) attempt=\(epoch) progress=\(String(format: "%.2f", engineProgress()))")
            }
            let url: URL?
            if format == .matchStream { url = streamURL }
            else {
                let client = try? await serverService.makeSwiftSonicClient()
                url = client?.streamURL(id: songID, maxBitRate: format.subsonicMaxBitRate,
                                        format: format == .flacOriginal ? "raw" : format.subsonicFormat)
            }
            guard let url, Self.isAutomaticCacheEnabled, epoch == playbackEpoch, !Task.isCancelled,
                  LumaPerformance.budget.allowsAutomaticMediaDownloads,
                  !automaticDownloadTasks.contains(key),
                  !(await downloadService.isDownloading(songId: songID, serverId: serverId)),
                  await MainActor.run(body: {
                    serverService.state.isOnline
                    && (!serverService.state.isLimitedNetwork || cacheSettings.cacheOverCellular)
                        && serverService.state.activeServer?.id == serverId
                  }) else { return }
            do {
                if Self.playbackTraceEnabled {
                    print("[PB-CACHE] download-start song=\(songID) attempt=\(epoch)")
                }
                try await downloadAndCache(songId: songID, serverId: serverId, streamURL: url,
                                           customHeaders: headers, using: cacheSession)
                await cacheService.recordMetadata(song, serverId: serverId)
                if let file = await cacheService.cachedURL(forSongId: songID, serverId: serverId),
                   epoch == playbackEpoch, !Task.isCancelled {
                    systemEngine.provideSpectrumFile(file, forStream: streamURL)
                }
                cacheDownloadRetry.succeeded(requestKey)
                if Self.playbackTraceEnabled {
                    print("[PB-CACHE] download-done song=\(songID) attempt=\(epoch) progress=\(String(format: "%.2f", engineProgress()))")
                }
            } catch {
                if Self.playbackTraceEnabled {
                    print("[PB-CACHE] download-failed song=\(songID) attempt=\(epoch) error=\(error)")
                }
                if !Task.isCancelled {
                    cacheDownloadRetry.failed(requestKey, error: error)
                    Logger.player.debug("Cache download failed for '\(songID, privacy: .public)': \(error, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Progress timer

    func scheduleAutomaticDownload(song playingSong: DisplayableSong, serverId: UUID) async {
        guard !Task.isCancelled, LumaPerformance.budget.allowsAutomaticMediaDownloads,
              UserDefaults.standard.bool(forKey: Self.automaticDownloadUserDefaultsKey) else { return }
        let epoch = playbackEpoch
        let playingSongID = playingSong.id
        let logicalSong = await MainActor.run { state.currentTrack ?? playingSong }
        let atmosSong = await mediaResolver.preferredAtmosDownloadSong(for: logicalSong, serverId: serverId)
        let song = atmosSong ?? logicalSong
        let preservesOriginal = atmosSong != nil
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        guard LumaPerformance.budget.allowsAutomaticMediaDownloads else { return }
        guard UserDefaults.standard.bool(forKey: Self.automaticDownloadUserDefaultsKey) else { return }
        let alreadyDownloaded = preservesOriginal
            ? await downloadService.downloadedOriginalURL(forSongId: song.id, serverId: serverId) != nil
            : await downloadService.isDownloaded(songId: song.id, serverId: serverId)
        guard !alreadyDownloaded,
              !(await downloadService.isDownloading(songId: song.id, serverId: serverId)) else { return }
        if AudioQualityClassifier.isDolbyAudio(song) {
            guard await MainActor.run(body: {
                streamingSettings.allowsRemoteDolbyAtmos(isCellular: serverService.state.isCellularConnection)
            }) else { return }
        }
        let (isLimited, allowCellular) = await MainActor.run {
            (
                serverService.state.isLimitedNetwork,
                UserDefaults.standard.bool(forKey: Self.automaticDownloadOverCellularUserDefaultsKey)
            )
        }
        guard Self.shouldAllowAutomaticDownload(
            isLimited: isLimited,
            allowCellular: allowCellular
        ) else {
            Logger.download.debug("Automatic download skipped — cellular use is disabled")
            return
        }
        let key = "\(serverId.uuidString):\(song.id)"
        let requestKey = await MainActor.run {
            let revision = (try? serverService.state.requestIdentity(for: serverId).revision) ?? 0
            return "\(key):\(revision):\(preservesOriginal ? CacheFormat.flacOriginal.rawValue : streamingSettings.effectiveDownloadFormat.rawValue)"
        }
        guard automaticDownloadRetry.permits(requestKey) else { return }
        guard epoch == playbackEpoch, !Task.isCancelled,
              automaticDownloadTasks.insert(key).inserted else { return }
        let workID = UUID()
        let task = Task {
            defer {
                if automaticDownloadWork[key]?.id == workID {
                    automaticDownloadWork[key] = nil
                    automaticDownloadTasks.remove(key)
                }
            }
            let scheduledAt = Date()
            // A second full-file request beside a stream that is still opening can starve the
            // foreground request, especially for lossless originals. Wait until the media clock
            // proves that this exact track is producing audio before sharing the connection.
            guard epoch == playbackEpoch,
                  await waitForEstablishedPlayback(of: playingSongID, epoch: epoch),
                  epoch == playbackEpoch else { return }
            if isLimited {
                // Preserve the existing 45-second limited-network grace period, counting time
                // already spent establishing playback.
                let remaining = max(0, 45 - Date().timeIntervalSince(scheduledAt))
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                let stillPlayingThisTrack = await MainActor.run {
                    state.playbackState == .playing && (state.currentPlaybackTrack?.id ?? state.currentTrack?.id) == playingSongID
                }
                guard stillPlayingThisTrack else { return }
            }
            guard LumaPerformance.budget.allowsAutomaticMediaDownloads,
                  await MainActor.run(body: {
                let automaticDownloadsEnabled = UserDefaults.standard.bool(
                    forKey: Self.automaticDownloadUserDefaultsKey
                )
                let cellularAllowed = UserDefaults.standard.bool(
                    forKey: Self.automaticDownloadOverCellularUserDefaultsKey
                )
                return automaticDownloadsEnabled
                    && serverService.state.isOnline
                    && serverService.state.activeServer?.id == serverId
                    && (!AudioQualityClassifier.isDolbyAudio(song)
                        || streamingSettings.allowsRemoteDolbyAtmos(isCellular: serverService.state.isCellularConnection))
                    && Self.shouldAllowAutomaticDownload(
                        isLimited: serverService.state.isLimitedNetwork,
                        allowCellular: cellularAllowed
                    )
            }) else { return }
            do {
                let downloadableSong = await MainActor.run { song.asSong() }
                guard epoch == playbackEpoch, !Task.isCancelled else { return }
                if preservesOriginal {
                    try await downloadService.downloadOriginal(song: downloadableSong, serverId: serverId)
                } else {
                    try await downloadService.download(song: downloadableSong, serverId: serverId)
                }
                automaticDownloadRetry.succeeded(requestKey)
                guard epoch == playbackEpoch, !Task.isCancelled else { return }
                // Normally playback is already healthy, so this is a no-op. If the engine fell
                // back into acquisition while the transfer finished, immediately use the valid
                // local file instead of continuing to wait on the remote response.
                let visibleSong = await MainActor.run {
                    (state.currentPlaybackTrack?.id ?? state.currentTrack?.id) == song.id ? state.currentTrack : nil
                }
                if let visibleSong { _ = await recoverAcquiringPlaybackFromLocalMedia(
                    song: visibleSong,
                    serverId: serverId,
                    expectedEpoch: epoch,
                    reason: "automatic download completed"
                ) }
            } catch {
                if Task.isCancelled || PlaybackFailure.classify(error).kind == .cancelled { return }
                automaticDownloadRetry.failed(requestKey, error: error)
                Logger.download.error("Automatic download failed for '\(song.id, privacy: .public)': \(error, privacy: .public)")
            }
        }
        automaticDownloadWork[key] = (workID, task)
    }

    /// Waits for a real advancing media clock rather than trusting an optimistic `.playing`
    /// callback. This keeps a background full-file transfer off the playback critical path.
    private func waitForEstablishedPlayback(of songID: String, epoch: UInt64) async -> Bool {
        if Self.playbackTraceEnabled {
            print("[PB-CACHE] stability-wait-start song=\(songID) attempt=\(epoch) progress=\(String(format: "%.2f", engineProgress()))")
        }
        var stability = PlaybackPreparationStability()
        for _ in 0..<80 {
            guard epoch == playbackEpoch, !Task.isCancelled else { return false }
            let snapshot = await MainActor.run {
                (state.currentPlaybackTrack?.id ?? state.currentTrack?.id, state.playbackState, state.duration)
            }
            guard epoch == playbackEpoch, !Task.isCancelled, snapshot.0 == songID else { return false }
            // AVPlayer exposes buffer ranges; AudioStreaming does not. Even with a
            // native buffer, keep an optional full-file transfer out of the first
            // startup window so it cannot compete with the opening stream.
            let requiredStability: TimeInterval = systemPlayback.isActive ? 12 : 20
            if stability.observe(mediaTime: engineProgress(), now: ProcessInfo.processInfo.systemUptime,
                                 isPlaying: snapshot.1 == .playing, requiredDuration: requiredStability),
               !systemPlayback.isActive || PlaybackBufferPolicy.canPrepareNext(
                    isLocal: currentSource?.isLocal == true, bufferedAhead: systemEngine.bufferedDuration,
                    remaining: snapshot.2 - engineProgress()) {
                if Self.playbackTraceEnabled {
                    print("[PB-CACHE] stability-passed song=\(songID) attempt=\(epoch) progress=\(String(format: "%.2f", engineProgress())) buffered=\(String(format: "%.1f", systemEngine.bufferedDuration))")
                }
                return true
            }
            if snapshot.1 == .paused || snapshot.1 == .idle {
                return false
            }
            if case .error = snapshot.1 { return false }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return false }
        }
        return false
    }

    /// An automatic download may proceed when the network is unmetered/unconstrained, or when
    /// the user explicitly allowed downloads over a limited connection.
    nonisolated static func shouldAllowAutomaticDownload(
        isLimited: Bool,
        allowCellular: Bool
    ) -> Bool {
        !isLimited || allowCellular
    }

    /// Also covers enabling the setting during playback and retrying after connectivity returns.
    private func checkAutomaticDownload() async {
        guard Date() >= automaticDownloadCheckDate else { return }
        automaticDownloadCheckDate = Date().addingTimeInterval(30)
        let epoch = playbackEpoch
        let source = currentSource
        let current = await MainActor.run { () -> (DisplayableSong, UUID)? in
            guard state.playbackState == .playing, !state.isLiveStream,
                  let song = state.currentTrack, let serverId = serverService.state.activeServer?.id else { return nil }
            return (song, serverId)
        }
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        if let (song, serverId) = current {
            await scheduleAutomaticDownload(song: source?.playbackSong ?? song, serverId: serverId)
            if epoch == playbackEpoch, !Task.isCancelled, let source {
                scheduleEphemeralCache(song: song, source: source, serverId: serverId)
            }
        }
    }

    func startProgressTimer() {
        stopProgressTimer()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = LumaPerformance.budget.playbackProgressInterval
                do { try await Task.sleep(for: interval, tolerance: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled, let self else { break }
                await self.handleSystemPlayerItemChanged(generation: self.systemPlayback.generation)
                let context = await self.playbackContext
                let epoch = context.epoch
                let trackID = await MainActor.run { self.state.currentTrack?.id }
                guard let progress = await self.progressForPresentation(context: context) else { continue }
                let audioDuration = await self.engineDuration()
                let engineSeekable = await self.engineIsSeekable()
                let engineIsProducing = await self.activeEngine.state == .playing
                // Read once per tick: a hand-over may start or finish while this pass awaits.
                let isHandingOver = await self.isTrackTransitionPending
                guard !isHandingOver, epoch == (await self.playbackEpoch) else { continue }
                let positionBeforeTick = await MainActor.run { self.state.position }
                let seekState = await self.reconcilePendingSeek(engineProgress: progress)
                let engineIsEstimate = await self.durationIsEstimate()
                let preservesCatalog = await self.preservesCatalogDuration()
                guard epoch == (await self.playbackEpoch), !Task.isCancelled else { continue }
                if !seekState.isSettling, seekState.target != nil {
                    // The progress loop can win settlement before the dedicated monitor.
                    // It must publish the same atomic UI completion, rather than clear the
                    // hint first and leave .recovering until some future clock increment.
                    let producingAudio = await self.activeEngine.state == .playing
                    await self.publishEnginePlaybackConfirmation(settledPosition: progress,
                                                                 confirmsPlayback: producingAudio)
                }
                // A stream reconnect can reset its clock without ending the song. Recover
                // before publishing zero, so neither the UI nor repeat-one treats it as EOF.
                if !seekState.isSettling,
                   await self.recoverUnexpectedProgressReset(progress: progress, handleTrackEnd: true) { continue }
                let published = await self.commitPresentation(context) { state in
                    guard !Task.isCancelled, !isHandingOver, state.currentTrack?.id == trackID else { return false }
                    let cur = state.isLiveStream ? 0 : PlaybackDurationPolicy.resolve(
                        catalog: state.currentTrack?.duration ?? 0,
                        engine: audioDuration,
                        engineIsEstimate: engineIsEstimate,
                        preserveCatalog: preservesCatalog
                    )
                    if abs(state.duration - cur) > 0.5 || !state.duration.isFinite {
                        state.duration = cur
                    }
                    if !seekState.isSettling, state.pendingSeekPosition == nil {
                        let clamped = cur > 0 ? min(progress, cur) : progress
                        let preserve = PlaybackPositionPolicy.shouldPreserveZeroReset(
                            engineProgress: progress,
                            previousPosition: state.position,
                            playbackState: state.playbackState,
                            engineIsProducing: engineIsProducing
                        )
                        if !preserve, state.position != clamped {
                            state.position = clamped
                        }
                    }
                    let canSeek = engineSeekable || (audioDuration <= 0 && cur > 0)
                    if state.isSeekable != canSeek {
                        state.isSeekable = canSeek
                    }
                    return true
                }
                guard published, await self.contextIsCurrent(context), !isHandingOver else { continue }
                // Advancing media time confirms audio after startup, buffering or recovery.
                // A seek clock jump is excluded until the seek has settled.
                if !seekState.isSettling, progress > positionBeforeTick + 0.05 {
                    await self.publishEnginePlaybackConfirmation()
                }
                if !seekState.isSettling {
                    await self.checkEndOfTrackFallback(progress: progress)
                }
                guard epoch == (await self.playbackEpoch), !Task.isCancelled else { continue }
                await self.checkSustainedPlaybackStall(progress: progress)
                await self.ensureGaplessPreparation()
                let publishedProgress = seekState.isSettling
                    ? (seekState.target ?? progress)
                    : progress
                await self.periodicNowPlayingPush(elapsed: publishedProgress)
                await self.checkScrobbleThreshold()
                await self.checkPrefetchThreshold()
                await self.checkAutomaticDownload()
                await self.checkFadeOutThreshold()
            }
        }
    }

    func progressForPresentation(context: PlaybackContext) async -> Double? {
        guard contextIsCurrent(context), !isTrackTransitionPending, !isHandlingEndOfTrack else { return nil }
        if systemPlayback.isActive {
            if let position = systemEngine.currentItemProgress { return streamTimeOffset + position }
            // The last native item can drain while the app is suspended or its EOF
            // callback is fenced by an earlier command. Never publish an empty queue as 0:00.
            if let id = systemEngine.unacknowledgedEndID, transport.permitsAudio {
                let generation = systemPlayback.generation
                let time = systemEngine.progress
                await Task {
                    await handleSystemEngineEvent(.ended(generation, id, itemTime: time), expectedContext: context)
                }.value
            }
            return nil
        }
        return engineProgress()
    }

    func recoverUnexpectedProgressReset(progress: Double, handleTrackEnd: Bool = false) async -> Bool {
        guard pendingRestoreInfo == nil, !isTrackTransitionPending, seekState == .idle,
              Self.didEngineProgressWrap(previous: lastObservedEngineProgress, current: progress) else { return false }
        let epoch = playbackEpoch
        let previous = lastObservedEngineProgress
        let request = seekRequestGeneration
        let commandID = transportCommandID
        let snapshot = await MainActor.run { (state.duration, state.playbackState.hasPlaybackIntent, state.isLiveStream) }
        guard epoch == playbackEpoch, request == seekRequestGeneration, commandID == transportCommandID,
              !Task.isCancelled, snapshot.1, !snapshot.2 else { return false }
        if gaplessBridge.wasSelected || Self.isClockResetNearEnd(previous: previous, duration: snapshot.0) {
            guard handleTrackEnd else { return false }
            await finishTrackFromProgressTimer(context: playbackContext, position: previous,
                                               engineConfirmed: gaplessBridge.wasSelected)
        } else {
            await recoverUnexpectedStreamReset(position: previous)
        }
        return true
    }

    nonisolated static func isClockResetNearEnd(previous: Double, duration: Double) -> Bool {
        duration.isFinite && duration > 0 && previous >= duration - 1
    }

    private func durationIsEstimate() -> Bool {
        !systemPlayback.isActive || currentSource.map(AudioQualityClassifier.isLossyTranscodeStream) == true
    }

    private func preservesCatalogDuration() -> Bool {
        currentSource?.supportsTranscodeOffset == true
            || currentSource.map(AudioQualityClassifier.isLossyTranscodeStream) == true
    }

    func reconcilePendingSeek(engineProgress: TimeInterval, allowsPausedOffset: Bool = false) -> (isSettling: Bool, target: TimeInterval?) {
        guard !Task.isCancelled else { return (true, seekState.target) }
        // An offset is our requested origin, not proof that the new response has produced
        // audio. Keep the target pinned until its own media clock actually advances.
        if systemPlayback.isActive, systemEngine.isSeeking || systemEngine.lastSeekFailed {
            return (true, seekState.target)
        }
        if !allowsPausedOffset, currentSource?.supportsTranscodeOffset == true,
           activeEngine.progress <= 0.05,
           case .settling(let target, let deadline) = seekState, Date() < deadline {
            return (true, target)
        }
        // A broad server-segment tolerance can accept a local parser's old clock, especially
        // for short backwards seeks. Local files can land accurately without that concession.
        let tolerance: TimeInterval = currentSource?.isLocal == true || seekBufferURL != nil ? 0.15 : 2.5
        switch seekState.reconcile(progress: engineProgress, now: Date(), tolerance: tolerance) {
        case .inactive:
            return (false, nil)
        case .waiting(let target):
            return (true, target)
        case .finished(let target, let landed):
            lastObservedEngineProgress = engineProgress
            if landed { systemPlayback.seekSettleDeadline = .distantPast }
            if !landed {
                seekState = .settling(target: target, deadline: Date().addingTimeInterval(600))
                let generation = systemPlayback.generation
                Task { [weak self] in await self?.recoverFailedSeek(target: target, failedGeneration: generation) }
                Logger.player.warning(
                    "[SEEK] engine did not reach target in time target=\(target, format: .fixed(precision: 1))s engine=\(engineProgress, format: .fixed(precision: 1))s"
                )
            }
            return (!landed, target)
        }
    }

    /// When AudioStreaming never reports EOF (common on AirPlay), advance from progress alone.
    func checkEndOfTrackFallback(progress: Double) async {
        let context = playbackContext
        let request = seekRequestGeneration
        let (playbackState, duration, isLiveStream) = await MainActor.run {
            (state.playbackState, state.duration, state.isLiveStream)
        }
        guard contextIsCurrent(context), request == seekRequestGeneration else { return }
        guard case .playing = playbackState, !isLiveStream, duration > 1 else {
            endOfTrackStallStartedAt = nil
            lastObservedEngineProgress = progress
            return
        }

        let previousProgress = lastObservedEngineProgress
        lastObservedEngineProgress = progress

        // A restore seek, an armed engine rebuild or a foreground health-check rebuild all reset
        // the engine clock mid-track. That reset is not end of track — app state and engine are
        // simply out of step while the restart settles — so it must never advance the queue.
        #if os(iOS)
        let engineIsRestarting = pendingRestoreInfo != nil || restorePauseTask != nil || isRebuildingEngine || isTrackTransitionPending
        #else
        let engineIsRestarting = pendingRestoreInfo != nil || restorePauseTask != nil || isTrackTransitionPending
        #endif
        if engineIsRestarting {
            endOfTrackStallStartedAt = nil
            return
        }

        // AudioStreaming resets progress when it reaches EOF (and when a queued entry begins).
        // Server duration metadata is frequently inaccurate, so requiring the old progress to
        // be near that metadata can leave the engine replaying from zero under stale UI state.
        // User seeks cannot enter here while settling and reset `lastObservedEngineProgress` to
        // their target, which makes this wrap test safe for backward scrubbing.
        if Self.didEngineProgressWrap(previous: previousProgress, current: progress) {
            Logger.player.info(
                "[END-OF-TRACK] detected engine progress wrap (previous=\(previousProgress, format: .fixed(precision: 2))s current=\(progress, format: .fixed(precision: 2))s bridge=\(self.gaplessBridge.next != nil))"
            )
            endOfTrackStallStartedAt = nil
            await finishTrackFromProgressTimer(context: context, position: previousProgress,
                                               engineConfirmed: gaplessBridge.next != nil)
            return
        }

        // Do not advance merely because metadata says 0.2s remain. That used to race the real
        // EOF callback and could consume a gapless bridge before its audio had actually moved.
        // Only use the fallback after progress has genuinely stopped near the end.
        let remaining = duration - progress
        guard remaining <= 0.80 else {
            endOfTrackStallStartedAt = nil
            return
        }
        if endOfTrackStallStartedAt == nil || abs(progress - endOfTrackStallProgress) > 0.08 {
            endOfTrackStallStartedAt = Date()
            endOfTrackStallProgress = progress
            return
        }
        guard let started = endOfTrackStallStartedAt,
              Date().timeIntervalSince(started) >= 1.5 else { return }
        Logger.player.info(
            "[END-OF-TRACK] stall watchdog fired near end (progress=\(progress, format: .fixed(precision: 2))s remaining=\(remaining, format: .fixed(precision: 2))s)"
        )
        endOfTrackStallStartedAt = nil
        await finishTrackFromProgressTimer(context: context, position: progress, engineConfirmed: false)
    }

    private func finishTrackFromProgressTimer(context: PlaybackContext, position: Double, engineConfirmed: Bool) async {
        // Starting the successor cancels the outgoing timer. The accepted EOF must
        // outlive that timer, while a newer pause, stop or selection still wins.
        await Task {
            await handleEndOfTrack(engineConfirmed: engineConfirmed, expectedContext: context,
                                   finishedProgress: position)
        }.value
    }

    func stopProgressTimer() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func checkSustainedPlaybackStall(progress: Double) async {
        let epoch = playbackEpoch
        let snapshot = await MainActor.run { (state.playbackState, state.isLiveStream) }
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        let intendsToPlay = snapshot.0.hasPlaybackIntent
        let stalled = progressStallMonitor.observe(
            mediaTime: progress,
            now: ProcessInfo.processInfo.systemUptime,
            cannotPlay: intendsToPlay && !snapshot.1,
            isSeeking: seekState != .idle || isTrackTransitionPending
                || pendingRestoreInfo != nil || Date() < systemPlayback.seekSettleDeadline
        )
        if stalled, !systemPlayback.recoveredCurrentStall {
            // Resolving a replacement must not freeze progress/seek reconciliation.
            Task { [weak self] in await self?.recoverFromStalledStream() }
        }
    }
}
