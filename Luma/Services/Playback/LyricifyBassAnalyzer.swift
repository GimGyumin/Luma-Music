// Lyricify Backgrounds — Apple Music Inspired · iOS, modern iOS background.
// Ported from https://github.com/WXRIW/Lyricify-Backgrounds
// Reference commit: cbef8a667c02a01707c78c7e76dc67d65cf161ed
// Source: Lyricify.Backgrounds.AppleMusicInspired.Windows/Rendering/AppleMusicSpectrumAnalysis.cs
// Copyright the Lyricify Backgrounds contributors. Licensed under Apache License 2.0.
// Swift port © 2026 Luma contributors.
//
// Luma feeds this analyzer from the audible AudioStreaming mixer or AVPlayer PCM tap.
// The meter delivers 2048-frame windows. This analyzer advances in 512-sample hops
// with presentation timestamps and accumulates a 4096-sample window for its precise FFT.
// See THIRD_PARTY_NOTICES.md for platform adaptations from Windows loopback.
// See Luma/Resources/Licenses/Lyricify-Apache-2.0.txt.

import Accelerate
import Foundation
import QuartzCore
import Synchronization

nonisolated final class LyricifyBassAnalyzer: @unchecked Sendable {
    static let shared = LyricifyBassAnalyzer()

    private static let preciseFFTLength = 4096
    private static let fastFFTLength = 2048
    /// The reference analyzes every ~8.3 ms at 120 Hz. A 2048-frame PCM window
    /// contains four 512-sample hops; feeding those hops separately keeps the
    /// confirmation ramp and attack detector close to the source cadence instead
    /// of smearing short kicks across a whole 46 ms window.
    static let reportHopLength = 512
    private static let missingReportSeconds: TimeInterval = 0.25

    private let lock = NSLock()
    private let preciseSetup: FFTSetup?
    private let fastSetup: FFTSetup?
    private let preciseHann: [Float]
    private let fastHann: [Float]
    private var ring = [Float](repeating: 0, count: preciseFFTLength)
    private var writeIndex = 0
    private var available = 0
    private var sampleRate = 44_100.0
    private var transient = BassTransientDetector()
    private var preciseState = BassFeatureState()
    private var fastState = BassFeatureState()
    private var transientState = BassFeatureState()
    private var preciseFloating = [Float](repeating: 0, count: preciseFFTLength)
    private var preciseImaginary = [Float](repeating: 0, count: preciseFFTLength)
    private var fastFloating = [Float](repeating: 0, count: fastFFTLength)
    private var fastImaginary = [Float](repeating: 0, count: fastFFTLength)
    private var reportHistory = [Float](repeating: 0, count: 3)
    private var reportIndex = 0
    private var availableReports = 0
    private var recentReports = [Float](repeating: 0, count: 4)
    private var recentIndex = 0
    private var targetPower: Float = 0
    private var power: Float = 0
    private var lastProcessTime: CFTimeInterval = 0
    private var expectedMediaTime: Double?
    private var lastUnprocessed: Float = 0
    private var lastConfirmed: Float = 0
    private var peakLevel: Float = 0
    private var peakDominance: Float = 0
    private var peakTransient: Float = 0
    private var peakUnprocessed: Float = 0
    private var peakConfirmed: Float = 0
    private var peakPower: Float = 0
    private var lastInputRMS: Float = 0
    private var peakInputRMS: Float = 0
    /// The tap decodes ahead of audible playback. Keep the smoothed power at its
    /// media-derived host time so the background reacts when the sound is heard,
    /// not when the decoder produced it.
    private static let historyCapacity = 128
    private var historyTimes = [Double](repeating: 0, count: historyCapacity)
    private var historyValues = [Float](repeating: 0, count: historyCapacity)
    private var historyIndex = 0

    private init() {
        preciseSetup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))
        fastSetup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))
        var precise = [Float](repeating: 0, count: Self.preciseFFTLength)
        var fast = [Float](repeating: 0, count: Self.fastFFTLength)
        vDSP_hann_window(&precise, vDSP_Length(Self.preciseFFTLength), Int32(vDSP_HANN_DENORM))
        vDSP_hann_window(&fast, vDSP_Length(Self.fastFFTLength), Int32(vDSP_HANN_DENORM))
        preciseHann = precise
        fastHann = fast
    }

    deinit {
        if let preciseSetup { vDSP_destroy_fftsetup(preciseSetup) }
        if let fastSetup { vDSP_destroy_fftsetup(fastSetup) }
    }

    /// Process one PCM window. `channelData` must contain pointers valid for the duration of
    /// the call; samples are downmixed to mono for the Lyricify bass analysis.
    func process(
        channelData: [UnsafePointer<Float>],
        frameCount: Int,
        sampleRate newSampleRate: Double,
        hostTime: Double = 0,
        mediaTime: Double? = nil
    ) {
        guard frameCount > 0, !channelData.isEmpty, newSampleRate.isFinite, newSampleRate > 0 else { return }
        lock.withLock {
            if abs(sampleRate - newSampleRate) > 0.5 {
                sampleRate = newSampleRate
                resetLocked()
            }
            let channels = min(channelData.count, 8)
            let count = min(frameCount, 8192)
            // `mediaTime` is the centre of a 2048-frame window, and native taps can
            // deliver it in render-quantum-sized pieces. A two-sample tolerance fired
            // on every window and cleared the confirmation/power history before it could
            // accumulate, pinning the pulse at its single-report value. Only a real
            // timeline break (seek/stall) should reset the analyzer.
            if let mediaTime, let expectedMediaTime,
               abs(mediaTime - expectedMediaTime) > 0.25 {
                resetLocked()
            }
            if transient.sampleRate != Int(sampleRate) {
                transient.configure(sampleRate: Int(sampleRate))
            }
            for frame in 0..<count {
                var sum: Float = 0
                var used = 0
                for channel in 0..<channels {
                    let value = channelData[channel][frame]
                    if value.isFinite {
                        sum += value
                        used += 1
                    }
                }
                let sample = used > 0 ? sum / Float(used) : 0
                transient.push(sample)
                ring[writeIndex] = min(4, max(-4, sample))
                writeIndex = (writeIndex + 1) % Self.preciseFFTLength
                available = min(available + 1, Self.preciseFFTLength)
            }
            #if DEBUG
            var inputSum: Float = 0
            for frame in 0..<count {
                let value = channelData[0][frame]
                inputSum += value * value
            }
            lastInputRMS = count > 0 ? (inputSum / Float(count)).squareRoot() : 0
            peakInputRMS = max(peakInputRMS, lastInputRMS)
            #endif
            expectedMediaTime = mediaTime.map { $0 + Double(count) / sampleRate }
            analyzeLocked()
            recordPower(at: hostTime)
            lastProcessTime = CACurrentMediaTime()
        }
    }

    func process(
        samples: UnsafePointer<Float>,
        channelStride: Int,
        channelCount: Int,
        frameCount: Int,
        sampleRate: Double,
        hostTime: Double = 0,
        mediaTime: Double? = nil
    ) {
        guard channelCount > 0, channelStride > 0 else { return }
        var pointers: [UnsafePointer<Float>] = []
        pointers.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            pointers.append(samples.advanced(by: channel * channelStride))
        }
        process(channelData: pointers, frameCount: frameCount,
            sampleRate: sampleRate, hostTime: hostTime, mediaTime: mediaTime)
    }

    /// Consume one PCM window in report-sized hops. `windowStartMediaTime` is the
    /// media timestamp of the first sample, if the caller has one.
    func processWindow(
        channelData: [UnsafePointer<Float>],
        frameCount: Int,
        sampleRate: Double,
        windowStartMediaTime: Double? = nil,
        windowStartHostTime: Double? = nil
    ) {
        guard frameCount > 0, !channelData.isEmpty else { return }
        var start = 0
        while start < frameCount {
            let count = min(Self.reportHopLength, frameCount - start)
            let pointers = channelData.map { $0.advanced(by: start) }
            let media = windowStartMediaTime.map {
                $0 + Double(start + count / 2) / sampleRate
            }
            let host = windowStartHostTime.map {
                $0 + Double(start + count / 2) / sampleRate
            }
            process(channelData: pointers, frameCount: count,
                sampleRate: sampleRate, hostTime: host ?? 0, mediaTime: media)
            start += count
        }
    }

    /// 0...1 Lyricify processed low-frequency response. Returns 0 after 250 ms without PCM.
    var pulsePower: Float {
        lock.withLock {
            let now = CACurrentMediaTime()
            guard lastProcessTime > 0,
                  now - lastProcessTime <= Self.missingReportSeconds else { return 0 }
            var selectedTime = -Double.infinity
            var selected: Float = 0
            var hasHistory = false
            for index in 0..<Self.historyCapacity where historyTimes[index] > 0 {
                hasHistory = true
                let time = historyTimes[index]
                if time <= now + 1.0 / 120, time > selectedTime {
                    selectedTime = time
                    selected = historyValues[index]
                }
            }
            // Before the first timestamped report (e.g. a file reader without a
            // media clock), expose the live power immediately.
            guard hasHistory else { return processSpectrumPower(power) }
            guard selectedTime > -Double.infinity else { return 0 }
            return selected
        }
    }

    private func recordPower(at hostTime: Double) {
        let time = hostTime > 0 ? hostTime : CACurrentMediaTime()
        historyTimes[historyIndex] = time
        historyValues[historyIndex] = processSpectrumPower(power)
        historyIndex = (historyIndex + 1) % Self.historyCapacity
    }

    /// Exact image-scale mapping from Lyricify `GetImageScales`: 1 + 0.33 * power².
    var imageScale: Float {
        let value = pulsePower
        return 1 + 0.33 * value * value
    }

    func reset() {
        lock.withLock {
            resetLocked()
            peakLevel = 0
            peakDominance = 0
            peakTransient = 0
            peakUnprocessed = 0
            peakConfirmed = 0
            peakPower = 0
            peakInputRMS = 0
        }
    }

    private func resetLocked() {
        ring = [Float](repeating: 0, count: Self.preciseFFTLength)
        writeIndex = 0
        available = 0
        transient.reset()
        preciseState = BassFeatureState()
        fastState = BassFeatureState()
        transientState = BassFeatureState()
        reportHistory = [Float](repeating: 0, count: 3)
        reportIndex = 0
        availableReports = 0
        recentReports = [Float](repeating: 0, count: 4)
        recentIndex = 0
        targetPower = 0
        power = 0
        lastProcessTime = 0
        expectedMediaTime = nil
        lastUnprocessed = 0
        lastConfirmed = 0
        lastInputRMS = 0
        historyTimes = [Double](repeating: 0, count: Self.historyCapacity)
        historyValues = [Float](repeating: 0, count: Self.historyCapacity)
        historyIndex = 0
    }

    private func analyzeLocked() {
        guard available >= Self.fastFFTLength else { return }
        let fastResponse = response(
            length: Self.fastFFTLength,
            setup: fastSetup,
            hann: fastHann,
            floating: &fastFloating,
            imaginary: &fastImaginary,
            state: &fastState)
        var preciseResponse: Float = 0
        if available >= Self.preciseFFTLength {
            preciseResponse = response(
                length: Self.preciseFFTLength,
                setup: preciseSetup,
                hann: preciseHann,
                floating: &preciseFloating,
                imaginary: &preciseImaginary,
                state: &preciseState)
        }
        let transientPowers = transient.powers()
        let transientResponse = bassResponse(
            bassPower: transientPowers.bass,
            referencePower: transientPowers.reference,
            state: &transientState)
        let unprocessed = max(transientResponse, max(fastResponse, preciseResponse))
        let immediate = shouldTriggerImmediately(
            transient: transientResponse, fast: fastResponse)
        let confirmed = confirmedResponse(unprocessed, allowImmediateTrigger: immediate)
        lastUnprocessed = unprocessed
        lastConfirmed = confirmed

        recentReports[recentIndex] = confirmed
        recentIndex = (recentIndex + 1) % recentReports.count
        var weighted: Float = 0
        let ramp: [Float] = [0.1, 0.2, 0.3, 0.4]
        for index in 0..<recentReports.count {
            let sampleIndex = (recentIndex + index) % recentReports.count
            weighted += recentReports[sampleIndex] * ramp[index]
        }
        // Same target decay/follow shape as Lyricify's UpdateSpectrumPower, applied at the
        // available 30 Hz report cadence instead of 60/120 Hz.
        targetPower = max(weighted, targetPower * 0.98)
        power += (targetPower - power) * 0.5
        if power < 0.00000001 { power = 0 }
        peakLevel = max(peakLevel, fastState.debugLevel)
        peakDominance = max(peakDominance, fastState.debugDominance)
        peakTransient = max(peakTransient, fastState.debugTransient)
        peakUnprocessed = max(peakUnprocessed, unprocessed)
        peakConfirmed = max(peakConfirmed, confirmed)
        peakPower = max(peakPower, processSpectrumPower(power))
    }

    private func response(
        length: Int,
        setup: FFTSetup?,
        hann: [Float],
        floating: inout [Float],
        imaginary: inout [Float],
        state: inout BassFeatureState
    ) -> Float {
        guard let setup, floating.count == length, imaginary.count == length else { return 0 }
        let start = (writeIndex - length + Self.preciseFFTLength) % Self.preciseFFTLength
        for index in 0..<length {
            floating[index] = ring[(start + index) % Self.preciseFFTLength] * hann[index]
            imaginary[index] = 0
        }
        floating.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                vDSP_fft_zip(setup, &split, 1,
                    vDSP_Length(log2(Double(length))), FFTDirection(FFT_FORWARD))
            }
        }

        let low = bandPower(floating, imaginary, length: length,
            band: 30...105, sampleRate: sampleRate)
        let bassNote = bandPower(floating, imaginary, length: length,
            band: 75...155, sampleRate: sampleRate)
        let upper = bandPower(floating, imaginary, length: length,
            band: 145...210, sampleRate: sampleRate)
        let lowMid = bandPower(floating, imaginary, length: length,
            band: 155...380, sampleRate: sampleRate)
        let mid = bandPower(floating, imaginary, length: length,
            band: 380...760, sampleRate: sampleRate)
        let core = max(low, bassNote * 0.9)
        let supportedUpper = min(upper, core * 1.35)
        let bass = core + supportedUpper * 0.2
        let reference = max(lowMid * 2.3, mid * 1.6)
        return bassResponse(bassPower: bass, referencePower: reference, state: &state)
    }

    private func bandPower(
        _ real: [Float], _ imaginary: [Float], length: Int,
        band: ClosedRange<Double>, sampleRate: Double
    ) -> Double {
        let firstBin = max(1, Int(ceil(band.lowerBound * Double(length) / sampleRate)))
        let lastBin = min(length / 2 - 1, Int(floor(band.upperBound * Double(length) / sampleRate)))
        guard lastBin >= firstBin else { return 0 }
        let scale = 4.0 / Double(length)
        var squared = 0.0
        for bin in firstBin...lastBin {
            let re = Double(real[bin]) * scale
            let im = Double(imaginary[bin]) * scale
            squared += re * re + im * im
        }
        return squared / (3.0 * Double(lastBin - firstBin + 1))
    }

    private func bassResponse(
        bassPower: Double, referencePower: Double, state: inout BassFeatureState
    ) -> Float {
        let bassDecibels = powerToDecibels(bassPower)
        let referenceDecibels = powerToDecibels(referencePower)
        if !state.initialized {
            state.slowBassDecibels = max(-72, bassDecibels - 7)
            state.slowReferenceDecibels = referenceDecibels
            state.previousBassDecibels = bassDecibels
            state.initialized = true
        }
        let frameBassRise = max(0, bassDecibels - state.previousBassDecibels)
        state.previousBassDecibels = bassDecibels
        let bassRise = max(0, bassDecibels - state.slowBassDecibels)
        let referenceRise = max(0, referenceDecibels - state.slowReferenceDecibels)
        let dominance = smoothRange(
            bassDecibels - referenceDecibels, floor: 0, ceiling: 8)
        let sharpAttackTarget = bassDecibels >= -45
            ? smoothRange(frameBassRise, floor: 7, ceiling: 14) : 0
        let reportRate = Float(sampleRate / Double(Self.reportHopLength))
        let sharpAttackDecay = Float(exp(Double(-1 / (reportRate * 0.09))))
        state.sharpAttack = max(sharpAttackTarget, state.sharpAttack * sharpAttackDecay)
        let harmonicConfidence = smoothRange(
            dominance, floor: 0.12, ceiling: 0.3) * state.sharpAttack * 0.9
        let bassConfidence = max(dominance, harmonicConfidence)
        let referenceRiseRejection = 0.7 - dominance * 0.35
        let bassOnlyRise = bassRise - referenceRise * referenceRiseRejection
        let seconds = 1 / reportRate
        state.slowBassDecibels = smoothBaseline(
            state.slowBassDecibels, target: bassDecibels, seconds: seconds)
        state.slowReferenceDecibels = smoothBaseline(
            state.slowReferenceDecibels, target: referenceDecibels, seconds: seconds)
        let level = smoothRange(bassDecibels, floor: -50, ceiling: -18)
        let transient = smoothRange(bassOnlyRise, floor: 1.2, ceiling: 7)
        state.debugLevel = level
        state.debugDominance = dominance
        state.debugTransient = transient
        state.debugBassDecibels = bassDecibels
        state.debugReferenceDecibels = referenceDecibels
        return min(1, max(0, level * bassConfidence
            * (0.1 + (1 - 0.1) * transient)))
    }

    private func confirmedResponse(_ unprocessed: Float, allowImmediateTrigger: Bool) -> Float {
        reportHistory[reportIndex] = unprocessed
        reportIndex = (reportIndex + 1) % reportHistory.count
        availableReports = min(availableReports + 1, reportHistory.count)
        if allowImmediateTrigger { return unprocessed }
        if availableReports == 2 {
            return min(reportHistory[0], reportHistory[1])
        }
        if availableReports >= 3 {
            let sorted = reportHistory.sorted()
            return sorted[1]
        }
        return 0
    }

    private func shouldTriggerImmediately(transient: Float, fast: Float) -> Bool {
        (transient >= 0.72 && fast >= 0.32) || (fast >= 0.72 && transient >= 0.32)
    }

    private func powerToDecibels(_ power: Double) -> Float {
        Float(10 * log10(max(power, 1e-12)))
    }

    private func smoothRange(_ value: Float, floor: Float, ceiling: Float) -> Float {
        let normalized = min(1, max(0, (value - floor) / (ceiling - floor)))
        return normalized * normalized * (3 - 2 * normalized)
    }

    private func smoothBaseline(_ current: Float, target: Float, seconds: Float) -> Float {
        let timeConstant: Float = target > current ? 1.1 : 0.16
        let mix = Float(exp(Double(-seconds / timeConstant)))
        return max(-72, current + (target - current) * mix)
    }

    private func processSpectrumPower(_ value: Float) -> Float {
        let x = min(1, max(0, value))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    var debugSummary: String {
        lock.withLock {
            func lane(_ state: BassFeatureState) -> String {
                String(format: "%.2f/%.2f/%.2f@%.0f/%.0fdB",
                    state.debugLevel, state.debugDominance, state.debugTransient,
                    state.debugBassDecibels, state.debugReferenceDecibels)
            }
            let peak = String(format: "%.2f/%.2f/%.2f/%.2f/%.2f/%.2f",
                peakLevel, peakDominance, peakTransient,
                peakUnprocessed, peakConfirmed, peakPower)
            return "fast=\(lane(fastState)) precise=\(lane(preciseState)) "
                + "transient=\(lane(transientState)) unprocessed=\(String(format: "%.2f", lastUnprocessed)) "
                + "confirmed=\(String(format: "%.2f", lastConfirmed)) "
                + "target=\(String(format: "%.2f", targetPower)) power=\(String(format: "%.2f", power)) "
                + "pulse=\(String(format: "%.3f", processSpectrumPower(power))) "
                + "peak=\(peak) input_rms=\(String(format: "%.3f/%.3f", lastInputRMS, peakInputRMS))"
        }
    }
}

private nonisolated struct BassFeatureState {
    var slowBassDecibels: Float = 0
    var slowReferenceDecibels: Float = 0
    var previousBassDecibels: Float = 0
    var sharpAttack: Float = 0
    var initialized = false
    var debugLevel: Float = 0
    var debugDominance: Float = 0
    var debugTransient: Float = 0
    var debugBassDecibels: Float = 0
    var debugReferenceDecibels: Float = 0
}

private nonisolated struct BassTransientDetector {
    private var lowCutoff = BiquadLowPass()
    private var bassCutoff = BiquadLowPass()
    private var referenceCutoff = BiquadLowPass()
    private(set) var sampleRate = 0
    private var bassPower = 0.0
    private var referencePower = 0.0

    mutating func configure(sampleRate: Int) {
        self.sampleRate = max(1, sampleRate)
        lowCutoff.configure(cutoff: 25, sampleRate: Float(self.sampleRate), q: 0.70710678)
        bassCutoff.configure(cutoff: 190, sampleRate: Float(self.sampleRate), q: 0.70710678)
        referenceCutoff.configure(cutoff: 760, sampleRate: Float(self.sampleRate), q: 0.70710678)
        bassPower = 0
        referencePower = 0
    }

    mutating func push(_ sample: Float) {
        guard sampleRate > 0 else { return }
        let low = lowCutoff.process(sample)
        let bassTop = bassCutoff.process(sample)
        let referenceTop = referenceCutoff.process(sample)
        let bass = bassTop - low
        let reference = referenceTop - bassTop
        updateEnvelope(&bassPower, target: Double(bass * bass))
        updateEnvelope(&referencePower, target: Double(reference * reference))
    }

    func powers() -> (bass: Double, reference: Double) {
        (max(bassPower, 1e-12), max(referencePower, 1e-12))
    }

    mutating func reset() {
        lowCutoff.reset()
        bassCutoff.reset()
        referenceCutoff.reset()
        bassPower = 0
        referencePower = 0
    }

    private func updateEnvelope(_ current: inout Double, target: Double) {
        let seconds = target > current ? 0.006 : 0.045
        let retain = exp(-1 / (Double(sampleRate) * seconds))
        current = current * retain + target * (1 - retain)
    }
}

private nonisolated struct BiquadLowPass {
    private var b0: Float = 1
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var z1: Float = 0
    private var z2: Float = 0

    mutating func configure(cutoff: Float, sampleRate: Float, q: Float) {
        let maximum = sampleRate * 0.49
        let omega = 2 * Float.pi * min(max(cutoff, 1), maximum) / sampleRate
        let sine = sin(omega)
        let cosine = cos(omega)
        let alpha = sine / (2 * q)
        let inverseA0 = 1 / (1 + alpha)
        b0 = (1 - cosine) * 0.5 * inverseA0
        b1 = (1 - cosine) * inverseA0
        b2 = b0
        a1 = -2 * cosine * inverseA0
        a2 = (1 - alpha) * inverseA0
        reset()
    }

    mutating func process(_ sample: Float) -> Float {
        let output = b0 * sample + z1
        z1 = b1 * sample - a1 * output + z2
        z2 = b2 * sample - a2 * output
        return output.isFinite ? output : 0
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }
}
