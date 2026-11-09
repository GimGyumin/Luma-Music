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
    // MARK: - Scrobble

    func cancelPendingScrobble() {
        playingNowTask?.cancel()
        playingNowTask = nil
        periodicPlaybackReportTask?.cancel()
        periodicPlaybackReportTask = nil
        trackMetadataTask?.cancel()
        trackMetadataTask = nil
    }

    func checkScrobbleThreshold() async {
        // A track change is in flight: the accumulated time still belongs to the outgoing track,
        // so attributing it to the incoming one would scrobble the wrong song.
        guard !isTrackTransitionPending, !detector.fired else { return }
        let context = playbackContext
        let (currentSong, currentAccount) = await MainActor.run { (state.currentTrack, serverService.state.activeServer) }
        guard let song = currentSong, let account = currentAccount else { return }
        guard contextIsCurrent(context), !isTrackTransitionPending else { return }
        fireScrobbleIfThresholdMet(song: song, account: account)
    }

    private func fireScrobbleIfThresholdMet(song: DisplayableSong, account: ServerSnapshot) {
        guard Self.isListeningHistoryEnabled else { return }
        let duration = song.duration
        let songId = currentSource?.playbackSong?.id ?? song.id
        let segmentContrib = currentSegmentDuration
        let accumulated = accumulatedPlayedSeconds + segmentContrib
        guard detector.check(duration: duration, accumulated: accumulated) else { return }
        let startDate = trackPlayStartDate ?? Date()
        let session = accumulatorID
        Task { [libraryService] in
            await libraryService.submitListen(session: session, track: songId, date: startDate, account: account)
        }
        Task { [listenBrainzService] in
            await listenBrainzService.notifyScrobbleThreshold(song: song, startDate: startDate)
        }
    }

    func cancelPendingCacheDownload() {
        cacheDownloadTask?.cancel()
        cacheDownloadTask = nil
        cacheDownloadID = nil
        // These requests were started by playback, not by the user's Downloads
        // screen. Release their bandwidth on underrun, selection or stop.
        for work in automaticDownloadWork.values { work.task.cancel() }
        automaticDownloadWork.removeAll()
        automaticDownloadTasks.removeAll()
    }

    // MARK: - Play-time accumulator

    var currentSegmentDuration: TimeInterval {
        segmentStartedUptime.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0
    }

    func finalizePlaySegment() {
        guard currentPlaySegmentStart != nil else { return }
        accumulatedPlayedSeconds += currentSegmentDuration
        currentPlaySegmentStart = nil
    }

    func resetTrackAccumulator(isPlaying: Bool) {
        accumulatorID = UUID()
        accumulatedPlayedSeconds = 0
        trackPlayStartDate = Date()
        currentPlaySegmentStart = isPlaying ? Date() : nil
        detector.reset()
    }

    // MARK: - Stats recording

    func recordCurrentTrackPlayback(
        trigger: String = "unknown",
        overridingTrack: DisplayableSong? = nil
    ) async {
        guard Self.isListeningHistoryEnabled else { return }
        // Capture the outgoing counters before any suspension or track publication.
        let context = playbackContext
        let recordingID = accumulatorID
        guard recordedAccumulatorID != recordingID else { return }
        let startDate = trackPlayStartDate
        let completed = wasTrackCompletedNaturally
        let segmentContrib = currentSegmentDuration
        let durationListened = accumulatedPlayedSeconds + segmentContrib
        let recordedTrack: DisplayableSong?
        if let overridingTrack {
            recordedTrack = overridingTrack
        } else {
            recordedTrack = await MainActor.run { state.currentTrack }
        }
        guard let song = recordedTrack,
              let startDate else { return }
        guard let serverId = await MainActor.run(body: { serverService.state.activeServer?.localReplayID }) else { return }

        guard durationListened >= 30 else {
            Logger.player.debug("[STATS] Skip — durationListened=\(durationListened)s < 30s")
            return
        }

        guard context == playbackContext, recordedAccumulatorID != recordingID else { return }
        recordedAccumulatorID = recordingID
        let trackDuration = song.duration
        let dto = PlaybackEventDTO(
            id: recordingID,
            trackId: song.id,
            trackTitle: song.title,
            albumId: song.albumId,
            albumTitle: song.albumName,
            artistId: song.artistId,
            artistName: song.artist ?? "",
            genre: song.genre,
            timestamp: startDate,
            durationListened: durationListened,
            trackDuration: trackDuration,
            wasCompleted: completed,
            serverId: serverId
        )
        // Persistence is ordered, but no longer holds up audio startup. The immutable DTO
        // keeps delayed writes attributed to the outgoing song, never the newly visible one.
        let previousWrite = historyWriteTask
        historyWriteTask = Task { [statsService] in
            await previousWrite?.value
            await statsService.recordPlayback(dto, trigger: trigger)
        }
    }

    // MARK: - Cache download helpers

    func downloadAndCache(
        songId: String,
        serverId: UUID,
        streamURL: URL,
        customHeaders: [String: String],
        using session: URLSession
    ) async throws {
        // A setting change may land while a transfer is already in flight.
        guard Self.isAutomaticCacheEnabled else { throw CancellationError() }
        var request = URLRequest(url: streamURL)
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let identity = try await MainActor.run { try serverService.state.requestIdentity(for: serverId) }
        let key = MediaTransferKey(accountID: serverId, revision: identity.revision, songID: songId, request: request)
        let transferRequest = request
        try await transferCoordinator.cache(key) { [cacheService] in
            let (tempURL, response) = try await session.download(for: transferRequest)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw HTTPTransferFailure(response: response, stage: "audio cache response")
            }

            try AudioResponseValidator.validate(fileAt: tempURL, response: response, songId: songId, logger: Logger.cache)

            try Task.checkCancellation()
            let ext = streamURL.pathExtension
            let mimeType = response.mimeType ?? (ext.isEmpty ? "audio/mpeg" : "audio/\(ext)")

            // The user may have turned Automatic Downloads off while this
            // transfer was in flight. Do not add a new cache entry after that.
            guard Self.isAutomaticCacheEnabled else { throw CancellationError() }

            let cachedURL = try await cacheService.storeTransferred(
                fileAt: tempURL,
                forSongId: songId,
                serverId: serverId,
                mimeType: mimeType,
                key: key
            )

            Logger.player.info("Cached '\(songId, privacy: .public)'")
            return try CachedMediaTransfer(url: cachedURL, response: response)
        }
    }
}
