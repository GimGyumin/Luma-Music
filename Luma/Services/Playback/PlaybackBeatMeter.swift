// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AVFoundation
import Synchronization
import Observation
import SwiftUI
import OSLog
import QuartzCore

/// Live playback energy from decoded AudioStreaming/native-player PCM.
/// Visible indicators and the lyrics renderer share the same published spectrum.
///
/// Audio-thread samples are coalesced; `@Observable` properties update at most every
/// `LumaPerformance.beatPublishInterval` (30 Hz normally, 15 Hz in Low Power Mode) so
/// views are never invalidated on every mixer buffer.
@Observable
@MainActor
final class PlaybackBeatMeter {
    nonisolated static let filterName = "luma.beatMeter"
    nonisolated static let bandCount = 4
    nonisolated static let diagnosticsEnabled = ProcessInfo.processInfo.arguments.contains("-LumaLyricsPulseProbe")

    /// Shared instance; UI reads `level` / `beatPulse` / `bands` on the main actor.
    static let shared = PlaybackBeatMeter()

    /// Smoothed relative loudness suitable for UI (0 idle … 1 peak).
    private(set) var level: CGFloat = 0
    /// Short-window spike for punchier beat flashes.
    private(set) var beatPulse: CGFloat = 0
    /// Per-bar equalizer energies (0…1), driven by real audio — not a canned loop.
    private(set) var bands: [CGFloat] = Array(repeating: 0, count: bandCount)

    enum AnalysisInput: String { case disabled, waiting, unavailable, pcm, file }
    private(set) var input = AnalysisInput.disabled
    private(set) var spectrum = PlaybackSpectrum.zero
    private(set) var fallbackBands = Array(repeating: CGFloat.zero, count: bandCount)
    var hasValidAnalysis: Bool {
        (input == .pcm || input == .file) && CACurrentMediaTime() - lastSampleHostTime <= 0.25
    }
    var visualizationFallbackActive: Bool { analysisActive && waveformListeners > 0 && input == .unavailable }
    private var waveformListeners = 0
    @ObservationIgnored private var lastDiagnosticTime = -Double.infinity
    var targetBass: Float { hasValidAnalysis ? (pulseEvents.last?.strength ?? bassEnvelope.value(at: CACurrentMediaTime())) : 0 }

    @ObservationIgnored private(set) var lastSampleHostTime = 0.0

    @ObservationIgnored private var bassEnvelope = PlaybackBassEnvelope()
    @ObservationIgnored private var onsetDetector = PlaybackOnsetDetector()
    @ObservationIgnored private var pulseEvents: [(time: Double, strength: Float)] = []
    @ObservationIgnored private var clockProvider: (@Sendable () -> PlaybackAnalysisClock?)?
    @ObservationIgnored private var lastAnalysisClock: PlaybackAnalysisClock?
    @ObservationIgnored private var lastAnalysisTime: Double?
    @ObservationIgnored private(set) var analysisMediaTime: Double?
    @ObservationIgnored private(set) var triggerHostTime: Double?
    @ObservationIgnored private(set) var animationStartHostTime: Double?
    @ObservationIgnored private var previousPulse: Float = 0
    @ObservationIgnored private var onsetStrength: Float = 0
    @ObservationIgnored private(set) var analysisLeadSeconds: Double = 0
    @ObservationIgnored private var presentedHostTime: Double?

    func recordPresentation(trigger: Double, at hostTime: Double) {
        guard Self.diagnosticsEnabled, hostTime > 0 else { return }
        presentedHostTime = hostTime
        Logger.player.debug("[PULSE-PRESENT] trigger_host=\(trigger) display_host=\(hostTime) presentation_delay_ms=\((hostTime - trigger) * 1000)")
    }

    var backgroundBass: Float { pulse(at: CACurrentMediaTime()) }

    func pulse(at hostTime: Double) -> Float {
        if let clockProvider, clockProvider()?.playing != true { return 0 }
        while let next = pulseEvents.first, next.time <= hostTime {
            pulseEvents.removeFirst()
            guard hostTime - next.time <= 0.25 else { continue }
            bassEnvelope.trigger(strength: next.strength, at: next.time)
            triggerHostTime = next.time
        }
        let amplitude = bassEnvelope.value(at: hostTime)
        if previousPulse <= 0.001, amplitude > 0.001 { animationStartHostTime = hostTime }
        previousPulse = amplitude
        return amplitude
    }

    private var lastEnvelopeHostTime = 0.0
    private var normalizer = PlaybackSpectrumNormalizer()
    private var lastNativeSpectrumSource: PlaybackSpectrumSource?
    private var ema: Float = 0
    private var bandEMA: [Float] = Array(repeating: 0, count: bandCount)
    private var enabled = false
    private var analysisActive = false
    /// Number of visible consumers of the spectrum.
    private var listenCount = 0
    @ObservationIgnored private var publicationTask: Task<Void, Never>?
    private var consumedRevision: UInt64 = 0
    nonisolated private static let pcmWindow = PlaybackPCMWindow()
    @ObservationIgnored private var analyzer = PlaybackSpectrumAnalyzer()
    @ObservationIgnored private var nativeSourceProvider: (@Sendable () -> PlaybackSpectrumSource?)?
    @ObservationIgnored private let fileAnalyzer = PlaybackFileSpectrumAnalyzer()
    @ObservationIgnored private var nativeAnalysisSourceProvider: (@Sendable () -> NativePlaybackAnalysisSource?)?
    @ObservationIgnored private var nativeAnalysisPlayer: NativePlaybackAnalysisPlayer?
    private var sourceProviderRevision: UInt64 = 0
    @ObservationIgnored private var missingSamplesSince: Double?
    private var lastLiveSampleHostTime = 0.0

    nonisolated private static let publicationGeneration = Atomic<UInt64>(0)
    nonisolated private static let uiListeningFlag = Atomic<Bool>(false)

    nonisolated static func enqueue(buffer: AVAudioPCMBuffer, when: AVAudioTime? = nil, outputLatency: Double = 0) {
        enqueue(bufferList: buffer.audioBufferList, format: buffer.format.streamDescription.pointee,
            frameCount: Int(buffer.frameLength),
            hostTime: when.flatMap { $0.isHostTimeValid ? AVAudioTime.seconds(forHostTime: $0.hostTime) + max(0, outputLatency) : nil })
    }

    /// Render callbacks only copy PCM into preallocated windows. FFT stays on the consumer.
    nonisolated static func enqueue(bufferList: UnsafePointer<AudioBufferList>,
                                   format: AudioStreamBasicDescription, frameCount: Int, hostTime: Double? = nil, mediaTime: Double? = nil) {
        guard uiListeningFlag.load(ordering: .relaxed) else { return }
        pcmWindow.capture(bufferList, format: format, frames: frameCount,
            generation: publicationGeneration.load(ordering: .relaxed), hostTime: hostTime, mediaTime: mediaTime)
    }

    private func resetSpectrumReference() {
        bassEnvelope = PlaybackBassEnvelope()
        onsetDetector = PlaybackOnsetDetector()
        pulseEvents.removeAll(keepingCapacity: true)
        lastAnalysisTime = nil
        triggerHostTime = nil
        animationStartHostTime = nil
        analysisMediaTime = nil
        presentedHostTime = nil
        previousPulse = 0
        analyzer.reset()
        normalizer = PlaybackSpectrumNormalizer()
        lastEnvelopeHostTime = 0
        lastNativeSpectrumSource = nil
    }

    func setNativeSourceProvider(_ provider: (@Sendable () -> PlaybackSpectrumSource?)?,
                                 analysisProvider: (@Sendable () -> NativePlaybackAnalysisSource?)? = nil,
                                 clockProvider: (@Sendable () -> PlaybackAnalysisClock?)? = nil) {
        nativeSourceProvider = provider
        nativeAnalysisSourceProvider = analysisProvider
        self.clockProvider = clockProvider
        resetForNewItem()
    }

    func resetForNewItem() {
        stopNativeAnalysis()
        sourceProviderRevision &+= 1
        Self.publicationGeneration.wrappingAdd(1, ordering: .relaxed)
        lastAnalysisClock = nil
        clearAnalysis()
    }

    private func clearAnalysis() {
        resetSpectrumReference()
        lastLiveSampleHostTime = 0
        lastSampleHostTime = 0
        missingSamplesSince = nil
        input = analysisActive ? .waiting : .disabled
        spectrum = .zero
        ema = 0
        level = 0
        beatPulse = 0
        bandEMA = Array(repeating: 0, count: Self.bandCount)
        bands = Array(repeating: 0, count: Self.bandCount)
    }

    private func stopNativeAnalysis() {
        nativeAnalysisPlayer?.stop()
        nativeAnalysisPlayer = nil
    }

    private func updateNativeAnalysis() {
        guard analysisActive, LumaPerformance.budget.allowsAuxiliaryStreamingDecoder,
              let source = nativeAnalysisSourceProvider?() else {
            stopNativeAnalysis()
            return
        }
        let player = nativeAnalysisPlayer ?? NativePlaybackAnalysisPlayer()
        nativeAnalysisPlayer = player
        player.update(source)
    }

    private func consumeLatestSample() -> Bool {
        if let clockProvider {
            guard let current = clockProvider(), current.playing else {
                if lastAnalysisClock != nil { resetForNewItem() }
                return true
            }
            if let old = lastAnalysisClock, !old.hasSameTimeline(as: current) { resetForNewItem() }
            lastAnalysisClock = current
        }
        updateNativeAnalysis()
        var processed = 0
        while processed < 6, let sample = Self.pcmWindow.copyLatest(into: analyzer.samples,
            generation: Self.publicationGeneration.load(ordering: .relaxed), after: consumedRevision, oldestFirst: true) {
            processed += 1
            consumedRevision = sample.revision
            guard CACurrentMediaTime() - sample.receivedAt <= 0.25 else { continue }
            let now = CACurrentMediaTime()
            var presentationTime = sample.presentationTime
            if let mediaTime = sample.mediaTime, let clock = lastAnalysisClock {
                presentationTime = clock.hostTime + mediaTime - clock.position
            }
            analysisLeadSeconds = presentationTime - now
            // Native taps may decode ahead of audible playback. Analyze once now,
            // then present onset events at their media-derived host time.
            guard presentationTime >= now - 0.15, presentationTime <= now + 10 else { continue }
            let values = analyzer.analyze(sampleRate: sample.sampleRate, channels: sample.channels)
            analysisMediaTime = sample.mediaTime ?? lastAnalysisClock.map { $0.position + presentationTime - $0.hostTime }
            lastLiveSampleHostTime = sample.receivedAt
            missingSamplesSince = nil
            apply(values, input: .pcm, receivedAt: sample.receivedAt, presentationTime: presentationTime)
        }
        return lastLiveSampleHostTime > 0
            && CACurrentMediaTime() - lastLiveSampleHostTime < 0.15
    }

    private func consumeNativeFileSample() async {
        let generation = Self.publicationGeneration.load(ordering: .relaxed)
        let providerRevision = sourceProviderRevision
        if let source = nativeSourceProvider?() {
            if lastNativeSpectrumSource?.hasSameItem(as: source) != true
                || lastNativeSpectrumSource?.seekSequence != source.seekSequence {
                resetSpectrumReference()
            }
            lastNativeSpectrumSource = source
            let readAt = CACurrentMediaTime()
            let values = await fileAnalyzer.energies(at: source)
            guard !Task.isCancelled, analysisActive, sourceProviderRevision == providerRevision,
                  Self.publicationGeneration.load(ordering: .relaxed) == generation else { return }
            if let values, let current = nativeSourceProvider?(), source.isCurrent(comparedTo: current), CACurrentMediaTime() - readAt <= 0.25 {
                missingSamplesSince = nil
                analysisMediaTime = source.position
                apply(values, input: .file, receivedAt: readAt, presentationTime: readAt)
                return
            }
        }
        let now = CACurrentMediaTime()
        if missingSamplesSince == nil { missingSamplesSince = now }
        let lastInput = lastSampleHostTime > 0 ? lastSampleHostTime : (missingSamplesSince ?? now)
        guard now - lastInput >= 0.25 else { return }
        if input != .unavailable {
            input = .unavailable
            spectrum = .zero
            ema = 0
            level = 0
            beatPulse = 0
            bandEMA = Array(repeating: 0, count: Self.bandCount)
            bands = Array(repeating: 0, count: Self.bandCount)
        }
        // Missing PCM is represented by resting bars and no background pulse.
        // A playback-state oscillator cannot stand in for measured music.
        fallbackBands = Array(repeating: 0, count: Self.bandCount)
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        refreshPerformanceBudget()
    }

    /// Keep the mixer tap publishing while any UI consumer needs live energy.
    func retainUIListening(waveform: Bool = false) {
        if waveform { waveformListeners += 1 }
        listenCount += 1
        if listenCount == 1 {
            refreshPerformanceBudget()
        }
    }

    func releaseUIListening(waveform: Bool = false) {
        if waveform { waveformListeners = max(0, waveformListeners - 1) }
        listenCount = max(0, listenCount - 1)
        if listenCount == 0 {
            refreshPerformanceBudget()
        }
    }

    /// Re-applies cadence and visibility policy after thermal/power/foreground changes.
    func refreshPerformanceBudget() {
        // Construct the fixed PCM storage before the first render callback can use it.
        _ = Self.pcmWindow
        let active = enabled && listenCount > 0 && LumaPerformance.allowsBeatVisuals
        if active != analysisActive {
            Self.uiListeningFlag.store(false, ordering: .relaxed)
            Self.publicationGeneration.wrappingAdd(1, ordering: .relaxed)
            analysisActive = active
            clearAnalysis()
            logDiagnostics(force: true)
        }
        Self.uiListeningFlag.store(active, ordering: .relaxed)
        if !active || !LumaPerformance.budget.allowsAuxiliaryStreamingDecoder { stopNativeAnalysis() }
        if !active {
            publicationTask?.cancel()
            publicationTask = nil
        } else if publicationTask == nil {
            publicationTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(LumaPerformance.beatPublishInterval)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    if !self.consumeLatestSample() { await self.consumeNativeFileSample() }
                    self.logDiagnostics()
                }
            }
        }
    }

    /// Publish coalesced band energies on the main actor.
    private func apply(_ spectrum: PlaybackSpectrum, input: AnalysisInput, receivedAt: Double, presentationTime: Double) {
        guard enabled, listenCount > 0, LumaPerformance.allowsBeatVisuals else { return }

        if self.input != input {
            onsetDetector = PlaybackOnsetDetector()
            pulseEvents.removeAll(keepingCapacity: true)
            bassEnvelope = PlaybackBassEnvelope()
            lastAnalysisTime = nil
        }
        self.spectrum = spectrum
        self.input = input
        lastSampleHostTime = receivedAt
        if let lastAnalysisTime, presentationTime - lastAnalysisTime > 0.25 {
            onsetDetector = PlaybackOnsetDetector()
            pulseEvents.removeAll(keepingCapacity: true)
            bassEnvelope = PlaybackBassEnvelope()
        }
        lastAnalysisTime = presentationTime
        onsetStrength = onsetDetector.update(spectrum, at: presentationTime)
        if onsetStrength > 0 {
            pulseEvents.append((presentationTime, onsetStrength))
            if Self.diagnosticsEnabled {
                let media = analysisMediaTime ?? -1
                Logger.player.debug("[PULSE-ONSET] media_s=\(media) presentation_host=\(presentationTime) analysis_host=\(CACurrentMediaTime()) strength=\(self.onsetStrength) rms=\(spectrum.rms) peak=\(spectrum.peak) flux=\(spectrum.spectralFlux)")
            }
            if pulseEvents.count > 64 { pulseEvents.removeLast() }
        }
        updateBands(from: spectrum.bands)
    }

    private func updateBands(from raw: SIMD4<Float>) {
        let now = CACurrentMediaTime()
        let elapsed = lastEnvelopeHostTime > 0 ? max(0, now - lastEnvelopeHostTime) : LumaPerformance.beatPublishInterval
        lastEnvelopeHostTime = now
        let targets = normalizer.targets(for: raw, elapsed: elapsed)
        var nextBands: [CGFloat] = []
        for band in 0..<4 {
            bandEMA[band] = PlaybackSpectrumEnvelope.next(current: bandEMA[band],
                target: targets[band], elapsed: elapsed)
            nextBands.append(CGFloat(bandEMA[band]))
        }
        let peak = max(targets.x, targets.y, targets.z, targets.w)
        ema = PlaybackSpectrumEnvelope.next(current: ema, target: peak, elapsed: elapsed)
        level = CGFloat(ema)
        beatPulse = CGFloat(max(0, peak - ema))
        bands = nextBands
    }

    private func logDiagnostics(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastDiagnosticTime >= 3 else { return }
        lastDiagnosticTime = now
        let age = lastSampleHostTime > 0 ? Int(1000 * (now - lastSampleHostTime)) : -1
        let waveform = analysisActive && waveformListeners > 0
        let budget = LumaPerformance.budget.summary
        if Self.diagnosticsEnabled {
            let playback = clockProvider?()?.position ?? -1
            let media = analysisMediaTime ?? -1
            let trigger = triggerHostTime ?? -1
            let presented = presentedHostTime ?? -1
            let animation = animationStartHostTime ?? -1
            let delay = animation >= 0 && trigger >= 0 ? (animation - trigger) * 1000 : -1
            Logger.player.debug("[PULSE] playback_s=\(playback) analysis_media_s=\(media) rms=\(self.spectrum.rms) peak=\(self.spectrum.peak) low_rms=\(self.spectrum.bassRMS) flux=\(self.spectrum.spectralFlux) onset=\(self.onsetStrength) trigger_host=\(trigger) animation_host=\(animation) amplitude=\(self.previousPulse) display_host=\(presented) render_delay_ms=\(delay)")
        }
        Logger.player.debug("[VISUALIZER] input=\(self.input.rawValue, privacy: .public) pcm_buffer_received=\(self.input == .pcm) fft_active=\(self.hasValidAnalysis) rms=\(self.spectrum.rms) bass_energy=\(self.spectrum.bassRMS) analysis_data_age_ms=\(age) visualization_fallback_active=\(self.visualizationFallbackActive) waveform_render_active=\(waveform) animation_budget_reason=\(budget, privacy: .public)")
    }

    /// Render-thread path: four fixed SIMD lanes, no arrays, tasks, or locks.
    nonisolated static func fourBandEnergies(bufferList: UnsafePointer<AudioBufferList>,
                                             format: AudioStreamBasicDescription, frameCount: Int) -> SIMD4<Float> {
        guard frameCount > 0, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return .zero }
        let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bytes = Int(format.mBitsPerChannel / 8)
        guard (floating && (bytes == 4 || bytes == 8)) || (signed && (bytes == 2 || bytes == 4)) else { return .zero }
        var sums = SIMD4<Float>.zero
        var counts = SIMD4<Float>.zero
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let step = max(1, frameCount / 1024)
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let frames = min(frameCount, Int(buffer.mDataByteSize) / (bytes * channels))
            for frame in stride(from: 0, to: frames, by: step) {
                let band = min(3, frame * 4 / frameCount)
                for channel in 0..<min(8, channels) {
                    let index = frame * channels + channel
                    let value: Float
                    if floating {
                        value = bytes == 4 ? data.assumingMemoryBound(to: Float.self)[index]
                            : Float(data.assumingMemoryBound(to: Double.self)[index])
                    } else {
                        value = bytes == 2 ? Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
                            : Float(data.assumingMemoryBound(to: Int32.self)[index]) / 2147483648
                    }
                    guard value.isFinite else { continue }
                    sums[band] += value * value
                    counts[band] += 1
                }
            }
        }
        for band in 0..<4 { sums[band] = counts[band] > 0 ? (sums[band] / counts[band]).squareRoot() : 0 }
        return sums
    }

    /// Split the buffer into `bandCount` time slices and return per-slice RMS (real audio energy).
    nonisolated static func bandEnergies(from buffer: AVAudioPCMBuffer, bandCount: Int = bandCount) -> [Float] {
        bandEnergies(bufferList: buffer.audioBufferList, format: buffer.format.streamDescription.pointee,
                     frameCount: Int(buffer.frameLength), bandCount: bandCount)
    }

    /// Handles the tap's actual output format without forcing sample rate, channel layout or
    /// downmixing. Work is bounded to about 1024 samples per channel, at the UI publish cadence.
    nonisolated static func bandEnergies(bufferList: UnsafePointer<AudioBufferList>,
                                       format: AudioStreamBasicDescription, frameCount: Int,
                                       bandCount: Int = bandCount) -> [Float] {
        guard frameCount > 0, bandCount > 0, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
            return Array(repeating: 0, count: max(0, bandCount))
        }
        let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bytes = Int(format.mBitsPerChannel / 8)
        guard (floating && [4, 8].contains(bytes)) || (signed && [2, 4].contains(bytes)) else {
            return Array(repeating: 0, count: bandCount)
        }
        var sums = Array(repeating: Float(0), count: bandCount)
        var counts = Array(repeating: 0, count: bandCount)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let step = max(1, frameCount / (256 * bandCount))
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let frames = min(frameCount, Int(buffer.mDataByteSize) / (bytes * channels))
            for frame in stride(from: 0, to: frames, by: step) {
                let band = min(bandCount - 1, frame * bandCount / frameCount)
                for channel in 0..<min(8, channels) {
                    let index = frame * channels + channel
                    let value: Float
                    if floating {
                        value = bytes == 4 ? data.assumingMemoryBound(to: Float.self)[index]
                            : Float(data.assumingMemoryBound(to: Double.self)[index])
                    } else {
                        value = bytes == 2 ? Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
                            : Float(data.assumingMemoryBound(to: Int32.self)[index]) / 2147483648
                    }
                    guard value.isFinite else { continue }
                    sums[band] += value * value
                    counts[band] += 1
                }
            }
        }
        return (0..<bandCount).map { counts[$0] > 0 ? sqrt(sums[$0] / Float(counts[$0])) : 0 }
    }
}
