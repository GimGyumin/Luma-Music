import AVFoundation
import MediaToolbox
import Synchronization

/// Read-only native PCM tap: samples pass through unchanged, including channel layout.
/// The tap owns a separate callback context; no tap/context retain cycle is created.
nonisolated final class NativePlaybackMeterTap: @unchecked Sendable {
    private final class Context {
        let active = Atomic<Bool>(false)
        var format = AudioStreamBasicDescription()
        let mediaOffset = Atomic<Double>(0)
    }
    private let context = Context()
    private var tap: MTAudioProcessingTap?

    init?() {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(context).toOpaque(),
            init: { _, info, storage in
                guard let info else { return }
                storage.pointee = Unmanaged<Context>.fromOpaque(info).retain().toOpaque()
            },
            finalize: { tap in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.format = format.pointee
            },
            unprepare: { _ in },
            process: { tap, frames, _, list, framesOut, flagsOut in
                var timeRange = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, list, flagsOut, &timeRange, framesOut)
                guard status == noErr, framesOut.pointee > 0 else { return }
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard context.active.load(ordering: .relaxed) else { return }
                PlaybackBeatMeter.enqueue(bufferList: UnsafePointer(list), format: context.format,
                                          frameCount: framesOut.pointee,
                                          mediaTime: timeRange.start.isNumeric ? timeRange.start.seconds + context.mediaOffset.load(ordering: .relaxed) : nil)
            }
        )
        var created: MTAudioProcessingTap?
        let status: OSStatus
        if #available(iOS 27, macOS 27, *) {
            // A nil preferred format retains the device-optimized PCM layout. On iOS 27
            // track-mix taps also support unprotected HLS; no separate decoder is needed.
            status = MTAudioProcessingTapCreateWithPreferredFormat(kCFAllocatorDefault, &callbacks,
                kMTAudioProcessingTapCreationFlag_PostEffects, nil, &created)
        } else {
            status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                kMTAudioProcessingTapCreationFlag_PostEffects, &created)
        }
        guard status == noErr, let created else { return nil }
        tap = created
    }

    @MainActor func attach(to item: AVPlayerItem, trackID: CMPersistentTrackID) {
        let input = AVMutableAudioMixInputParameters()
        input.trackID = trackID
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = (item.audioMix?.inputParameters ?? []) + [input]
        item.audioMix = mix
    }

    func setActive(_ active: Bool) { context.active.store(active, ordering: .relaxed) }
    func setMediaOffset(_ offset: Double) { context.mediaOffset.store(offset, ordering: .relaxed) }
    deinit { context.active.store(false, ordering: .relaxed) }
}

/// The asset is shared with audible playback. Access to its actor-isolated
/// properties stays on the main actor in NativePlaybackAnalysisPlayer.
nonisolated struct NativePlaybackAnalysisSource: @unchecked Sendable {
    let item: AVPlayerItem
    let url: URL
    let headers: [String: String]
    let position: Double
    let generation: UInt64
    let seekSequence: UInt64

    func hasSameItem(as other: Self) -> Bool {
        item === other.item && generation == other.generation
    }
}

/// A silent, visibility-scoped decoder supplies PCM when the audible gapless
/// queue cannot install a per-item audio mix. It never changes the audible item.
@MainActor
final class NativePlaybackAnalysisPlayer {
    private var source: NativePlaybackAnalysisSource?
    private var player: AVPlayer?
    private var meter: NativePlaybackMeterTap?
    private var preparation: Task<Void, Never>?
    private var timelineOffset = 0.0
    private var seeking = false
    private var seekID = UUID()
    private var lastSeekTime = -Double.infinity

    func update(_ next: NativePlaybackAnalysisSource) {
        if source?.hasSameItem(as: next) != true || source?.seekSequence != next.seekSequence {
            stop()
            let request = Self.analysisRequest(url: next.url, position: next.position)
            timelineOffset = request.offset
            let asset: AVAsset
            if request.url == next.url {
                asset = next.item.asset
            } else {
                let options: [String: Any]? = next.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": next.headers]
                asset = AVURLAsset(url: request.url, options: options)
            }
            source = next
            preparation = Task { [weak self] in
                // A track tap sees decoded samples upstream of the silent player's output gain.
                // A mix-output tap on a muted player can deliver silence or no buffers at all.
                let track = try? await asset.loadTracks(withMediaType: .audio).first
                guard !Task.isCancelled, let self, let current = self.source,
                      current.hasSameItem(as: next), current.seekSequence == next.seekSequence,
                      let meter = NativePlaybackMeterTap() else { return }
                let trackID: CMPersistentTrackID
                if let track {
                    trackID = track.trackID
                } else if #available(iOS 27, macOS 27, *) {
                    trackID = AVAudioMixInputParametersTrackID.mixID.rawValue
                } else { return }
                let item = AVPlayerItem(asset: asset)
                meter.setMediaOffset(self.timelineOffset)
                meter.attach(to: item, trackID: trackID)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true
                player.allowsExternalPlayback = false
                self.player = player
                self.meter = meter
                self.seek(to: current.position - self.timelineOffset)
            }
            return
        }
        source = next
        guard let player else { return }
        let drift = abs(player.currentTime().seconds + timelineOffset - next.position)
        let windowDuration = Double(PlaybackPCMWindow.count) / 44100
        if !seeking, drift > windowDuration && ProcessInfo.processInfo.systemUptime - lastSeekTime >= 1 {
            seek(to: next.position - timelineOffset)
        }
        meter?.setActive(!seeking && drift <= windowDuration && player.timeControlStatus == .playing)
    }

    /// Request a nearby OpenSubsonic slice instead of seeking across an unseekable
    /// growing transcode. The offset maps that decoder back to the audible clock.
    static func analysisRequest(url: URL, position: Double) -> (url: URL, offset: Double) {
        guard position.isFinite, position >= 0,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var query = parts.queryItems,
              let index = query.firstIndex(where: { $0.name.lowercased() == "timeoffset" }),
              let base = query[index].value.flatMap(Double.init), base.isFinite else { return (url, 0) }
        let start = floor(max(0, base + position))
        query[index].value = String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), start)
        parts.queryItems = query
        return (parts.url ?? url, start - base)
    }

    private func seek(to position: Double) {
        guard let player, position.isFinite else { return }
        meter?.setActive(false)
        seeking = true
        lastSeekTime = ProcessInfo.processInfo.systemUptime
        let id = UUID()
        seekID = id
        player.seek(to: CMTime(seconds: max(0, position), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] completed in
            Task { @MainActor [weak self, weak player] in
                guard let self, self.seekID == id, let player, self.player === player else { return }
                self.seeking = false
                if completed { player.play() }
            }
        }
    }

    func stop() {
        preparation?.cancel()
        preparation = nil
        seekID = UUID()
        seeking = false
        meter?.setActive(false)
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        player?.replaceCurrentItem(with: nil)
        player = nil
        meter = nil
        source = nil
    }
}
