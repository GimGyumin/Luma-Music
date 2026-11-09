import Testing
import Foundation
import AVFoundation
import QuartzCore
@testable import Luma

@Suite("Native decoded-audio meter", .serialized) @MainActor
struct NativePlaybackMeterTests {
    @Test("Missing PCM leaves resting bars and a real silent frame restores analysis")
    func waveformFallbackRecovers() async throws {
        let budget = LumaPerformance.budget
        LumaPerformance.publish(.placeholder)
        let meter = PlaybackBeatMeter.shared
        meter.setNativeSourceProvider(nil)
        meter.setEnabled(true)
        meter.retainUIListening(waveform: true)
        defer {
            meter.releaseUIListening(waveform: true)
            meter.setEnabled(false)
            LumaPerformance.publish(budget)
        }
        let deadline = Date().addingTimeInterval(2)
        while !meter.visualizationFallbackActive && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(meter.visualizationFallbackActive)
        let first = meter.fallbackBands
        try await Task.sleep(for: .milliseconds(100))
        #expect(meter.fallbackBands == first && first.allSatisfy { $0 == 0 })
        #expect(meter.backgroundBass == 0 && meter.spectrum == .zero && !meter.hasValidAnalysis)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048))
        pcm.frameLength = 2048
        pcm.floatChannelData?[0].update(repeating: 0, count: 2048)
        PlaybackBeatMeter.enqueue(buffer: pcm)
        // Analysis is delivered asynchronously. A fixed 100ms sleep races the
        // parallel test runner; wait for the observable state instead of
        // weakening the assertions.
        let analysisDeadline = Date().addingTimeInterval(2)
        while !meter.hasValidAnalysis && Date() < analysisDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(meter.hasValidAnalysis && meter.input == .pcm && !meter.visualizationFallbackActive)
        #expect(meter.spectrum == .zero && meter.bands.allSatisfy { $0 == 0 })
        meter.resetForNewItem()
        #expect(!meter.hasValidAnalysis)
    }

    @Test("Timestamped transients follow AVPlayer's audible timeline")
    func nativeOnsetPresentationTiming() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-timing-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 44100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 220500))
            pcm.frameLength = 220500
            let samples = try #require(pcm.floatChannelData)[0]
            for frame in 0..<220500 {
                let time = Double(frame) / rate
                let age = time - floor(time)
                samples[frame] = time >= 1 && time < 4.2 && age < 0.085
                    ? 0.5 * Float(sin(2 * .pi * 94 * time) * exp(-age / 0.03)) : 0
            }
            try file.write(from: pcm)
        }
        let budget = LumaPerformance.budget
        LumaPerformance.publish(.placeholder)
        let meter = PlaybackBeatMeter.shared
        let engine = AVPlayerPlaybackEngine()
        meter.setNativeSourceProvider(nil, clockProvider: { [weak engine] in engine?.analysisClock })
        meter.setEnabled(true)
        meter.retainUIListening()
        defer {
            engine.stop(); meter.releaseUIListening(); meter.setEnabled(false); meter.setNativeSourceProvider(nil)
            LumaPerformance.publish(budget)
        }
        engine.start(url: url, headers: [:], generation: 1, allowsAudioAnalysis: true)
        var trigger: Double?
        var delays: [Double] = []
        var maxRMS: Float = 0
        var maxPulse: Float = 0
        var maxFlux: Float = 0
        var maxLead: Double = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(7))
        while engine.progress < 4.4, ContinuousClock.now < deadline {
            let hostTime = CACurrentMediaTime()
            let pulse = meter.pulse(at: hostTime)
            maxRMS = max(maxRMS, meter.spectrum.rms)
            maxPulse = max(maxPulse, pulse)
            maxFlux = max(maxFlux, meter.spectrum.spectralFlux)
            maxLead = max(maxLead, meter.analysisLeadSeconds)
            if pulse > 0.001, let next = meter.triggerHostTime, next != trigger {
                trigger = next
                let media = engine.progress
                let expected = media.rounded()
                if expected >= 1 && expected <= 4 { delays.append(media - expected) }
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        print("PULSE-INPUT input=\(meter.input) rms=\(maxRMS) pulse=\(maxPulse) flux=\(maxFlux) media=\(meter.analysisMediaTime ?? -1) progress=\(engine.progress) max_lead_s=\(maxLead)")
        #expect(delays.count >= 3)
        #expect(delays.allSatisfy { $0 >= -0.06 && $0 <= 0.15 })
        if !delays.isEmpty {
            print("PULSE-TIMING events=\(delays.count) mean_ms=\(delays.reduce(0, +) / Double(delays.count) * 1000) worst_ms=\(delays.map(abs).max()! * 1000)")
        }
        engine.pause()
        try await Task.sleep(for: .milliseconds(80))
        #expect(meter.pulse(at: CACurrentMediaTime()) == 0)
        #expect(meter.analysisMediaTime == nil)
    }

    @Test("AVPlayer PCM drives the meter, silence decays, and seek retains transport")
    func nativePCM() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meter-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 176400))
            pcm.frameLength = 176400
            let samples = try #require(pcm.floatChannelData)[0]
            for frame in 0..<176400 {
                samples[frame] = frame < 88200 ? 0.24 * sin(Float(frame) * 2 * .pi * 440 / 44100) : 0
            }
            try file.write(from: pcm)
        }
        // This verifies PCM delivery, independently of the host's thermal/foreground budget.
        let previousBudget = LumaPerformance.budget
        LumaPerformance.publish(.placeholder)
        defer { LumaPerformance.publish(previousBudget); PlaybackBeatMeter.shared.refreshPerformanceBudget() }
        let meter = PlaybackBeatMeter.shared
        let engine = AVPlayerPlaybackEngine()
        meter.setNativeSourceProvider(nil, clockProvider: { [weak engine] in engine?.analysisClock })
        meter.setEnabled(true)
        meter.retainUIListening()
        defer { engine.stop(); meter.releaseUIListening(); meter.setEnabled(false); meter.setNativeSourceProvider(nil) }
        engine.start(url: url, headers: [:], generation: 1, allowsAudioAnalysis: true)
        let id = try #require(engine.playerIdentity)
        let deadline = Date().addingTimeInterval(6)
        while meter.level < 0.1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(meter.level > 0.1)
        let peak = meter.level
        engine.seek(to: 2.4)
        let quietDeadline = Date().addingTimeInterval(3)
        while (engine.isSeeking || meter.level > peak * 0.25), Date() < quietDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(meter.level < peak * 0.25)
        #expect(engine.playerIdentity == id)
        #expect(!engine.lastSeekFailed)
        engine.pause()
        #expect(engine.timeControlStatus == .paused)
    }
}
