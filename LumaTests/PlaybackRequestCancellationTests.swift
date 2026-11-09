import Foundation
import AVFoundation
import AudioStreaming
import SwiftSonic
import Testing
@testable import Luma

@MainActor
private final class SuspendedPlaybackResolver: MediaResolverProtocol {
    nonisolated let starts: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private(set) var cancelledIDs: Set<String> = []

    init() {
        (starts, continuation) = AsyncStream.makeStream()
    }

    func resolve(songId: String, serverId: UUID, song: DisplayableSong?) async throws -> MediaSource {
        continuation.yield(songId)
        do {
            try await Task.sleep(for: .seconds(5))
        } catch {
            cancelledIDs.insert(songId)
            throw error
        }
        throw LumaError.timeout
    }

    func resolveRadio(_ station: InternetRadioStation) async throws -> MediaSource {
        throw LumaError.timeout
    }
}

@MainActor
@Suite("Playback request cancellation", .serialized)
struct PlaybackRequestCancellationTests {
    private func makePlayer(
        container: AppContainer, resolver: any MediaResolverProtocol, engine: FakePlaybackEngine
    ) -> PlayerService {
        container.serverState.activeServer = ServerSnapshot(from: ServerConfig(
            displayName: "Playback test", baseURL: "https://example.invalid", username: "test"
        ))
        return PlayerService(
            state: container.playerState, mediaResolver: resolver,
            serverService: container.serverService, sessionService: container.sessionService,
            artworkImageCache: container.artworkImageCache, lyricsService: container.lyricsService,
            libraryService: container.libraryService, cacheService: container.cacheService,
            downloadService: container.downloadService, cacheSettings: container.cacheSettings,
            streamingSettings: container.streamingSettings, replayGainSettings: container.replayGainSettings,
            crossfadeSettings: container.crossfadeSettings, gaplessSettings: container.gaplessSettings,
            toastService: container.toastService, statsService: container.statsService,
            listenBrainzService: container.listenBrainzService, engine: engine
        )
    }

    private func song(_ id: String) -> DisplayableSong {
        DisplayableSong(
            id: id, title: id, artist: nil, albumId: nil, albumName: nil,
            artistId: nil, genre: nil, duration: 180, trackNumber: nil,
            isDownloaded: false, coverArtId: nil, audioFormat: nil,
            replayGainTrackGain: nil, replayGainTrackPeak: nil,
            replayGainAlbumGain: nil, replayGainAlbumPeak: nil,
            replayGainBaseGain: nil, replayGainFallbackGain: nil
        )
    }

    private func silentWAV(seconds: UInt32) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gapless-\(UUID()).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000 * seconds))
        pcm.frameLength = pcm.frameCapacity
        pcm.floatChannelData?[0].update(repeating: 0, count: Int(pcm.frameLength))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: pcm)
        }
        return url
    }

    @Test("Restored playback retries without losing its checkpoint", arguments: [false, true])
    func restoredSelectionWithoutSourceCanRetryAtSavedPosition(failFirst: Bool) async throws {
        let url = try silentWAV(seconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let resolver = RestoreRetryResolver(url: url)
        resolver.failNext = failFirst
        let player = makePlayer(container: container, resolver: resolver, engine: engine)
        let track = DisplayableSong(id: "restored", title: "Restored", duration: 30)
        container.playerState.currentTrack = track
        container.playerState.queue = [track]
        container.playerState.position = 12
        container.playerState.duration = 30
        container.playerState.playbackState = .paused
        container.playerState.isPlaybackAvailable = false
        if failFirst {
            await player.resume()
            #expect(container.playerState.position == 12)
            #expect(container.playerState.playbackState == .error(.playbackFailed(PlaybackFailure.classify(LumaError.timeout))))
        }
        await player.resume()
        #expect(container.playerState.currentTrack?.id == track.id)
        #expect(container.playerState.isPlaybackAvailable)
        #expect(resolver.calls == (failFirst ? 2 : 1))
        let deadline = Date().addingTimeInterval(5)
        while player.systemEngine.progress < 11.8, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(player.systemEngine.progress >= 11.8)
        #expect(container.playerState.playbackState != .paused)
        await player.stop()
    }

    @Test func naturalGaplessQueueFinishesAtEndEvenWithoutNativeNotifications() async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let file = try silentWAV(seconds: 5)
        let successor = try silentWAV(seconds: 5)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: successor)
        }
        let resolver = RestoreRetryResolver(url: file)
        let player = makePlayer(container: container, resolver: resolver, engine: engine)
        let queue = ["first", "second"].map { DisplayableSong(id: $0, title: $0, duration: 5) }
        container.playerState.queue = queue
        container.playerState.currentIndex = 0
        container.playerState.currentTrack = queue[0]
        container.playerState.duration = 5
        container.playerState.playbackState = .playing
        container.playerState.repeatMode = .off
        container.playerState.isAutoExtendEnabled = false
        _ = await player.installPreparedHandoff(next: queue[1], currentURL: file, nextURL: successor)
        let native = player.systemEngine
        defer { native.stop() }
        native.volume = 0
        native.resume()
        await player.startProgressTimer()
        let deadline = Date().addingTimeInterval(16)
        while container.playerState.playbackState != .paused, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(container.playerState.currentIndex == 1)
        #expect(container.playerState.currentTrack?.id == "second")
        #expect(container.playerState.playbackState == .paused)
        #expect(container.playerState.position >= 4.9)
        #expect(resolver.calls == 0)
        await player.stop()
    }

    @Test func delayedNativeHandoffKeepsQueueAndClockOnTheSameSong() async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let file = try silentWAV(seconds: 5)
        let successor = try silentWAV(seconds: 5)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: successor)
        }
        let resolver = RestoreRetryResolver(url: file)
        let player = makePlayer(container: container, resolver: resolver, engine: engine)
        let queue = [song("ending"), song("successor")]
        container.playerState.queue = queue
        container.playerState.currentIndex = 0
        container.playerState.currentTrack = queue[0]
        container.playerState.position = 179
        container.playerState.duration = 180
        container.playerState.playbackState = .playing
        let generation = await player.installPreparedHandoff(next: queue[1], currentURL: file, nextURL: successor)
        let native = player.systemEngine
        defer { native.stop() }
        try #require(native.advanceToPreparedNext(expectedURL: successor))
        let deadline = Date().addingTimeInterval(3)
        while native.state != .playing, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(native.state == .playing)
        try await Task.sleep(for: .milliseconds(1250))
        native.pause()

        let outgoing = await player.playbackContext
        #expect(await player.progressForPresentation(context: outgoing) == nil)
        #expect(container.playerState.position == 179)
        await player.handleSystemPlayerItemChanged(generation: generation)
        await player.handleSystemPlayerItemChanged(generation: generation)
        #expect(container.playerState.currentIndex == 1)
        #expect(container.playerState.currentTrack?.id == "successor")
        #expect(container.playerState.position > 1)
        #expect(abs(container.playerState.position - native.progress) < 0.1)
        #expect(resolver.calls == 0)
        #expect(!native.hasQueuedItem)
        await player.stop()
    }

    @Test func endOfTrackFallbackCanReplaceItsOwnProgressTimer() async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let file = LumaTestResources.fixture("Fixtures/SilentMP3.mp3", sourceFile: #filePath)
        let resolver = RestoreRetryResolver(url: file)
        let player = makePlayer(container: container, resolver: resolver, engine: engine)
        let queue = [song("ending"), song("successor")]
        container.playerState.queue = queue
        container.playerState.currentIndex = 0
        container.playerState.currentTrack = queue[0]
        container.playerState.duration = 180
        container.playerState.position = 180
        container.playerState.playbackState = .playing

        await player.runFinalProgressTick(at: 180)

        #expect(container.playerState.currentIndex == 1)
        #expect(container.playerState.currentTrack?.id == "successor")
        #expect(container.playerState.playbackState.hasPlaybackIntent)
        #expect(player.systemEngine.hasCurrentItem || engine.calls.contains(.play(file, [:])))
        #expect(resolver.calls == 1)
        await player.stop()
    }

    @Test func latestSelectionCancelsPreviousResolveAndStopCancelsLatest() async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let resolver = SuspendedPlaybackResolver()
        let player = makePlayer(container: container, resolver: resolver, engine: engine)
        var starts = resolver.starts.makeAsyncIterator()
        let queue = [song("first"), song("second")]
        let first = Task { try await player.play(tracks: queue, startIndex: 0) }
        let firstStarted = await starts.next()
        #expect(firstStarted == "first")
        let second = Task { try await player.play(tracks: queue, startIndex: 1) }
        let secondStarted = await starts.next()
        #expect(secondStarted == "second")
        try await first.value
        #expect(resolver.cancelledIDs.contains("first"))
        #expect(container.playerState.currentTrack?.id == "second")
        await player.stop()
        try await second.value
        #expect(resolver.cancelledIDs.contains("second"))
        #expect(!engine.calls.contains { if case .play = $0 { return true }; return false })
    }

    @Test func pauseDuringResolutionCannotStartAudioLater() async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let resolver = SuspendedPlaybackResolver()
        let player = makePlayer(container: container, resolver: resolver, engine: engine)
        var starts = resolver.starts.makeAsyncIterator()
        let request = Task { try await player.play(tracks: [song("paused")], startIndex: 0) }
        let pausedStarted = await starts.next()
        #expect(pausedStarted == "paused")
        await player.pause()
        try await request.value
        #expect(resolver.cancelledIDs.contains("paused"))
        #expect(container.playerState.playbackState == .paused)
        #expect(!engine.calls.contains { if case .play = $0 { return true }; return false })
    }

    @Test("A late cold-resume resolve cannot override pause or stop", arguments: [false, true])
    func coldResumeRespectsNewerCommand(stop: Bool) async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let resolver = HeldResumeResolver()
        let player = makePlayer(container: container, resolver: resolver, engine: engine)
        let track = song("resume")
        container.playerState.currentTrack = track
        container.playerState.queue = [track]
        container.playerState.position = 45
        container.playerState.playbackState = .paused
        await player.primeColdResume()
        var starts = resolver.starts.makeAsyncIterator()
        let pending = Task { await player.resume() }
        _ = await starts.next()
        #expect(container.playerState.playbackState == .recovering)
        #expect(container.playerState.position == 45)
        if stop { await player.stop() } else { await player.pause() }
        resolver.finish()
        await pending.value
        #expect(!player.systemEngine.hasCurrentItem)
        #expect(container.playerState.playbackState == (stop ? .idle : .paused))
        #expect(!engine.calls.contains { if case .play = $0 { return true }; return false })
        await player.stop()
    }
}

@MainActor
private final class HeldResumeResolver: MediaResolverProtocol {
    nonisolated let starts: AsyncStream<Void>
    private let events: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<MediaSource, Never>?

    init() { (starts, events) = AsyncStream.makeStream() }
    func resolve(songId: String, serverId: UUID, song: DisplayableSong?) async throws -> MediaSource {
        await withCheckedContinuation { continuation in
            pending = continuation
            events.yield(())
        }
    }
    func finish() {
        pending?.resume(returning: .downloaded(URL(fileURLWithPath: "/tmp/late-resume.wav")))
        pending = nil
    }
    func resolveRadio(_ station: InternetRadioStation) async throws -> MediaSource { throw LumaError.timeout }
}

private extension PlayerService {
    func installPreparedHandoff(next: DisplayableSong, currentURL: URL, nextURL: URL) -> UInt64 {
        systemPlayback.isActive = true
        // Deliver the current-item notification manually after the successor's clock moves.
        systemEngine.eventHandler = nil
        currentSource = .downloaded(currentURL)
        gaplessBridge.arm(next: next, source: .downloaded(nextURL), epoch: playbackEpoch)
        systemEngine.start(url: currentURL, headers: [:], generation: systemPlayback.generation, paused: true)
        #expect(systemEngine.prepareNext(url: nextURL, headers: [:]))
        return systemPlayback.generation
    }

    func runFinalProgressTick(at position: Double) async {
        endOfTrackStallProgress = position
        endOfTrackStallStartedAt = Date().addingTimeInterval(-2)
        let tick = Task { await checkEndOfTrackFallback(progress: position) }
        progressTask = tick
        await tick.value
    }

    func primeColdResume() {
        currentSource = .downloaded(URL(fileURLWithPath: "/tmp/cold-resume.wav"))
        systemPlayback.isActive = true
    }
}

@MainActor
private final class RestoreRetryResolver: MediaResolverProtocol {
    let url: URL
    var calls = 0
    var failNext = false
    init(url: URL) { self.url = url }
    func resolve(songId: String, serverId: UUID, song: DisplayableSong?) async throws -> MediaSource {
        calls += 1
        if failNext { failNext = false; throw LumaError.timeout }
        return .downloaded(url)
    }
    func resolveRadio(_ station: InternetRadioStation) async throws -> MediaSource { throw LumaError.timeout }
}
