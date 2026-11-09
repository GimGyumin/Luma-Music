import Synchronization
import AVFoundation
import Accelerate
import QuartzCore

/// Fixed storage shared by render callbacks and the UI consumer. Neither side waits:
/// one atomic claim protects the whole snapshot, and contention drops a visual sample.
nonisolated final class PlaybackMeterMailbox: Sendable {
    private let busy = Atomic<Bool>(false)
    private let first = Atomic<UInt64>(0)
    private let second = Atomic<UInt64>(0)
    private let generation = Atomic<UInt64>(0)
    private let revision = Atomic<UInt64>(0)

    func publish(_ values: SIMD4<Float>, generation token: UInt64) {
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else { return }
        defer { busy.store(false, ordering: .releasing) }
        first.store(UInt64(values.x.bitPattern) | UInt64(values.y.bitPattern) << 32, ordering: .relaxed)
        second.store(UInt64(values.z.bitPattern) | UInt64(values.w.bitPattern) << 32, ordering: .relaxed)
        generation.store(token, ordering: .relaxed)
        revision.wrappingAdd(1, ordering: .relaxed)
    }

    func latest() -> (bands: SIMD4<Float>, generation: UInt64, revision: UInt64)? {
        // Claim before reading instead of relying on optimistic checks around relaxed
        // loads. The acquire/release pair keeps all lanes and the generation together.
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else { return nil }
        defer { busy.store(false, ordering: .releasing) }
        let currentRevision = revision.load(ordering: .relaxed)
        guard currentRevision != 0 else { return nil }
        let a = first.load(ordering: .relaxed), b = second.load(ordering: .relaxed)
        let token = generation.load(ordering: .relaxed)
        return (SIMD4(Float(bitPattern: UInt32(truncatingIfNeeded: a)), Float(bitPattern: UInt32(truncatingIfNeeded: a >> 32)),
                      Float(bitPattern: UInt32(truncatingIfNeeded: b)), Float(bitPattern: UInt32(truncatingIfNeeded: b >> 32))), token, currentRevision)
    }
}

// PCM is copied on the render thread. Windowing and FFT run on the consumer.

nonisolated final class PlaybackPCMWindow: @unchecked Sendable {
    static let count = 2048
    static let channels = 8
    private let busy = Atomic<Bool>(false)
    private let discontinuity = Atomic<Bool>(false)
    private var writing = UnsafeMutablePointer<Float>.allocate(capacity: count * channels)
    private static let capacity = 6
    private struct Stamp {
        let revision: UInt64
        let generation: UInt64
        let sampleRate: Double
        let channels: Int
        let receivedAt: Double
        let presentationTime: Double
        let mediaTime: Double?
    }
    private var windows = (0..<capacity).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: count * channels) }
    private var stamps = [Stamp?](repeating: nil, count: capacity)
    private var first = 0
    private var queued = 0
    private var nextMediaTime: Double?
    private var filled = 0
    private var sampleRate = 0.0
    private var channelCount = 0
    private var formatFlags: UInt32 = 0
    private var sampleBytes = 0
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    init() {
        writing.initialize(repeating: 0, count: Self.count * Self.channels)
        for window in windows { window.initialize(repeating: 0, count: Self.count * Self.channels) }
    }

    deinit { writing.deallocate(); for window in windows { window.deallocate() } }

    func capture(_ list: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription,
                 frames: Int, generation token: UInt64, hostTime: Double? = nil, mediaTime: Double? = nil) {
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else {
            discontinuity.store(true, ordering: .relaxed)
            return
        }
        defer { busy.store(false, ordering: .releasing) }
        let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bytes = Int(format.mBitsPerChannel / 8)
        guard frames > 0, format.mSampleRate.isFinite, format.mSampleRate > 0,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              (floating && (bytes == 4 || bytes == 8)) || (signed && (bytes == 2 || bytes == 4))
        else { filled = 0; return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var channels = 0
        var available = frames
        for buffer in buffers {
            guard buffer.mData != nil, buffer.mNumberChannels > 0 else { continue }
            channels += Int(buffer.mNumberChannels)
            available = min(available, Int(buffer.mDataByteSize) / (bytes * Int(buffer.mNumberChannels)))
        }
        channels = min(channels, Self.channels)
        guard channels > 0, available > 0 else { filled = 0; return }
        if discontinuity.exchange(false, ordering: .relaxed) || generation != token
            || sampleRate != format.mSampleRate || channelCount != channels
            || formatFlags != format.mFormatFlags || sampleBytes != bytes
            || (mediaTime != nil && nextMediaTime != nil && abs(mediaTime! - nextMediaTime!) > 2 / format.mSampleRate) {
            filled = 0
            queued = 0
            first = 0
        }
        generation = token
        sampleRate = format.mSampleRate
        channelCount = channels
        formatFlags = format.mFormatFlags
        sampleBytes = bytes
        // Bound work even if a native tap supplies a very large render quantum.
        nextMediaTime = mediaTime.map { $0 + Double(available) / sampleRate }
        let start = max(0, available - Self.count * 4)
        if start > 0 { filled = 0 }
        for frame in start..<available {
            var outputChannel = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let stride = Int(buffer.mNumberChannels)
                for channel in 0..<min(stride, channels - outputChannel) {
                    let index = frame * stride + channel
                    let value: Float
                    if floating {
                        value = bytes == 4 ? data.assumingMemoryBound(to: Float.self)[index]
                            : Float(data.assumingMemoryBound(to: Double.self)[index])
                    } else {
                        value = bytes == 2 ? Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
                            : Float(data.assumingMemoryBound(to: Int32.self)[index]) / 2147483648
                    }
                    writing[outputChannel * Self.count + filled] = value.isFinite ? value : 0
                    outputChannel += 1
                }
                if outputChannel == channels { break }
            }
            filled += 1
            if filled == Self.count {
                if queued == Self.capacity {
                    first = (first + 1) % Self.capacity
                    queued -= 1
                }
                let slot = (first + queued) % Self.capacity
                swap(&writing, &windows[slot])
                revision &+= 1
                let receivedAt = CACurrentMediaTime()
                let centerOffset = (Double(frame + 1) - Double(Self.count) / 2) / sampleRate
                stamps[slot] = Stamp(revision: revision, generation: token, sampleRate: sampleRate, channels: channels,
                    receivedAt: receivedAt, presentationTime: (hostTime ?? receivedAt) + centerOffset,
                    mediaTime: mediaTime.map { $0 + centerOffset })
                queued += 1
                filled = 0
            }
        }
    }

    func copyLatest(into destination: UnsafeMutablePointer<Float>, generation token: UInt64,
                    after consumed: UInt64, oldestFirst: Bool = false) -> (revision: UInt64, sampleRate: Double, channels: Int, receivedAt: Double, presentationTime: Double, mediaTime: Double?)? {
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else { return nil }
        defer { busy.store(false, ordering: .releasing) }
        guard queued > 0 else { return nil }
        let slot = oldestFirst ? first : (first + queued - 1) % Self.capacity
        guard let stamp = stamps[slot], stamp.revision != consumed, stamp.generation == token else { return nil }
        destination.update(from: windows[slot], count: stamp.channels * Self.count)
        if oldestFirst {
            first = (first + 1) % Self.capacity
            queued -= 1
        }
        return (stamp.revision, stamp.sampleRate, stamp.channels, stamp.receivedAt, stamp.presentationTime, stamp.mediaTime)
    }
}

nonisolated struct PlaybackSpectrum: Equatable, Sendable {
    var bands = SIMD4<Float>.zero
    var bassRMS: Float = 0
    var rms: Float = 0
    var peak: Float = 0
    var spectralFlux: Float = 0
    static let zero = Self()
}

/// Presentation timestamps always use the monotonic host clock. The native engine
/// supplies its audible item time; AudioStreaming supplies the mixer tap's AVAudioTime.
nonisolated struct PlaybackAnalysisClock: Sendable {
    var position: Double
    var hostTime: Double
    var itemID: ObjectIdentifier
    var generation: UInt64
    var seekSequence: UInt64
    var playing: Bool

    func hasSameTimeline(as other: Self) -> Bool {
        itemID == other.itemID && generation == other.generation && seekSequence == other.seekSequence
    }
}

/// Positive spectral change identifies attacks. Sustained volume does not generate pulses.
nonisolated struct PlaybackOnsetDetector {
    private var bassBaseline: Float = 0
    private var energyBaseline: Float = 0
    private var fluxMean: Float = 0
    private var fluxDeviation: Float = 0
    private var lastTime: Double?
    private var lastTrigger = -Double.infinity
    private(set) var strength: Float = 0

    mutating func update(_ sample: PlaybackSpectrum, at time: Double) -> Float {
        guard time.isFinite else { return 0 }
        if let lastTime, time <= lastTime { return 0 }
        let dt = min(0.2, max(0.001, time - (lastTime ?? (time - 0.03))))
        lastTime = time
        let flux = max(0, sample.spectralFlux)
        let threshold = max(0.06, fluxMean + 1.6 * fluxDeviation)
        let bassRise = max(0, sample.bassRMS - bassBaseline)
        let relativeBassRise = bassRise / max(0.008, bassBaseline)
        let audible = min(1, max(0, (sample.rms - 0.0008) / 0.012))
        let energyRise = max(0, sample.rms - energyBaseline) / max(0.008, energyBaseline)
        strength = 0
        if flux > threshold, audible > 0, time - lastTrigger >= 0.10,
           relativeBassRise > 0.12 || energyRise > 0.18 {
            strength = min(0.85, max(relativeBassRise * 0.40, flux * 0.65)) * audible
            lastTrigger = time
        }
        let adaptation = Float(1 - exp(-dt / 0.55))
        fluxDeviation += (abs(flux - fluxMean) - fluxDeviation) * adaptation
        fluxMean += (flux - fluxMean) * adaptation
        bassBaseline += (sample.bassRMS - bassBaseline) * Float(1 - exp(-dt / 0.18))
        energyBaseline += (sample.rms - energyBaseline) * Float(1 - exp(-dt / 0.65))
        return strength
    }
}

/// Bounded attack/return, sampled directly by Metal. There is no implicit animation
/// or continuous RMS term, and overlapping attacks replace the peak instead of adding it.
nonisolated struct PlaybackBassEnvelope {
    static let attack = 0.065
    static let release = 0.28
    private var timestamp: Double?
    private var start: Float = 0
    private var peak: Float = 0
    private(set) var target: Float = 0

    static func scale(bass: Float, reaction: Float) -> Float {
        1 + 0.010 * min(1, max(0, bass * reaction / 0.30))
    }

    mutating func trigger(strength: Float, at time: Double) {
        guard strength.isFinite, strength > 0, time.isFinite else { return }
        start = value(at: time)
        peak = min(0.85, max(start, strength))
        target = peak
        timestamp = time
    }

    func value(at time: Double) -> Float {
        guard let timestamp else { return 0 }
        let elapsed = time - timestamp
        guard elapsed >= 0 else { return start }
        if elapsed < Self.attack {
            let t = Float(elapsed / Self.attack)
            return start + (peak - start) * t * t * (3 - 2 * t)
        }
        let t = Float(min(1, (elapsed - Self.attack) / Self.release))
        return peak * (1 - t * t * (3 - 2 * t))
    }
}

/// Reusable FFT storage. Each channel is transformed separately so opposite-phase
/// stereo signals retain their energy. Call analyze only from the consumer.
nonisolated final class PlaybackSpectrumAnalyzer {
    let samples = UnsafeMutablePointer<Float>.allocate(capacity: PlaybackPCMWindow.count * PlaybackPCMWindow.channels)
    private let window = UnsafeMutablePointer<Float>.allocate(capacity: PlaybackPCMWindow.count)
    private let real = UnsafeMutablePointer<Float>.allocate(capacity: PlaybackPCMWindow.count)
    private let imaginary = UnsafeMutablePointer<Float>.allocate(capacity: PlaybackPCMWindow.count)
    private let setup: FFTSetup?
    private let logSize = vDSP_Length(11)
    private var previousMagnitudes = SIMD32<Float>.zero
    private var lastSampleRate = 0.0
    private var lastChannels = 0

    func reset() {
        previousMagnitudes = SIMD32<Float>.zero
        lastSampleRate = 0
        lastChannels = 0
    }

    init() {
        samples.initialize(repeating: 0, count: PlaybackPCMWindow.count * PlaybackPCMWindow.channels)
        real.initialize(repeating: 0, count: PlaybackPCMWindow.count)
        imaginary.initialize(repeating: 0, count: PlaybackPCMWindow.count)
        setup = vDSP_create_fftsetup(logSize, FFTRadix(kFFTRadix2))
        vDSP_hann_window(window, vDSP_Length(PlaybackPCMWindow.count), Int32(vDSP_HANN_DENORM))
    }
    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
        samples.deallocate(); window.deallocate(); real.deallocate(); imaginary.deallocate()
    }

    func analyze(sampleRate: Double, channels: Int) -> PlaybackSpectrum {
        guard let setup, sampleRate.isFinite, sampleRate > 0,
              (1...PlaybackPCMWindow.channels).contains(channels) else { return .zero }
        let size = PlaybackPCMWindow.count
        var energies = SIMD4<Float>.zero
        var bassPower: Float = 0
        var totalPower: Float = 0
        var peak: Float = 0
        var magnitudes = SIMD32<Float>.zero
        if lastSampleRate != sampleRate || lastChannels != channels { reset() }
        lastSampleRate = sampleRate
        lastChannels = channels
        for channel in 0..<channels {
            let input = samples.advanced(by: channel * size)
            var sum: Float = 0
            vDSP_svesq(input, 1, &sum, vDSP_Length(size))
            totalPower += sum
            var channelPeak: Float = 0
            vDSP_maxmgv(input, 1, &channelPeak, vDSP_Length(size))
            peak = max(peak, channelPeak)
            // A complex FFT of real-valued input avoids packed DC/Nyquist special cases.
            vDSP_vmul(input, 1, window, 1, real, 1, vDSP_Length(size))
            vDSP_vclr(imaginary, 1, vDSP_Length(size))
            var spectrum = DSPSplitComplex(realp: real, imagp: imaginary)
            vDSP_fft_zip(setup, &spectrum, 1, logSize, FFTDirection(FFT_FORWARD))
            for bin in 1..<(size / 2) {
                let frequency = Double(bin) * sampleRate / Double(size)
                guard frequency >= 20, frequency < 20000 else { continue }
                let band = frequency < 250 ? 0 : (frequency < 1000 ? 1 : (frequency < 4000 ? 2 : 3))
                let power = real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
                energies[band] += power
                let fluxBand = min(31, max(0, Int(log2(frequency / 20) * 3.2)))
                magnitudes[fluxBand] += power
                if frequency >= 50 && frequency <= 120 { bassPower += power }
            }
        }
        // Parseval normalization compensates the Hann window's mean-square gain.
        let scale = Float(2.0 / (Double(size * size * channels) * 0.375))
        for band in 0..<4 { energies[band] = sqrt(max(0, energies[band] * scale)) }
        var increase: Float = 0
        var reference: Float = 0
        for bin in magnitudes.indices {
            magnitudes[bin] = sqrt(max(0, magnitudes[bin] * scale))
            increase += max(0, magnitudes[bin] - previousMagnitudes[bin])
            reference += previousMagnitudes[bin]
        }
        previousMagnitudes = magnitudes
        return PlaybackSpectrum(bands: energies, bassRMS: sqrt(max(0, bassPower * scale)),
                                rms: sqrt(totalPower / Float(size * channels)), peak: peak,
                                spectralFlux: min(2, increase / max(0.01, reference)))
    }
}

nonisolated enum PlaybackSpectrumEnvelope {
    static func next(current: Float, target: Float, elapsed: Double) -> Float {
        let timeConstant = target > current ? 0.040 : 0.150
        let coefficient = Float(1 - exp(-max(0, elapsed) / timeConstant))
        return current + (target - current) * coefficient
    }

}

/// Tracks each band's own recent RMS, so fixed spectral balance does not determine
/// bar height. Targets follow measured changes, with a gate for near-silent input.
nonisolated struct PlaybackSpectrumNormalizer {
    private var reference = SIMD4<Float>.zero

    mutating func targets(for raw: SIMD4<Float>, elapsed: Double) -> SIMD4<Float> {
        let floor: Float = 0.0001
        let duration = elapsed.isFinite ? max(0, elapsed) : 0
        let adaptation = Float(1 - exp(-duration / 1.2))
        var targets = SIMD4<Float>.zero
        for band in 0..<4 {
            let rms = raw[band].isFinite ? max(0, raw[band]) : 0
            if reference[band] < floor {
                reference[band] = max(floor, rms * 0.65)
            }
            let relative = 0.5 + 0.4 * log2(max(floor, rms) / reference[band])
            let audibility = min(1, max(0, (rms - floor) / (4 * floor)))
            targets[band] = min(1, max(0, relative)) * audibility
            reference[band] += (max(floor, rms) - reference[band]) * adaptation
        }
        return targets
    }
}

nonisolated struct PlaybackSpectrumSource: Sendable {
    let url: URL
    let position: TimeInterval
    let itemID: ObjectIdentifier
    let generation: UInt64
    let seekSequence: UInt64

    func hasSameItem(as other: Self) -> Bool {
        url == other.url && itemID == other.itemID && generation == other.generation
    }

    func isCurrent(comparedTo other: Self) -> Bool {
        hasSameItem(as: other) && seekSequence == other.seekSequence && abs(position - other.position) < 0.35
    }
}

/// A separate, silent file reader for native gapless playback. All file opening,
/// seeking and FFT work stays on this actor, independently of the audible decoder.
actor PlaybackFileSpectrumAnalyzer {
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer?
    private var openedSource: PlaybackSpectrumSource?
    private var failedSource: PlaybackSpectrumSource?
    private let analyzer = PlaybackSpectrumAnalyzer()

    func energies(at source: PlaybackSpectrumSource) -> PlaybackSpectrum? {
        guard source.url.isFileURL, source.position.isFinite, source.position >= 0 else { return nil }
        if let failedSource, failedSource.hasSameItem(as: source),
           failedSource.seekSequence == source.seekSequence { return nil }
        do {
            if openedSource?.hasSameItem(as: source) != true || openedSource?.seekSequence != source.seekSequence {
                analyzer.reset()
            }
            if openedSource?.hasSameItem(as: source) != true {
                let opened = try AVAudioFile(forReading: source.url, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard let pcm = AVAudioPCMBuffer(pcmFormat: opened.processingFormat,
                    frameCapacity: AVAudioFrameCount(PlaybackPCMWindow.count)) else { return nil }
                file = opened
                buffer = pcm
                openedSource = source
            }
            guard let file, let buffer, file.processingFormat.sampleRate > 0 else { return nil }
            let rate = file.processingFormat.sampleRate
            let frame = min(Double(file.length), source.position * rate)
            guard frame.isFinite else { return nil }
            if frame >= Double(file.length) { return .zero }
            openedSource = source
            file.framePosition = AVAudioFramePosition(max(0, frame - Double(PlaybackPCMWindow.count) / 2))
            try file.read(into: buffer, frameCount: AVAudioFrameCount(PlaybackPCMWindow.count))
            guard let channels = buffer.floatChannelData else { return nil }
            let channelCount = min(Int(buffer.format.channelCount), PlaybackPCMWindow.channels)
            let frames = Int(buffer.frameLength)
            for channel in 0..<channelCount {
                let destination = analyzer.samples.advanced(by: channel * PlaybackPCMWindow.count)
                destination.update(from: channels[channel], count: frames)
                if frames < PlaybackPCMWindow.count {
                    destination.advanced(by: frames).update(repeating: 0, count: PlaybackPCMWindow.count - frames)
                }
            }
            return analyzer.analyze(sampleRate: rate, channels: channelCount)
        } catch {
            failedSource = source
            file = nil
            buffer = nil
            openedSource = nil
            return nil
        }
    }
}
