// Lyricify Backgrounds — Apple Music Inspired · iOS, modern iOS background.
// Ported from https://github.com/WXRIW/Lyricify-Backgrounds
// Reference commit: cbef8a667c02a01707c78c7e76dc67d65cf161ed
// Source: AppleMusicIosRendererView.cs / AppleMusicIosRenderer.cs / AppleMusicIosMesh.cs
// Copyright the Lyricify Backgrounds contributors. Licensed under Apache License 2.0.
// Swift/Metal port © 2026 Luma contributors. Changes: native iOS/Metal lifecycle, Luma PCM.
// See Luma/Resources/Licenses/Lyricify-Apache-2.0.txt and THIRD_PARTY_NOTICES.md.

import SwiftUI
import Metal
import MetalKit
import OSLog
import QuartzCore

/// Pure scene gates, kept outside the view so Low Power / Reduce Motion behavior is
/// reviewable and unit-testable.
nonisolated enum LyricifyScenePolicy {
    /// Low Power, serious heat and backgrounding freeze the rotation/Mesh clock only.
    static func motionEnabled(
        isPresented: Bool, animated: Bool, reduceMotion: Bool, budget: PerformanceBudget
    ) -> Bool {
        isPresented && animated && !reduceMotion && budget.allowsArtworkMotion
    }

    /// The pulse is driven by measured PCM, not by the ambient clock. It stays alive
    /// when rotation/Mesh are frozen; Reduce Motion remains an explicit opt-out.
    static func pulseEnabled(
        isPresented: Bool, animated: Bool, isPlaying: Bool, audioReaction: Float,
        reduceMotion: Bool, budget: PerformanceBudget
    ) -> Bool {
        isPresented && animated && isPlaying && audioReaction > 0 && !reduceMotion
            && budget.allowsBeatVisuals
    }
}

/// Replaces the previous AMLL four-sprite background with Lyricify's modern iOS
/// Apple Music Inspired material: three rotating artwork layers, the 77-tap
/// sigma-42.5 Gaussian, Lyricify's color treatment, and its pinch mesh.
struct AppleMusicLyricsBackground: View {
    let coverImage: PlatformImage?
    let fallbackColor: Color
    let isPlaying: Bool
    var animated = true
    var isPresented = true
    var audioReaction: Float = 0.30
    var flowSpeed = 1.0

    @Environment(\.playbackVisualsPresented) private var surfacePresented
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var governor = PerformanceGovernor.shared
    @State private var isVisible = false
    @State private var metalUnavailable = false
    @State private var waitingForArtwork = false

    private var presented: Bool { isVisible && surfacePresented && isPresented && scenePhase == .active }
    /// Lyricify rotates while the material is alive; playback only gates the bass pulse.
    private var motionEnabled: Bool {
        LyricifyScenePolicy.motionEnabled(isPresented: presented, animated: animated,
            reduceMotion: reduceMotion, budget: governor.budget)
    }
    private var pulseEnabled: Bool {
        LyricifyScenePolicy.pulseEnabled(isPresented: presented, animated: animated,
            isPlaying: isPlaying, audioReaction: audioReaction, reduceMotion: reduceMotion,
            budget: governor.budget)
    }
    private var framesPerSecond: Int {
        if governor.budget.isLowPowerMode || governor.budget.thermalPressure >= .fair {
            return 30
        }
        return 60
    }
    private var rotationScale: Float {
        Float(min(4, max(0, flowSpeed)))
    }

    var body: some View {
        ZStack {
            fallbackColor
            if !metalUnavailable {
                LyricifyMetalSurface(
                    image: coverImage,
                    clearArtwork: waitingForArtwork,
                    framesPerSecond: framesPerSecond,
                    renderEnabled: presented && !waitingForArtwork,
                    motionEnabled: motionEnabled,
                    pulseEnabled: pulseEnabled,
                    lightAppearance: colorScheme == .light,
                    rotationScale: rotationScale,
                    onUnavailable: { metalUnavailable = true }
                )
                .opacity(waitingForArtwork ? 0 : 1)
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
                // Keep the last artwork frame until the fallback delay expires.
                do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
                waitingForArtwork = true
            }
        }
        .onChange(of: governor.budget.isMemoryPressured) { _, pressured in
            if pressured { Task { await LyricifyArtworkTextureCache.shared.removeAll() } }
        }
    }
}

private struct LyricifyMetalSurface {
    let image: PlatformImage?
    let clearArtwork: Bool
    let framesPerSecond: Int
    let renderEnabled: Bool
    let motionEnabled: Bool
    let pulseEnabled: Bool
    let lightAppearance: Bool
    let rotationScale: Float
    let onUnavailable: () -> Void

    func makeCoordinator() -> LyricifySceneCoordinator {
        LyricifySceneCoordinator(onUnavailable: onUnavailable)
    }

    private func makeSurface(coordinator: LyricifySceneCoordinator) -> ArtworkMetalView {
        let view = ArtworkMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = false
        view.preferredFramesPerSecond = framesPerSecond
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        #else
        view.layer?.isOpaque = false
        #endif
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        coordinator.attach(view)
        return view
    }
}

#if os(iOS)
extension LyricifyMetalSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> ArtworkMetalView { makeSurface(coordinator: context.coordinator) }
    func updateUIView(_ view: ArtworkMetalView, context: Context) {
        context.coordinator.update(
            image: image, clearArtwork: clearArtwork, framesPerSecond: framesPerSecond, renderEnabled: renderEnabled,
            motionEnabled: motionEnabled, pulseEnabled: pulseEnabled,
            lightAppearance: lightAppearance, rotationScale: rotationScale)
    }
    static func dismantleUIView(_ view: ArtworkMetalView, coordinator: LyricifySceneCoordinator) {
        coordinator.stop()
    }
}
#else
extension LyricifyMetalSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> ArtworkMetalView { makeSurface(coordinator: context.coordinator) }
    func updateNSView(_ view: ArtworkMetalView, context: Context) {
        context.coordinator.update(
            image: image, clearArtwork: clearArtwork, framesPerSecond: framesPerSecond, renderEnabled: renderEnabled,
            motionEnabled: motionEnabled, pulseEnabled: pulseEnabled,
            lightAppearance: lightAppearance, rotationScale: rotationScale)
    }
    static func dismantleNSView(_ view: ArtworkMetalView, coordinator: LyricifySceneCoordinator) {
        coordinator.stop()
    }
}
#endif

/// The drawable is full resolution; the Lyricify blur already runs on a 4x
/// downsampled render target, so the compositor only upscales the final material.
private final class ArtworkMetalView: MTKView {
    var onResize: (() -> Void)?
    #if os(iOS)
    override func layoutSubviews() { super.layoutSubviews(); onResize?() }
    #else
    override func layout() { super.layout(); onResize?() }
    #endif
}

@MainActor
private final class LyricifySceneCoordinator: NSObject, MTKViewDelegate {
    private weak var view: ArtworkMetalView?
    private var gpu: LyricifyBackgroundGPU?
    private var setupTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var requestedImage: PlatformImage?
    private var submittedImageID: ObjectIdentifier?
    private var artworkGeneration: UInt64 = 0
    private var pendingArtwork: (generation: UInt64, texture: any MTLTexture)?
    private var renderEnabled = false
    private var motionEnabled = false
    private var pulseEnabled = false
    private var lightAppearance = false
    private var rotationScale: Float = 1
    private var framesPerSecond = 60
    private var listening = false
    private var clock = ArtworkSceneClock()
    private var smoothedPulse: Float = 0
    private var lastDrawTime: CFTimeInterval = 0
    private var renderStartTime: CFTimeInterval?
    private var lastPulseLogTime = -Double.infinity
    private let inFlight = DispatchSemaphore(value: 2)
    private let onUnavailable: () -> Void

    init(onUnavailable: @escaping () -> Void) {
        self.onUnavailable = onUnavailable
    }

    func attach(_ view: ArtworkMetalView) {
        self.view = view
        view.delegate = self
        view.onResize = { [weak self] in self?.resize() }
        guard let device = view.device else {
            Task { @MainActor [weak self] in self?.onUnavailable() }
            return
        }
        setupTask = Task { [weak self] in
            let gpu = await LyricifyRendererPreparation.shared.renderer(device: device)
            guard !Task.isCancelled, let self else { return }
            setupTask = nil
            guard let gpu else {
                onUnavailable()
                return
            }
            self.gpu = gpu
            prepareArtworkIfNeeded()
            updateTicker()
        }
    }

    func update(
        image: PlatformImage?,
        clearArtwork: Bool,
        framesPerSecond: Int,
        renderEnabled: Bool,
        motionEnabled: Bool,
        pulseEnabled: Bool,
        lightAppearance: Bool,
        rotationScale: Float
    ) {
        self.framesPerSecond = framesPerSecond
        view?.preferredFramesPerSecond = framesPerSecond
        let presentationChanged = self.renderEnabled != renderEnabled
            || self.lightAppearance != lightAppearance
        self.renderEnabled = renderEnabled
        self.motionEnabled = motionEnabled
        self.pulseEnabled = pulseEnabled
        self.lightAppearance = lightAppearance
        self.rotationScale = rotationScale
        clock.setRunning(renderEnabled && motionEnabled, now: CACurrentMediaTime())
        if !renderEnabled { smoothedPulse = 0 }
        if clearArtwork { gpu?.releaseArtwork() }
        let imageID = image.map(ObjectIdentifier.init)
        if imageID != submittedImageID {
            submittedImageID = imageID
            requestedImage = image
            artworkGeneration &+= 1
            pendingArtwork = nil
            artworkTask?.cancel()
            prepareArtworkIfNeeded()
        }
        updateTicker()
        if presentationChanged { requestStaticFrame() }
    }

    private func prepareArtworkIfNeeded() {
        guard let image = requestedImage, let gpu else { return }
        let generation = artworkGeneration
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            let prepared = await LyricifyArtworkTextureCache.shared.artwork(
                image: image, device: gpu.device)
            guard !Task.isCancelled, let self, self.artworkGeneration == generation else { return }
            self.artworkTask = nil
            guard let prepared else {
                self.onUnavailable()
                return
            }
            if self.renderEnabled && gpu.isTransitioning {
                // Let the current blend finish before applying the newest queued cover.
                self.pendingArtwork = (generation, prepared.texture)
            } else {
                self.installArtwork(prepared.texture)
            }
        }
    }

    private func installArtwork(_ texture: any MTLTexture) {
        gpu?.replaceArtwork(texture, crossfade: renderEnabled)
        updateTicker()
        requestStaticFrame()
    }

    private func updateTicker() {
        guard let view else { return }
        let visibleArtwork = renderEnabled && gpu?.hasArtwork == true
        setListening(visibleArtwork && pulseEnabled)
        view.isPaused = !visibleArtwork || !(motionEnabled || pulseEnabled
            || gpu?.isTransitioning == true || smoothedPulse > 0.002)
    }

    private func requestStaticFrame() {
        guard renderEnabled, gpu?.hasArtwork == true, let view, view.isPaused else { return }
        #if os(iOS)
        view.setNeedsDisplay()
        #else
        view.needsDisplay = true
        #endif
    }

    private func setListening(_ active: Bool) {
        guard active != listening else { return }
        listening = active
        if active { PlaybackBeatMeter.shared.retainUIListening(playbackPCMOnly: true) }
        else { PlaybackBeatMeter.shared.releaseUIListening(playbackPCMOnly: true) }
    }

    private func resize() {
        guard let view else { return }
        let scale: CGFloat
        #if os(iOS)
        scale = view.contentScaleFactor
        #else
        scale = view.window?.backingScaleFactor ?? 2
        #endif
        let size = CGSize(width: max(1, view.bounds.width * scale),
                          height: max(1, view.bounds.height * scale))
        if view.drawableSize != size { view.drawableSize = size }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { requestStaticFrame() }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(in: view) }
    }

    private func drawFrame(in view: MTKView) {
        guard renderEnabled, let gpu, gpu.hasArtwork,
              view.bounds.width > 0, view.bounds.height > 0 else { return }
        guard inFlight.wait(timeout: .now()) == .success else {
            requestStaticFrame()
            return
        }
        guard let drawable = view.currentDrawable else {
            inFlight.signal()
            return
        }
        let now = CACurrentMediaTime()
        let ambientElapsed = clock.sample(now: now)
        if renderStartTime == nil { renderStartTime = now }
        let wallElapsed = now - (renderStartTime ?? now)
        let delta = lastDrawTime > 0 ? min(0.1, max(0, now - lastDrawTime)) : 0
        lastDrawTime = now
        let target = pulseEnabled ? LyricifyBassAnalyzer.shared.pulsePower : 0
        if pulseEnabled && target > 0 {
            // The analyzer already applies Lyricify's attack/release smoothing.
            smoothedPulse = target
        } else if smoothedPulse > 0 {
            smoothedPulse *= Float(exp(-delta / 0.16))
            if smoothedPulse <= 0.002 { smoothedPulse = 0 }
        }
        guard let frame = gpu.render(
            size: view.bounds.size,
            elapsed: wallElapsed,
            motionTime: ambientElapsed,
            pulsePower: smoothedPulse,
            isLandscape: view.bounds.width > view.bounds.height,
            lightAppearance: lightAppearance,
            rotationScale: rotationScale,
            drawable: drawable) else {
            inFlight.signal()
            return
        }
        let gate = inFlight
        frame.commandBuffer.addCompletedHandler { _ in gate.signal() }
        frame.commandBuffer.commit()
        if !gpu.isTransitioning, let pendingArtwork {
            self.pendingArtwork = nil
            if pendingArtwork.generation == artworkGeneration { installArtwork(pendingArtwork.texture) }
        }
        updateTicker()
        if listening, now - lastPulseLogTime >= 3 {
            lastPulseLogTime = now
            Logger.ui.debug("[LYRICIFY] bass=\(self.smoothedPulse) rotation_scale=\(self.rotationScale) fps=\(self.framesPerSecond)")
        }
    }

    func stop() {
        setupTask?.cancel()
        setupTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        setListening(false)
        gpu?.releaseArtwork()
        gpu = nil
        pendingArtwork = nil
        view?.isPaused = true
        view?.delegate = nil
    }
}
