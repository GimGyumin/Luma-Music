import Testing
import Foundation
import AVFoundation
@testable import Luma

/// Coverage for the audio-thread band analysis that the beat visuals depend on. The function is
/// pure (buffer in, energies out), so it can be asserted exactly instead of eyeballed on a device.
@Suite("PlaybackBeatMeter")
struct PlaybackBeatMeterTests {
    private func buffer(filledWith fill: (Int) -> Float, frameCount: AVAudioFrameCount = 1024) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try #require(buffer.floatChannelData)
        for index in 0..<Int(frameCount) {
            samples[0][index] = fill(index)
        }
        return buffer
    }

    @Test("Bands split the buffer into equal time slices and report per-slice RMS")
    func bandsSplitBufferIntoTimeSlices() throws {
        // First half silent, second half full scale: the first bands must read silence, the last
        // bands full energy — this is what makes the equalizer react to *when* the beat hits.
        let buffer = try buffer(filledWith: { $0 < 512 ? 0 : 1 })
        let bands = PlaybackBeatMeter.bandEnergies(from: buffer, bandCount: 4)
        #expect(bands.count == 4)
        #expect(abs(bands[0]) < 0.0001)
        #expect(abs(bands[1]) < 0.0001)
        #expect(abs(bands[2] - 1) < 0.0001)
        #expect(abs(bands[3] - 1) < 0.0001)
    }

    @Test("Band energies are RMS, not peak")
    func bandsReportRMS() throws {
        // A 0.5-amplitude square wave has RMS 0.5 (a peak-based implementation would report 1.0).
        let buffer = try buffer(filledWith: { _ in 0.5 })
        let bands = PlaybackBeatMeter.bandEnergies(from: buffer, bandCount: 2)
        for energy in bands {
            #expect(abs(energy - 0.5) < 0.0001)
        }
    }

    @Test("Degenerate buffers yield a full-length zero array")
    func degenerateInputsAreSafe() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        empty.frameLength = 0
        #expect(PlaybackBeatMeter.bandEnergies(from: empty, bandCount: 4) == [0, 0, 0, 0])
        let buffer = try buffer(filledWith: { _ in 1 })
        #expect(PlaybackBeatMeter.bandEnergies(from: buffer, bandCount: 0).isEmpty)
    }

    @Test("Interleaved stereo reads both channels without advancing past storage")
    func interleavedStereo() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 44100, channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let data = try #require(buffer.floatChannelData)[0]
        for frame in 0..<1024 { data[frame * 2] = 0; data[frame * 2 + 1] = 1 }
        #expect(PlaybackBeatMeter.bandEnergies(from: buffer).allSatisfy { abs($0 - sqrt(0.5)) < 0.0001 })
    }

    @Test("Native Float64 PCM is analyzed without format conversion")
    func nativeFloat64() throws {
        var samples = Array(repeating: Double(0.25), count: 128)
        let format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 1, mBitsPerChannel: 64, mReserved: 0)
        let result = samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            return PlaybackBeatMeter.bandEnergies(bufferList: &list, format: format, frameCount: 128)
        }
        #expect(result == [0.25, 0.25, 0.25, 0.25])
    }
}

@Suite("Playback frequency spectrum")
struct PlaybackSpectrumTests {
    private func buffer(filledWith fill: (Int) -> Float, frameCount: AVAudioFrameCount = 1024) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        pcm.frameLength = frameCount
        let data = try #require(pcm.floatChannelData)[0]
        for i in 0..<Int(frameCount) { data[i] = fill(i) }
        return pcm
    }

    private func tone(bin: Int, sampleRate: Double = 48000, stereo: Bool = false,
                      oppositePhase: Bool = false) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: stereo ? 2 : 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048))
        pcm.frameLength = 2048
        let data = try #require(pcm.floatChannelData)
        for frame in 0..<2048 {
            let sample = 0.5 * sin(Float(frame * bin) * 2 * .pi / 2048)
            data[0][frame] = stereo && !oppositePhase ? 0 : sample
            if stereo { data[1][frame] = oppositePhase ? -sample : sample }
        }
        return pcm
    }

    private func analysis(_ pcm: AVAudioPCMBuffer) throws -> PlaybackSpectrum {
        let mailbox = PlaybackPCMWindow()
        let analyzer = PlaybackSpectrumAnalyzer()
        mailbox.capture(pcm.audioBufferList, format: pcm.format.streamDescription.pointee,
            frames: Int(pcm.frameLength), generation: 1)
        let snapshot = try #require(mailbox.copyLatest(into: analyzer.samples, generation: 1, after: 0))
        return analyzer.analyze(sampleRate: snapshot.sampleRate, channels: snapshot.channels)
    }

    private func spectrum(_ pcm: AVAudioPCMBuffer) throws -> SIMD4<Float> {
        try analysis(pcm).bands
    }

    @Test func backgroundPulseIsolatesKickFromTheRestOfTheLowBar() throws {
        let kick = try analysis(tone(bin: 4, stereo: true, oppositePhase: true)) // 93.75 Hz
        let upperBass = try analysis(tone(bin: 9)) // 211 Hz, also in the first bar
        #expect(kick.bassRMS > 0.3 && upperBass.bands.x > 0.3)
        #expect(upperBass.bassRMS < 0.001)
        #expect(try analysis(tone(bin: 0)).bassRMS == 0)
    }

    @Test func pulseUsesFiniteAttackAndReleaseWithoutSustainedVolume() {
        var envelope = PlaybackBassEnvelope()
        envelope.trigger(strength: 0.8, at: 2)
        #expect(envelope.value(at: 2) == 0)
        #expect(abs(envelope.value(at: 2 + PlaybackBassEnvelope.attack) - 0.8) < 0.0001)
        #expect(envelope.value(at: 2.02) > 0 && envelope.value(at: 2.02) < 0.8)
        #expect(envelope.value(at: 2.35) == 0)
        for i in 1..<100 { envelope.trigger(strength: 0.8, at: Double(i) * 0.1) }
        #expect(envelope.value(at: 9.95) <= 0.85)
    }

    @Test func sustainedBassCannotProduceMoreAttacksAndSilenceHasNoPulse() {
        var detector = PlaybackOnsetDetector()
        var count = 0
        for i in 0..<120 {
            let spectrum = PlaybackSpectrum(bassRMS: 0.2, rms: 0.3, peak: 0.7,
                spectralFlux: i == 0 ? 1 : 0)
            if detector.update(spectrum, at: Double(i) / 30) > 0 { count += 1 }
        }
        #expect(count == 1)
        #expect(detector.update(.zero, at: 4.1) == 0)
        let kick = PlaybackSpectrum(bassRMS: 0.65, rms: 0.75, peak: 0.95, spectralFlux: 0.8)
        #expect(detector.update(kick, at: 4.2) > 0)
        #expect(detector.update(kick, at: 4.23) == 0)
        #expect(detector.update(kick, at: 3) == 0)
    }

    @Test func negligibleSignalsAreNotNormalizedToFullPulse() {
        var detector = PlaybackOnsetDetector()
        let noise = PlaybackSpectrum(bassRMS: 0.0001, rms: 0.0002, peak: 0.0004, spectralFlux: 2)
        for i in 0..<100 { #expect(detector.update(noise, at: Double(i) / 30) == 0) }
    }

    @Test func tapTimestampRepresentsTheActualCenterOfThePCMWindow() throws {
        let pcm = try tone(bin: 4)
        let mailbox = PlaybackPCMWindow()
        let analyzer = PlaybackSpectrumAnalyzer()
        mailbox.capture(pcm.audioBufferList, format: pcm.format.streamDescription.pointee,
            frames: 2048, generation: 1, hostTime: 10, mediaTime: 42)
        let result = try #require(mailbox.copyLatest(into: analyzer.samples, generation: 1, after: 0))
        #expect(abs(result.presentationTime - (10 + 1024 / pcm.format.sampleRate)) < 0.00001)
        #expect(abs(try #require(result.mediaTime) - (42 + 1024 / pcm.format.sampleRate)) < 0.00001)
        #expect(mailbox.copyLatest(into: analyzer.samples, generation: 2, after: 0) == nil)
        let first = analyzer.analyze(sampleRate: pcm.format.sampleRate, channels: 1)
        let steady = analyzer.analyze(sampleRate: pcm.format.sampleRate, channels: 1)
        #expect(first.spectralFlux > 0 && steady.spectralFlux < 0.0001)
        #expect(first.peak > first.rms)
    }

    @Test func transientBeforeALargerNativeBufferTailIsRetained() throws {
        let pcm = try buffer(filledWith: { $0 < 2048 ? 0.5 : 0 }, frameCount: 8192)
        let mailbox = PlaybackPCMWindow()
        let analyzer = PlaybackSpectrumAnalyzer()
        mailbox.capture(pcm.audioBufferList, format: pcm.format.streamDescription.pointee,
            frames: 8192, generation: 1, hostTime: 10, mediaTime: 1)
        var revision: UInt64 = 0
        var levels: [Float] = []
        var positions: [Double] = []
        while let next = mailbox.copyLatest(into: analyzer.samples, generation: 1, after: revision, oldestFirst: true) {
            revision = next.revision
            levels.append(analyzer.analyze(sampleRate: next.sampleRate, channels: next.channels).rms)
            positions.append(try #require(next.mediaTime))
        }
        #expect(levels.count == 4 && levels[0] == 0.5)
        #expect(levels.dropFirst().allSatisfy { $0 == 0 })
        #expect(positions == positions.sorted())
    }

    @Test func seekDiscontinuityCannotConcatenateTwoHalfWindows() throws {
        let pcm = try buffer(filledWith: { _ in 0.5 })
        let mailbox = PlaybackPCMWindow()
        let analyzer = PlaybackSpectrumAnalyzer()
        for mediaTime in [1.0, 20.0] {
            mailbox.capture(pcm.audioBufferList, format: pcm.format.streamDescription.pointee,
                frames: 1024, generation: 1, hostTime: 10, mediaTime: mediaTime)
        }
        #expect(mailbox.copyLatest(into: analyzer.samples, generation: 1, after: 0) == nil)
        mailbox.capture(pcm.audioBufferList, format: pcm.format.streamDescription.pointee,
            frames: 1024, generation: 1, hostTime: 10, mediaTime: 20 + 1024 / pcm.format.sampleRate)
        let result = try #require(mailbox.copyLatest(into: analyzer.samples, generation: 1, after: 0))
        #expect(try #require(result.mediaTime) >= 20)
    }

    @Test func tonesSelectTheirFrequencyBandsAtDifferentSampleRates() throws {
        for sampleRate in [44100.0, 48000.0, 96000.0] {
            for (band, bin) in [4, 20, 80, 320].enumerated() {
                let result = try spectrum(tone(bin: bin, sampleRate: sampleRate))
                #expect(abs(result[band] - 0.5 / sqrt(2)) < 0.002)
                for other in 0..<4 where other != band { #expect(result[other] < 0.001) }
            }
        }
    }

    @Test func stereoEnergyIncludesBothChannelsAndRetainsOppositePhase() throws {
        let rightOnly = try spectrum(tone(bin: 20, stereo: true))
        #expect(abs(rightOnly.y - 0.25) < 0.002)
        let opposite = try spectrum(tone(bin: 20, stereo: true, oppositePhase: true))
        #expect(abs(opposite.y - 0.5 / sqrt(2)) < 0.002)
    }

    @Test func partialWindowsAndGenerationChangesNeverPublishOldPCM() throws {
        let pcm = try tone(bin: 4)
        let mailbox = PlaybackPCMWindow()
        let analyzer = PlaybackSpectrumAnalyzer()
        let format = pcm.format.streamDescription.pointee
        mailbox.capture(pcm.audioBufferList, format: format, frames: 1024, generation: 1)
        #expect(mailbox.copyLatest(into: analyzer.samples, generation: 1, after: 0) == nil)
        mailbox.capture(pcm.audioBufferList, format: format, frames: 1024, generation: 1)
        let first = try #require(mailbox.copyLatest(into: analyzer.samples, generation: 1, after: 0))
        #expect(mailbox.copyLatest(into: analyzer.samples, generation: 1, after: first.revision) == nil)
        mailbox.capture(pcm.audioBufferList, format: format, frames: 1024, generation: 2)
        #expect(mailbox.copyLatest(into: analyzer.samples, generation: 2, after: first.revision) == nil)
        mailbox.capture(pcm.audioBufferList, format: format, frames: 1024, generation: 2)
        let second = try #require(mailbox.copyLatest(into: analyzer.samples, generation: 2, after: first.revision))
        #expect(second.revision != first.revision)
        #expect(mailbox.copyLatest(into: analyzer.samples, generation: 1, after: 0) == nil)
    }

    @Test func nativeFormatsAndInterleavedStereoRetainTheRightChannel() throws {
        for common in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32] {
            for interleaved in [false, true] {
                let format = try #require(AVAudioFormat(commonFormat: common, sampleRate: 48000,
                    channels: 2, interleaved: interleaved))
                let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048))
                pcm.frameLength = 2048
                let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
                var channelBase = 0
                for buffer in buffers {
                    let data = try #require(buffer.mData)
                    let channels = Int(buffer.mNumberChannels)
                    for frame in 0..<2048 {
                        for channel in 0..<channels {
                            let sample: Float = channelBase + channel == 1
                                ? 0.5 * sin(Float(frame * 20) * 2 * .pi / 2048) : 0
                            let index = frame * channels + channel
                            switch common {
                            case .pcmFormatFloat32: data.assumingMemoryBound(to: Float.self)[index] = sample
                            case .pcmFormatFloat64: data.assumingMemoryBound(to: Double.self)[index] = Double(sample)
                            case .pcmFormatInt16: data.assumingMemoryBound(to: Int16.self)[index] = Int16(sample * 32767)
                            case .pcmFormatInt32: data.assumingMemoryBound(to: Int32.self)[index] = Int32(Double(sample) * 2147483647)
                            default: break
                            }
                        }
                    }
                    channelBase += channels
                }
                let result = try spectrum(pcm)
                #expect(abs(result.y - 0.25) < 0.002)
                #expect(result.x < 0.001 && result.z < 0.001 && result.w < 0.001)
            }
        }
    }

    @Test func silenceAndNonfiniteInputStayQuiet() throws {
        let pcm = try tone(bin: 0)
        pcm.floatChannelData?[0][5] = .nan
        pcm.floatChannelData?[0][6] = .infinity
        let result = try spectrum(pcm)
        #expect(result == .zero)
        var normalizer = PlaybackSpectrumNormalizer()
        #expect(normalizer.targets(for: SIMD4(.nan, .infinity, -1, 0), elapsed: 0.03) == .zero)
    }

    @Test func envelopeUsesElapsedTimeAcrossFrameRates() {
        let oneStep = PlaybackSpectrumEnvelope.next(current: 1, target: 0, elapsed: 0.15)
        var smallSteps: Float = 1
        for _ in 0..<5 {
            smallSteps = PlaybackSpectrumEnvelope.next(current: smallSteps, target: 0, elapsed: 0.03)
        }
        #expect(abs(oneStep - smallSteps) < 0.00001)
        #expect(abs(oneStep - exp(-1)) < 0.00001)
        let attack = PlaybackSpectrumEnvelope.next(current: 0, target: 1, elapsed: 0.040)
        #expect(abs(attack - (1 - exp(-1))) < 0.00001)
    }
}

@Suite("Native file spectrum")
struct PlaybackFileSpectrumTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spectrum-\(UUID()).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        pcm.frameLength = 96000
        let data = try #require(pcm.floatChannelData)[0]
        for frame in 0..<96000 {
            let frequency: Float = frame < 48000 ? 468.75 : 7500
            data[frame] = 0.5 * sin(Float(frame) * 2 * .pi * frequency / 48000)
        }
        try file.write(from: pcm)
        return url
    }

    @Test func silentFileReaderUsesTheActualPlaybackPosition() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let owner = NSObject()
        let reader = PlaybackFileSpectrumAnalyzer()
        let first = try #require(await reader.energies(at: PlaybackSpectrumSource(url: url, position: 0.2,
            itemID: ObjectIdentifier(owner), generation: 1, seekSequence: 0)))
        #expect(first.bands.y > 0.3 && first.bands.w < 0.001)
        let afterSeek = try #require(await reader.energies(at: PlaybackSpectrumSource(url: url, position: 1.2,
            itemID: ObjectIdentifier(owner), generation: 1, seekSequence: 1)))
        #expect(afterSeek.bands.w > 0.3 && afterSeek.bands.y < 0.001)
        let atEnd = try #require(await reader.energies(at: PlaybackSpectrumSource(url: url, position: 2,
            itemID: ObjectIdentifier(owner), generation: 1, seekSequence: 1)))
        #expect(atEnd == .zero)
    }

    @Test func staleSeekTrackAndGenerationCannotPublish() {
        let owner = NSObject()
        let other = NSObject()
        let url = URL(fileURLWithPath: "/tmp/spectrum.wav")
        let original = PlaybackSpectrumSource(url: url, position: 1,
            itemID: ObjectIdentifier(owner), generation: 1, seekSequence: 0)
        #expect(original.isCurrent(comparedTo: PlaybackSpectrumSource(url: url, position: 1.1,
            itemID: ObjectIdentifier(owner), generation: 1, seekSequence: 0)))
        #expect(!original.isCurrent(comparedTo: PlaybackSpectrumSource(url: url, position: 1.1,
            itemID: ObjectIdentifier(owner), generation: 1, seekSequence: 1)))
        #expect(!original.isCurrent(comparedTo: PlaybackSpectrumSource(url: url, position: 1.1,
            itemID: ObjectIdentifier(owner), generation: 2, seekSequence: 0)))
        #expect(!original.isCurrent(comparedTo: PlaybackSpectrumSource(url: url, position: 1.1,
            itemID: ObjectIdentifier(other), generation: 1, seekSequence: 0)))
        #expect(!original.isCurrent(comparedTo: PlaybackSpectrumSource(url: url, position: 5,
            itemID: ObjectIdentifier(owner), generation: 1, seekSequence: 0)))
    }

    @Test func remoteSourcesAndInvalidPositionsDoNotOpenAFile() async {
        let reader = PlaybackFileSpectrumAnalyzer()
        let owner = NSObject()
        let remote = PlaybackSpectrumSource(url: URL(string: "https://example.invalid/audio.m3u8")!,
            position: 1, itemID: ObjectIdentifier(owner), generation: 1, seekSequence: 0)
        #expect(await reader.energies(at: remote) == nil)
        let invalid = PlaybackSpectrumSource(url: URL(fileURLWithPath: "/tmp/spectrum.wav"),
            position: .nan, itemID: ObjectIdentifier(owner), generation: 1, seekSequence: 0)
        #expect(await reader.energies(at: invalid) == nil)
    }
}

@Suite("Independent audio frequency bar motion")
struct PlaybackSpectrumMotionTests {
    @Test func steadySpectralTiltDoesNotProduceDescendingBars() {
        var normalizer = PlaybackSpectrumNormalizer()
        var targets = SIMD4<Float>.zero
        for _ in 0..<90 {
            targets = normalizer.targets(for: SIMD4(0.25, 0.08, 0.02, 0.006), elapsed: 1.0 / 30)
        }
        #expect(abs(targets.x - targets.w) < 0.001)
        #expect(targets.x > 0.45 && targets.x < 0.6)
    }

    @Test func quieterHighBandCanOvertakeLouderBassWhenItsEnergyRises() {
        var normalizer = PlaybackSpectrumNormalizer()
        var bars = SIMD4<Float>.zero
        func smooth(_ targets: SIMD4<Float>, bars: inout SIMD4<Float>) {
            for band in 0..<4 {
                bars[band] = PlaybackSpectrumEnvelope.next(current: bars[band],
                    target: targets[band], elapsed: 1.0 / 30)
            }
        }
        for _ in 0..<90 {
            smooth(normalizer.targets(for: SIMD4(0.25, 0.08, 0.02, 0.006),
                elapsed: 1.0 / 30), bars: &bars)
        }
        for _ in 0..<6 {
            smooth(normalizer.targets(for: SIMD4(0.18, 0.08, 0.02, 0.024),
                elapsed: 1.0 / 30), bars: &bars)
        }
        #expect(bars.w > bars.x + 0.3)
        for _ in 0..<6 {
            smooth(normalizer.targets(for: SIMD4(0.75, 0.08, 0.02, 0.003),
                elapsed: 1.0 / 30), bars: &bars)
        }
        #expect(bars.x > bars.w + 0.3)
    }

    @Test func eachBandCalibratesWithoutChangingAnotherBandsResponse() {
        var first = PlaybackSpectrumNormalizer()
        var second = PlaybackSpectrumNormalizer()
        let scaling = SIMD4<Float>(0.5, 2, 0.3, 3)
        for tick in 0..<120 {
            let pulse: Float = tick % 12 < 4 ? 1.6 : 0.7
            let input = SIMD4<Float>(0.25 * pulse, 0.08, 0.02 / pulse, 0.006 * pulse)
            let a = first.targets(for: input, elapsed: 1.0 / 30)
            let b = second.targets(for: input * scaling, elapsed: 1.0 / 30)
            for band in 0..<4 { #expect(abs(a[band] - b[band]) < 0.001) }
        }
    }

    @Test func silenceAndSubaudibleNoiseNeverGenerateMotion() {
        var normalizer = PlaybackSpectrumNormalizer()
        for _ in 0..<60 {
            #expect(normalizer.targets(for: SIMD4(0, 0.00001, -1, .nan), elapsed: 1.0 / 15) == .zero)
        }
        let audible = normalizer.targets(for: SIMD4(repeating: 0.01), elapsed: 1.0 / 15)
        #expect(audible.x > 0.5)
        #expect(normalizer.targets(for: .zero, elapsed: 1.0 / 15) == .zero)
    }

    @Test func lowPowerCadenceKeepsTheSameCalibrationOverTime() {
        var normal = PlaybackSpectrumNormalizer()
        var lowPower = PlaybackSpectrumNormalizer()
        let input = SIMD4<Float>(0.25, 0.08, 0.02, 0.006)
        var first = SIMD4<Float>.zero
        var second = SIMD4<Float>.zero
        for _ in 0..<60 { first = normal.targets(for: input, elapsed: 1.0 / 30) }
        for _ in 0..<30 { second = lowPower.targets(for: input, elapsed: 1.0 / 15) }
        for band in 0..<4 { #expect(abs(first[band] - second[band]) < 0.01) }
    }
}
