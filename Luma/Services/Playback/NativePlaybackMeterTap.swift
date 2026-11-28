import AVFoundation
import MediaToolbox
import Synchronization

/// Read-only native PCM tap: samples pass through unchanged, including channel layout.
/// The tap owns a separate callback context; no tap/context retain cycle is created.
nonisolated final class NativePlaybackMeterTap: @unchecked Sendable {
    private final class Context {
        let active = Atomic<Bool>(false)
        let supplementary: Bool
        var format = AudioStreamBasicDescription()
        let mediaOffset = Atomic<Double>(0)
        let processCount = Atomic<UInt64>(0)
        let forwardCount = Atomic<UInt64>(0)
        let forwardFrames = Atomic<UInt64>(0)

        init(supplementary: Bool) {
            self.supplementary = supplementary
        }
    }
    private let context: Context
    private var tap: MTAudioProcessingTap?

    /// `trackMix` selects the iOS 27 preferred-format tap, which is required when the
    /// input parameters use `AVAudioMixInputParametersTrackID.mixID`. A per-track tap
    /// keeps the regular creation path; the preferred-format call leaves a track tap's
    /// format undefined and can leave it silent.
    init?(trackMix: Bool = false, supplementary: Bool = false) {
        let context = Context(supplementary: supplementary)
        self.context = context
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
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.processCount.wrappingAdd(1, ordering: .relaxed)
                var timeRange = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, list, flagsOut, &timeRange, framesOut)
                guard status == noErr, framesOut.pointee > 0 else { return }
                guard context.active.load(ordering: .relaxed) else { return }
                context.forwardCount.wrappingAdd(1, ordering: .relaxed)
                context.forwardFrames.wrappingAdd(UInt64(framesOut.pointee), ordering: .relaxed)
                PlaybackBeatMeter.enqueue(bufferList: UnsafePointer(list), format: context.format,
                                          frameCount: framesOut.pointee,
                                          mediaTime: timeRange.start.isNumeric ? timeRange.start.seconds + context.mediaOffset.load(ordering: .relaxed) : nil,
                                          supplementary: context.supplementary)
            }
        )
        var created: MTAudioProcessingTap?
        let status: OSStatus
        if #available(iOS 27, macOS 27, *), trackMix {
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
    var processCount: UInt64 { context.processCount.load(ordering: .relaxed) }
    var forwardCount: UInt64 { context.forwardCount.load(ordering: .relaxed) }
    var forwardedFrames: UInt64 { context.forwardFrames.load(ordering: .relaxed) }
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
    /// The background pulse tolerates a late analysis window; it cannot tolerate a
    /// permanently silent one. Keep drift bounded without turning sub-frame sync into
    /// an activation requirement.
    private static let driftTolerance = 0.1
    private static let correctionInterval: TimeInterval = 0.5
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
                      let meter = NativePlaybackMeterTap(supplementary: true) else { return }
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
                // A track tap sits upstream of the player's output gain, so muting the
                // silent decoder does not suppress the decoded buffers. A zero-volume
                // player, by contrast, can be rendered at a reduced rate.
                player.isMuted = true
                player.allowsExternalPlayback = false
                self.player = player
                self.meter = meter
                // Prepare an asset before the audible clock reaches the captured
                // position. Seeking to the *latest* source position avoids starting
                // hundreds of milliseconds behind and then being held inactive by the
                // drift gate below.
                let target = self.source?.position ?? current.position
                self.seek(to: target - self.timelineOffset)
            }
            return
        }
        source = next
        guard let player else { return }
        let drift = abs(player.currentTime().seconds + timelineOffset - next.position)
        // A silent decoder and the audible player are independent clocks. Correct large
        // drift, but keep the tap active while the decoder plays: gating analysis on
        // sub-frame sync left the tap active for only a few milliseconds after each seek,
        // which is too short for the Lyricify confirmation/decay window.
        if !seeking, drift > Self.driftTolerance,
           ProcessInfo.processInfo.systemUptime - lastSeekTime >= Self.correctionInterval {
            seek(to: next.position - timelineOffset)
        }
        meter?.setActive(!seeking && player.timeControlStatus == .playing)
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

    var debugSummary: String {
        let time = player?.currentTime().seconds ?? -1
        let status = player?.timeControlStatus.rawValue ?? -1
        return "source=\(source != nil) player=\(player != nil) status=\(status) "
            + "time=\(String(format: "%.2f", time)) seeking=\(seeking) "
            + "tap_process=\(meter?.processCount ?? 0) tap_forward=\(meter?.forwardCount ?? 0) "
            + "frames=\(meter?.forwardedFrames ?? 0)"
    }
}
