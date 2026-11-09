import SwiftUI
import Metal
import MetalKit
import OSLog
import QuartzCore

/// Artwork textures create the color field. This view never observes the audio meter or lyrics clock.
struct AppleMusicLyricsBackground: View {
    let coverImage: PlatformImage?
    let fallbackColor: Color
    let isPlaying: Bool
    var animated = true
    var isPresented = true
    var audioReaction: Float = 0.30
    var flowSpeed = AMLLArtworkMotion.defaultFlowSpeed

    @Environment(\.playbackVisualsPresented) private var surfacePresented
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var governor = PerformanceGovernor.shared
    @State private var isVisible = false
    @State private var metalUnavailable = false
    @State private var waitingForArtwork = false

    private var presented: Bool { isVisible && surfacePresented && isPresented && scenePhase == .active }
    private var motionEnabled: Bool { isPlaying && animated && !reduceMotion && governor.budget.allowsArtworkMotion }

    private var pulseEnabled: Bool { motionEnabled && audioReaction > 0 }

    var body: some View {
        ZStack {
            fallbackColor
            if metalUnavailable || waitingForArtwork {
                LyricsFallbackSurface(image: coverImage, tint: fallbackColor,
                    moving: presented && motionEnabled, pulsing: presented && pulseEnabled,
                    framesPerSecond: governor.budget.artworkFramesPerSecond,
                    speed: flowSpeed, reaction: audioReaction)
            } else {
                LyricsMetalSurface(
                    image: coverImage,
                    framesPerSecond: governor.budget.artworkFramesPerSecond,
                    renderEnabled: presented,
                    motionEnabled: motionEnabled,
                    transitionEnabled: animated && !reduceMotion && governor.budget.allowsDecorativeMotion && !governor.budget.isMemoryPressured,
                    flowSpeed: flowSpeed,
                    audioReaction: pulseEnabled ? audioReaction : 0,
                    onUnavailable: { metalUnavailable = true }
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: coverImage.map(ObjectIdentifier.init)) {
            if coverImage != nil {
                waitingForArtwork = false
                metalUnavailable = false
            } else {
                // Keep the previous frame while the next cover loads, then reveal the fallback.
                do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
                waitingForArtwork = true
            }
        }
        #if DEBUG
        .task(id: "\(isVisible)|\(scenePhase == .active)|\(animated)|\(isPlaying)|\(presented)|\(pulseEnabled)|\(metalUnavailable)|\(waitingForArtwork)") {
            guard presented, animated, isPlaying,
                  LyricsPulseProbe.enabled else { return }
            let meter = PlaybackBeatMeter.shared
            // Record just this surface's inputs. The developer build can be diagnosed on a
            // paired phone without exporting system logs or storing song or account information.
            while !Task.isCancelled {
                let mode = metalUnavailable || waitingForArtwork ? "fallback" : "metal"
                let frame = LyricsPulseProbe.shared.take()
                let value = "mode=\(mode) presented=\(presented) animated=\(animated) playing=\(isPlaying) enabled=\(pulseEnabled) reduce=\(reduceMotion) budget=\(governor.budget.summary) input=\(meter.input.rawValue) valid=\(meter.hasValidAnalysis) rms=\(meter.spectrum.rms) bass=\(meter.spectrum.bassRMS) target=\(meter.targetBass) frames=\(frame.count) min_scale=\(frame.low) max_scale=\(frame.high)"
                await LyricsPulseProbe.write(value)
                guard !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
            }
        }
        #endif
        .onChange(of: governor.budget.isMemoryPressured) { _, pressured in
            if pressured { Task { await ArtworkSceneTextureCache.shared.removeCachedArtwork() } }
        }
    }
}

#if DEBUG
@MainActor
private final class LyricsPulseProbe {
    static let shared = LyricsPulseProbe()
    static let enabled = ProcessInfo.processInfo.arguments.contains("-LumaLyricsPulseProbe")
    private var count = 0
    private var low: Float = 2
    private var high: Float = 1
    func sample(_ scale: Float) {
        count += 1
        low = min(low, scale)
        high = max(high, scale)
    }
    func take() -> (count: Int, low: Float, high: Float) {
        defer { count = 0; low = 2; high = 1 }
        return (count, count == 0 ? 1 : low, high)
    }
    @concurrent static func write(_ value: String) async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("luma-lyrics-pulse.txt")
        try? Data(value.utf8).write(to: file, options: .atomic)
    }
}
#endif

/// Keep the cover stationary beneath a slowly drifting light field when Metal or artwork is unavailable.
private struct LyricsFallbackSurface: View {
    let image: PlatformImage?
    let tint: Color
    let moving: Bool
    let pulsing: Bool
    let framesPerSecond: Int
    let speed: Double
    let reaction: Float
    @State private var clock = ArtworkSceneClock()
    @State private var listening = false

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1 / Double(framesPerSecond), paused: !moving && !pulsing)) { _ in
                var snapshot = clock
                let t = snapshot.sample(now: CACurrentMediaTime())
                let bass = pulsing ? PlaybackBeatMeter.shared.backgroundBass : 0
                let scale = CGFloat(PlaybackBassEnvelope.scale(bass: bass, reaction: reaction))
                let pulse = (scale - 1) / 0.010
                let center = UnitPoint(x: 0.5 + 0.12 * sin(t * 0.08), y: 0.48 + 0.10 * cos(t * 0.06))
                let side = max(geometry.size.width, geometry.size.height)
                ZStack {
                    tint
                    if let image {
                        Image(platformImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .scaleEffect(1.3).blur(radius: 60, opaque: true)
                    }
                    RadialGradient(colors: [tint.opacity(0.12 + 0.025 * pulse), .clear, .black.opacity(0.30)],
                        center: center, startRadius: 0, endRadius: side * (0.65 + 0.045 * pulse))
                    LinearGradient(stops: [.init(color: .clear, location: 0.4),
                                           .init(color: .black.opacity(0.28), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .clipped()
        }
        .onChange(of: moving, initial: true) { _, active in
            clock.setRunning(active, now: CACurrentMediaTime())
        }
        .onChange(of: pulsing, initial: true) { _, active in setListening(active) }
        .onChange(of: speed, initial: true) { _, value in clock.setSpeed(value, now: CACurrentMediaTime()) }
        .onDisappear { setListening(false) }
    }

    private func setListening(_ active: Bool) {
        guard active != listening else { return }
        listening = active
        if active { PlaybackBeatMeter.shared.retainUIListening() }
        else { PlaybackBeatMeter.shared.releaseUIListening() }
    }
}

private struct LyricsMetalSurface {
    let image: PlatformImage?
    let framesPerSecond: Int
    let renderEnabled: Bool
    let motionEnabled: Bool
    let transitionEnabled: Bool
    let flowSpeed: Double
    let audioReaction: Float
    let onUnavailable: () -> Void

    func makeCoordinator() -> LyricsSceneCoordinator { LyricsSceneCoordinator(onUnavailable: onUnavailable) }
    private func makeSurface(coordinator: LyricsSceneCoordinator) -> ArtworkMetalView {
        let view = ArtworkMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.preferredFramesPerSecond = framesPerSecond
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        #else
        view.layer?.isOpaque = false
        #endif
        #if os(iOS)
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        #else
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        #endif
        coordinator.attach(view)
        return view
    }
}

#if os(iOS)
extension LyricsMetalSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> ArtworkMetalView { makeSurface(coordinator: context.coordinator) }
    func updateUIView(_ view: ArtworkMetalView, context: Context) {
        view.preferredFramesPerSecond = framesPerSecond
        context.coordinator.update(image: image, renderEnabled: renderEnabled, motionEnabled: motionEnabled, transitionEnabled: transitionEnabled, flowSpeed: flowSpeed, audioReaction: audioReaction)
    }
    static func dismantleUIView(_ view: ArtworkMetalView, coordinator: LyricsSceneCoordinator) { coordinator.stop() }
}
#else
extension LyricsMetalSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> ArtworkMetalView { makeSurface(coordinator: context.coordinator) }
    func updateNSView(_ view: ArtworkMetalView, context: Context) {
        view.preferredFramesPerSecond = framesPerSecond
        context.coordinator.update(image: image, renderEnabled: renderEnabled, motionEnabled: motionEnabled, transitionEnabled: transitionEnabled, flowSpeed: flowSpeed, audioReaction: audioReaction)
    }
    static func dismantleNSView(_ view: ArtworkMetalView, coordinator: LyricsSceneCoordinator) { coordinator.stop() }
}
#endif

/// The drawable itself is low resolution; only the background is upscaled by the compositor.
private final class ArtworkMetalView: MTKView {
    var onResize: (() -> Void)?
    #if os(iOS)
    override func layoutSubviews() { super.layoutSubviews(); onResize?() }
    #else
    override func layout() { super.layout(); onResize?() }
    #endif
}

@MainActor
private final class LyricsSceneCoordinator: NSObject, MTKViewDelegate {
    private weak var view: ArtworkMetalView?
    private var gpu: LyricsArtworkGPU?
    private var setupTask: Task<Void, Never>?
    private var renderWatchdog: Task<Void, Never>?
    private var lastSubmittedFrame: TimeInterval = 0
    private var reportedUnavailable = false
    private var artworkTask: Task<Void, Never>?
    private var requestedImage: PlatformImage?
    private var submittedImageID: ObjectIdentifier?
    private var renderEnabled = false
    private var motionEnabled = false
    private var audioReaction: Float = 0
    private var hasTexture = false
    private var lastPulseLogTime = -Double.infinity
    private var lastPresentedTrigger: Double?
    private var listening = false
    private var clock = ArtworkSceneClock()
    private var fadeClock = ArtworkSceneClock()
    private var transitionEnabled = false
    private var transitionStartedAt: TimeInterval?
    private let inFlight = DispatchSemaphore(value: 2)
    private let onUnavailable: () -> Void

    init(onUnavailable: @escaping () -> Void) { self.onUnavailable = onUnavailable }

    func attach(_ view: ArtworkMetalView) {
        self.view = view
        view.delegate = self
        view.onResize = { [weak self] in self?.resize() }
        guard let device = view.device else {
            Task { @MainActor [weak self] in self?.onUnavailable() }
            return
        }
        setupTask = Task { [weak self] in
            let gpu = await ArtworkRendererPreparation.shared.renderer(device: device)
            guard !Task.isCancelled, let self else { return }
            setupTask = nil
            guard let gpu else { onUnavailable(); return }
            self.gpu = gpu
            resize()
            submitArtworkIfNeeded()
        }
    }

    func update(image: PlatformImage?, renderEnabled: Bool, motionEnabled: Bool, transitionEnabled: Bool, flowSpeed: Double, audioReaction: Float) {
        let wasEnabled = self.renderEnabled
        let wasMoving = self.motionEnabled
        let wasPulsing = self.audioReaction > 0
        self.renderEnabled = renderEnabled
        self.motionEnabled = renderEnabled && motionEnabled
        self.audioReaction = min(1, max(0, audioReaction))
        self.transitionEnabled = transitionEnabled
        if image == nil {
            artworkTask?.cancel()
            artworkTask = nil
            submittedImageID = nil
        }
        requestedImage = image
        let now = CACurrentMediaTime()
        // Integrate the rate instead of multiplying all elapsed time by a new
        // speed, which teleports the background when the flow setting changes.
        clock.setSpeed(AMLLArtworkMotion.speed(flowSpeed), now: now)
        clock.setRunning(self.motionEnabled, now: now)
        fadeClock.setRunning(renderEnabled && transitionEnabled, now: now)
        let finishingTransition = !transitionEnabled && transitionStartedAt != nil
        if finishingTransition { transitionStartedAt = nil }
        updateTicker()
        if !renderEnabled {
            if artworkTask != nil { submittedImageID = nil }
            artworkTask?.cancel()
            artworkTask = nil
            return
        }
        submitArtworkIfNeeded()
        if !self.motionEnabled && (wasMoving || (wasPulsing && self.audioReaction == 0) || !wasEnabled || finishingTransition) {
            view?.draw()
        }
    }

    private func checkRendering(_ expected: Bool) {
        guard expected, !reportedUnavailable else {
            renderWatchdog?.cancel()
            renderWatchdog = nil
            return
        }
        guard renderWatchdog == nil else { return }
        lastSubmittedFrame = CACurrentMediaTime()
        renderWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if CACurrentMediaTime() - self.lastSubmittedFrame > 1.5 {
                    self.reportedUnavailable = true
                    self.view?.isPaused = true
                    self.setListening(false)
                    self.onUnavailable()
                    return
                }
            }
        }
    }

    private func updateTicker() {
        let canDraw = renderEnabled && hasTexture && requestedImage != nil
        setListening(canDraw && audioReaction > 0)
        let running = canDraw && (motionEnabled || listening || (transitionEnabled && transitionStartedAt != nil))
        view?.isPaused = !running
        checkRendering(renderEnabled && (motionEnabled || audioReaction > 0) && requestedImage != nil)
    }

    private func setListening(_ active: Bool) {
        guard active != listening else { return }
        listening = active
        if active { PlaybackBeatMeter.shared.retainUIListening() }
        else { PlaybackBeatMeter.shared.releaseUIListening() }
    }

    private func submitArtworkIfNeeded() {
        guard renderEnabled, let gpu, let image = requestedImage else { return }
        let id = ObjectIdentifier(image)
        guard id != submittedImageID else { return }
        submittedImageID = id
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            let prepared = await ArtworkSceneTextureCache.shared.artwork(image: image, device: gpu.device)
            guard !Task.isCancelled, let self, renderEnabled, submittedImageID == id else { return }
            artworkTask = nil
            guard let prepared else { submittedImageID = nil; onUnavailable(); return }
            let crossfade = gpu.replaceArtwork(prepared.texture, profile: prepared.profile, crossfade: transitionEnabled)
            hasTexture = true
            transitionStartedAt = crossfade ? fadeClock.sample(now: CACurrentMediaTime()) : nil
            updateTicker()
            view?.draw()
        }
    }

    private func resize() {
        guard let view else { return }
        let size = ArtworkSceneMotion.renderSize(for: view.bounds.size)
        let drawableSize = CGSize(width: size.width, height: size.height)
        if view.drawableSize != drawableSize { view.drawableSize = drawableSize }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated {
            if renderEnabled, !motionEnabled { view.draw() }
        }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(in: view) }
    }

    private func drawFrame(in view: MTKView) {
        guard renderEnabled, !reportedUnavailable, let gpu, view.bounds.width > 0, view.bounds.height > 0,
              inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = view.currentDrawable else { inFlight.signal(); return }
        let now = CACurrentMediaTime()
        let time = clock.sample(now: now)
        let progress = transitionStartedAt.map { ArtworkSceneMotion.crossfadeProgress(elapsed: fadeClock.sample(now: now) - $0) } ?? 1
        let bass = listening ? PlaybackBeatMeter.shared.pulse(at: now) : 0
        let scale = PlaybackBassEnvelope.scale(bass: bass, reaction: audioReaction)
        guard let frame = gpu.render(size: view.bounds.size, elapsed: Float(time), transition: progress,
                                     flowSpeed: 1, pulseScale: scale, drawable: drawable) else {
            inFlight.signal()
            return
        }
        if transitionStartedAt != nil, progress >= 1 {
            transitionStartedAt = nil
            updateTicker()
        }
        let gate = inFlight
        frame.commandBuffer.addCompletedHandler { _ in gate.signal() }
        #if !targetEnvironment(simulator)
        if PlaybackBeatMeter.diagnosticsEnabled,
           let trigger = PlaybackBeatMeter.shared.triggerHostTime, trigger != lastPresentedTrigger,
           let metalDrawable = drawable as? any MTLDrawable {
            lastPresentedTrigger = trigger
            metalDrawable.addPresentedHandler { drawable in
                let presented = drawable.presentedTime
                Task { @MainActor in PlaybackBeatMeter.shared.recordPresentation(trigger: trigger, at: presented) }
            }
        }
        #endif
        frame.commandBuffer.commit()
        lastSubmittedFrame = now
        #if DEBUG
        if listening, LyricsPulseProbe.enabled { LyricsPulseProbe.shared.sample(scale) }
        #endif
        if listening, now - lastPulseLogTime >= 3 {
            lastPulseLogTime = now
            let target = PlaybackBassEnvelope.scale(bass: PlaybackBeatMeter.shared.targetBass, reaction: audioReaction)
            Logger.ui.debug("[VISUALIZER] pulse_target_scale=\(target) pulse_actual_scale=\(scale) flow_active=\(self.motionEnabled)")
        }
    }

    func stop() {
        renderWatchdog?.cancel()
        renderWatchdog = nil
        setListening(false)
        view?.isPaused = true
        view?.delegate = nil
        view?.onResize = nil
        setupTask?.cancel()
        artworkTask?.cancel()
        setupTask = nil
        artworkTask = nil
        gpu = nil
        requestedImage = nil
    }

}
