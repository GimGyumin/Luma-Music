// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Combine
import AppIntents
import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

#if canImport(UIKit)
import AVKit
import AVFoundation
#endif

enum PlayerSurface { case player, lyrics, queue }

/// 9:11 ≈ 4.5:5.5 split for wide Now Playing when a side panel is open.
private extension View {
    @ViewBuilder
    func morphCover(_ enabled: Bool, in namespace: Namespace.ID, isSource: Bool) -> some View {
        if enabled {
            matchedGeometryEffect(id: "cover", in: namespace, isSource: isSource)
        } else {
            self
        }
    }

    @ViewBuilder
    func lumaDesktopPlayerFooter<Footer: View>(
        enabled: Bool,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        if enabled {
            safeAreaInset(edge: .bottom, spacing: 0, content: footer)
        } else {
            self
        }
    }
}

private struct PlayerThemeKey: Equatable {
    let coverId: String?
    let override: Color?
    let isActive: Bool
    let serverID: UUID?
    let uploadVersion: Int
    let artworkRevision: UInt64
    let allowsArtworkNetwork: Bool
}

struct FullPlayerView: View {
    @Environment(\.appContainer) private var container
    @Environment(DominantColorExtractor.self) private var colorExtractor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("luma.visuals.animatedArtwork") private var animatedArtwork = true
    /// The same "Immersive Album Artwork" preference that extends album pages.
    /// When enabled, the compact iPhone player uses an artwork-led layout.
    @AppStorage("luma.visuals.immersiveAlbums") private var immersiveArtwork = true

    var onClose: (() -> Void)? = nil
    var openWithLyrics: Bool = false
    var openWithQueue: Bool = false
    /// Siri can request the translation or pronunciation layer; normal internal
    /// navigation leaves this at `.lyrics`.
    var openWithLyricsMode: LumaLyricsViewMode = .lyrics

    @State private var fallbackViewModel = FullPlayerViewModel()
    private var vm: FullPlayerViewModel { container?.fullPlayerViewModel ?? fallbackViewModel }
    @AppStorage("coverArtUploadVersion") private var coverArtUploadVersion = 0
    /// Local high-quality artwork resolved across the track/album/download candidates.
    @State private var resolvedArtworkID: String?
    @State private var resolvedArtworkImage: PlatformImage?
    @State private var resolvedArtworkTrackID: String?
    /// Lower-centre colour reported by the same backdrop that paints the player.
    @State private var backdropTint: Color?
    /// Device automation can open the player directly on a surface. Normal launches
    /// never set this variable; `NativeSearchLifecycle` uses the same pattern for URLs.
    @State private var surface: PlayerSurface = FullPlayerView.initialSurface
    private static var initialSurface: PlayerSurface {
        ProcessInfo.processInfo.environment["LUMA_TEST_PLAYER_SURFACE"] == "lyrics" ? .lyrics : .player
    }
    private var showLyrics: Bool { surface == .lyrics }
    @State private var lyricsViewModel: LyricsViewModel?
    @State private var appliedLyricsMode = false
    @State private var pendingLyricsMode: LumaLyricsViewMode?
    @State private var lyricsVisibilityOwner = UUID()
    @State private var atmosphereReady = false
    @State private var isRotating = false
    @State private var openTrace: PerformanceTrace?
    @State private var isLandscapeViewport = false
    @State private var atmosphereTask: Task<Void, Never>?
    @Namespace private var morphNS

    #if os(iOS)
    /// Playing artwork nearly fills the phone width, matching the system Music player.
    private static let playerCoverHPaddingCompact: CGFloat = LumaSpacing.xxl
    private static let playerCoverHPaddingRegular: CGFloat = 96
    /// Paused artwork keeps its layout slot and contracts around its center. Keeping the
    /// slot stable prevents the title, scrubber, and transport controls from jumping.
    private static let playerCoverPausedScale = PlayerArtworkPlaybackModifier.pausedScale
    private static let playerCoverToTitleGap: CGFloat = LumaSpacing.xl
    private static let playerControlsSpacing: CGFloat = LumaSpacing.l
    /// Align the compact player's lower chrome with the vertical rhythm of Music.app.
    private static let playerChromeYOffset: CGFloat = 12
    @State private var playerTopInset: CGFloat = 36
    @State private var playerViewportHeight: CGFloat = 844
    private var surfaceHeaderTopInset: CGFloat {
        max(playerTopInset - 41, 9)
    }

    private var playerCoverHPadding: CGFloat {
        horizontalSizeClass == .regular ? Self.playerCoverHPaddingRegular : Self.playerCoverHPaddingCompact
    }
    #endif

    private var usesDesktopDetail: Bool {
        LumaWideLayout.usesDesktopDetail(horizontalSizeClass: horizontalSizeClass)
    }

    private var usesPhoneLandscape: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact
        #else
        false
        #endif
    }

    private var usesWidePlayerLayout: Bool {
        LumaWideLayout.usesWidePlayerLayout(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
    }

    private var usesReferencePortraitLayout: Bool {
        #if os(iOS)
        !usesWidePlayerLayout && !usesPhoneLandscape && !dynamicTypeSize.isAccessibilitySize
        #else
        false
        #endif
    }

    private var usesImmersivePortraitLayout: Bool { usesReferencePortraitLayout && immersiveArtwork }

    /// Release player backdrop: the sharp sleeve and its edge extensions own the
    /// lyrics-off surface. Lyrics/queue continue to use the animated Lyricify material.
    private var showsImmersivePlayer: Bool { usesImmersivePortraitLayout && surface == .player }

    private func resolvedPlayerCoverId(_ playerState: PlayerState) -> String? {
        if playerState.isLiveStream { return playerState.currentRadio?.coverArt }
        if playerState.currentTrack?.id == resolvedArtworkTrackID, let resolvedArtworkID {
            return resolvedArtworkID
        }
        // Fallback until the local high-quality candidates resolve: the playback
        // cover (prepared album cover when the index knows it), then the song's
        // effective cover. The resolved id above wins once a downloaded original
        // or local hero is available.
        return container?.playbackCoverId(for: playerState.currentTrack)
            ?? playerState.currentTrack?.effectiveCoverArtId
    }

    private func playerCoverImage(for coverID: String) -> PlatformImage? {
        if coverID == resolvedArtworkID, let resolvedArtworkImage {
            return resolvedArtworkImage
        }
        if vm.themeColor(for: coverID, serverID: container?.serverState.activeServer?.id) != nil,
           let image = vm.coverImage(for: coverID) { return image }
        return container?.artworkImageCache.cachedImage(for: coverID, tier: .hero)
            ?? container?.artworkImageCache.cachedImage(for: coverID, tier: .thumb)
    }

    var body: some View {
        if let playerState = container?.playerState {
            let themeCoverId = resolvedPlayerCoverId(playerState)
            let themeKey = PlayerThemeKey(
                coverId: themeCoverId,
                override: colorExtractor.colorOverride(for: themeCoverId ?? ""),
                isActive: scenePhase == .active,
                serverID: container?.serverState.activeServer?.id,
                uploadVersion: coverArtUploadVersion,
                artworkRevision: vm.artworkRevision,
                allowsArtworkNetwork: container?.artworkImageCache.allowsNetworkDownloads == true
            )
            content(playerState)
                .onGeometryChange(for: Bool.self) { geometry in
                    geometry.size.width > geometry.size.height
                } action: { isLandscapeViewport = $0 }
                #if os(iOS)
                .background {
                    PlayerRotationObserver { rotating in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { isRotating = rotating }
                    }
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                }
                #endif
                // Rotation geometry snaps to the new viewport, while leaf animations
                // (notably play/pause artwork scaling) retain their own transactions.
                .animation(nil, value: isRotating)
                .appEntityIdentifier(nowPlayingEntityIdentifier(playerState))
                .onReceive(NotificationCenter.default.publisher(for: .lumaOpenFullPlayerLyrics)) { note in
                    withAnimation(LumaAnimation.surface) { surface = .lyrics }
                    guard let raw = note.userInfo?["mode"] as? String,
                          let mode = LumaLyricsViewMode(rawValue: raw) else { return }
                    if let lyricsVM = lyricsViewModel {
                        Task { await applyLyricsMode(mode, to: lyricsVM) }
                    } else {
                        pendingLyricsMode = mode
                    }
                }
                .task(id: themeKey) {
                    guard scenePhase == .active else { return }
                    for attempt in 0..<3 {
                        if attempt > 0 {
                            do { try await Task.sleep(for: .seconds(attempt * 2)) } catch { return }
                        }
                        guard !Task.isCancelled else { return }
                        await vm.updateColors(
                            for: themeCoverId, colorExtractor: colorExtractor,
                            container: container, uploadVersion: coverArtUploadVersion
                        )
                        guard let themeCoverId, vm.coverImage(for: themeCoverId) == nil else { return }
                    }
                }
                .task(id: playerState.currentTrack?.id) {
                    captureLyricsPresentation()
                    lyricsViewModel?.setVisible(false, owner: lyricsVisibilityOwner)
                    guard let track = playerState.currentTrack,
                          let serverId = container?.serverState.activeServer?.id,
                          let lyricsService = container?.lyricsService,
                          let playerService = container?.playerService else {
                        lyricsViewModel = nil
                        return
                    }
                    let newVM = LyricsViewModel(
                        songId: track.id,
                        serverId: serverId,
                        lyricsService: lyricsService,
                        playerService: playerService,
                        playerState: playerState,
                        match: LyricsMatchInfo(song: track)
                    )
                    lyricsViewModel = newVM
                    newVM.setScenePhase(scenePhase)
                    newVM.setVisible(showLyrics, owner: lyricsVisibilityOwner)
                    if showLyrics { showLyricsChrome() }
                    // Lyrics are optional for the first frame and were competing with
                    // the decoder/network on cold restore. If the user explicitly
                    // opened lyrics, load immediately; otherwise let first audio win.
                    if !showLyrics {
                        await PlaybackStartupGate.waitForFirstAudio(playerState)
                    }
                    guard !Task.isCancelled else { return }
                    await newVM.load()
                    guard !Task.isCancelled, lyricsViewModel === newVM,
                          playerState.currentTrack?.id == track.id else { return }
                    restoreLyricsPresentation(to: newVM)
                    if let pendingLyricsMode {
                        self.pendingLyricsMode = nil
                        await applyLyricsMode(pendingLyricsMode, to: newVM)
                    } else if openWithLyrics, !appliedLyricsMode {
                        appliedLyricsMode = true
                        await applyLyricsMode(openWithLyricsMode, to: newVM)
                    }
                    if newVM.shouldAutoDismissLyrics {
                        withAnimation(LumaAnimation.surface) { surface = .player }
                    } else if showLyrics {
                        newVM.reconcileTracking()
                    }
                }
                .task(id: "\(playerState.currentTrack?.id ?? "none")-\(coverArtUploadVersion)-\(vm.artworkRevision)") {
                    let track = playerState.currentTrack
                    let trackID = track?.id
                    if resolvedArtworkTrackID != trackID {
                        resolvedArtworkTrackID = nil
                        resolvedArtworkID = nil
                        resolvedArtworkImage = nil
                    }
                    guard let track,
                          let local = await container?.localPlaybackArtwork(for: track),
                          !Task.isCancelled,
                          playerState.currentTrack?.id == track.id else { return }
                    resolvedArtworkTrackID = track.id
                    resolvedArtworkID = local.id
                    resolvedArtworkImage = local.image
                }
                .onChange(of: scenePhase) { _, phase in
                    lyricsViewModel?.setScenePhase(phase)
                    if phase == .active { showLyricsChrome() }
                }
                .onChange(of: playerState.playbackState) { _, state in
                    lyricsViewModel?.reconcileTracking()
                    #if os(iOS)
                    MusicHapticsController.shared.setPlaying(state == .playing)
                    #endif
                }
                .onChange(of: surface) { _, newSurface in
                    Logger.ui.info("[PLAYER-SURFACE] run=\(RuntimeDiagnostics.sessionID, privacy: .public) surface=\(String(describing: newSurface), privacy: .public) animated_artwork=\(animatedArtwork, privacy: .public) budget=\(LumaPerformance.budget.summary, privacy: .public)")
                    if newSurface == .lyrics {
                        if lyricsViewModel?.shouldAutoDismissLyrics == true {
                            surface = .player
                            return
                        }
                        lyricsViewModel?.setVisible(true, owner: lyricsVisibilityOwner)
                        showLyricsChrome()
                    } else {
                        lyricsViewModel?.prefersHiddenChrome = false
                        lyricsViewModel?.setVisible(false, owner: lyricsVisibilityOwner)
                    }
                }
                .onChange(of: lyricsViewModel?.shouldAutoDismissLyrics) { _, shouldDismiss in
                    if shouldDismiss == true, showLyrics {
                        withAnimation(LumaAnimation.surface) { surface = .player }
                    }
                }
                .onAppear {
                    MemoryFootprintProbe.report("player_open")
                    Logger.ui.info("[PLAYER-VIEW] run=\(RuntimeDiagnostics.sessionID, privacy: .public) event=appear animated_artwork=\(animatedArtwork, privacy: .public) budget=\(LumaPerformance.budget.summary, privacy: .public)")
                    if openTrace == nil {
                        let trace = DiagnosticsCenter.shared.begin(.playerOpen)
                        openTrace = trace
                        Task { @MainActor in
                            await Task.yield()
                            trace.finish(Task.isCancelled ? .cancelled : .success)
                        }
                    }
                    if openWithQueue, !playerState.isLiveStream {
                        surface = .queue
                    } else if openWithLyrics {
                        if lyricsViewModel?.shouldAutoDismissLyrics != true {
                            surface = .lyrics
                        }
                    }
                    #if os(iOS)
                    MusicHapticsController.shared.setPlaying(playerState.playbackState == .playing)
                    #endif
                    lyricsViewModel?.setVisible(showLyrics, owner: lyricsVisibilityOwner)
                    atmosphereReady = false
                    atmosphereTask?.cancel()
                    atmosphereTask = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(usesWidePlayerLayout ? 320 : 180)) } catch { return }
                        atmosphereReady = true
                    }
                    if showLyrics { showLyricsChrome() }
                }
                .onDisappear {
                    captureLyricsPresentation()
                    MemoryFootprintProbe.report("player_close")
                    Logger.ui.info("[PLAYER-VIEW] run=\(RuntimeDiagnostics.sessionID, privacy: .public) event=disappear")
                    openTrace?.finish(.cancelled)
                    openTrace = nil
                    let closeTrace = DiagnosticsCenter.shared.begin(.playerClose)
                    Task { @MainActor in
                        await Task.yield()
                        closeTrace.finish(Task.isCancelled ? .cancelled : .success)
                    }
                    atmosphereTask?.cancel()
                    atmosphereTask = nil
                    atmosphereReady = false
                    lyricsViewModel?.setVisible(false, owner: lyricsVisibilityOwner)
                    #if os(iOS)
                    MusicHapticsController.shared.setPlaying(false)
                    #endif
                }
                .task {
                    guard MemoryFootprintProbe.isEnabled else { return }
                    try? await Task.sleep(for: .seconds(5))
                    MemoryFootprintProbe.report("player_5s")
                }
        }
    }

    @MainActor
    private func nowPlayingEntityIdentifier(_ playerState: PlayerState) -> EntityIdentifier? {
        guard #available(iOS 27.0, macOS 27.0, *),
              let song = playerState.currentTrack else { return nil }
        return OnscreenEntityAnnotation.songIdentifier(
            for: song,
            serverId: container?.serverState.activeServer?.id
        )
    }

    private func closePlayerPanel() {
        withAnimation(reduceMotion ? nil : LumaAnimation.surface) {
            surface = .player
        }
    }

    @ViewBuilder
    private func content(_ playerState: PlayerState) -> some View {
        let coverArtId = resolvedPlayerCoverId(playerState) ?? ""
        let dominant: Color = {
            if let prepared = vm.themeColor(for: coverArtId, serverID: container?.serverState.activeServer?.id) { return prepared }
            let source = colorExtractor.colorOverride(for: coverArtId)
                ?? colorExtractor.cachedColor(for: coverArtId) ?? .black
            if source == .black || source == .clear { return .black }
            return CoverColorRefiner.playerAtmosphere(from: source).pageColor
        }()
        let isPlaying = playerState.playbackState.hasPlaybackIntent
        let showingQueue = isQueueVisible(playerState)

        surfaceStack(playerState, coverArtId: coverArtId, isPlaying: isPlaying,
                     showingQueue: showingQueue, backgroundColor: dominant)
            .overlay {
                #if os(iOS)
                if !usesWidePlayerLayout && !usesPhoneLandscape && dynamicTypeSize.isAccessibilitySize {
                    portraitFooter(playerState)
                }
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .lumaContentWidth(.fill)
            .lumaDesktopPlayerFooter(enabled: {
                #if os(macOS)
                true
                #else
                usesWidePlayerLayout && !usesPhoneLandscape
                #endif
            }()) {
                sharedFooter(playerState)
            }
            .environment(\.marqueePaused, showLyrics || showingQueue || isRotating || scenePhase != .active)
            .environment(\.lumaPlayingAccent, LumaColors.accentForeground(on: dominant))
        .background {
            // The regular portrait phone player uses a cached, border-weighted
            // artwork mesh with Music.app's lower shade. Immersive artwork, iPad
            // and desktop keep the existing Lyricify or sleeve-extension material.
            ZStack {
                Color.black
                if usesReferencePortraitLayout && !immersiveArtwork {
                    AppleMusicArtworkBackdropView(
                        coverArtID: coverArtId,
                        image: playerCoverImage(for: coverArtId),
                        palette: container?.artworkImageCache.preparedPalette(for: coverArtId),
                        fallbackColor: dominant,
                        role: .player,
                        onPaletteReady: { backdropTint = $0 }
                    )
                } else {
                    AppleMusicLyricsBackground(
                        coverImage: playerCoverImage(for: coverArtId), fallbackColor: dominant,
                        isPlaying: playerState.playbackState == .playing,
                        animated: animatedArtwork && atmosphereReady && !showingQueue && !isRotating,
                        isPresented: !showsImmersivePlayer
                    )
                }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func surfaceStack(_ playerState: PlayerState, coverArtId: String, isPlaying: Bool,
                              showingQueue: Bool, backgroundColor: Color) -> some View {
        #if os(iOS)
        if usesPhoneLandscape {
            phoneLandscapeSurface(playerState, coverArtId: coverArtId, showingQueue: showingQueue)
        } else if usesWidePlayerLayout {
            desktopSurfaceStack(playerState, coverArtId: coverArtId, isPlaying: isPlaying, showingQueue: showingQueue)
        } else if usesReferencePortraitLayout {
            portraitPlayer(playerState, coverArtId: coverArtId, backgroundColor: backgroundColor)
        } else {
        let hideChrome = showLyrics && (lyricsViewModel?.prefersHiddenChrome == true)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                flowGap((showLyrics || showingQueue) ? surfaceHeaderTopInset : playerTopInset)

                ZStack {
                    if let lyricsVM = lyricsViewModel {
                        flowingLyricsContent(
                            playerState,
                            lyricsVM: lyricsVM,
                            hideChrome: hideChrome
                        )
                        .opacity(showLyrics ? 1 : 0)
                        .allowsHitTesting(showLyrics)
                        .accessibilityHidden(!showLyrics)
                        .animation(.easeInOut(duration: 0.20), value: showLyrics)
                    }
                    if showingQueue {
                        flowingQueueContent(playerState)
                    }

                    flowingCover(
                        playerState,
                        coverArtId: coverArtId,
                        isSource: surface == .player,
                        isPlaying: isPlaying
                    )
                    .allowsHitTesting(surface == .player)
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: showLyrics
                        ? (hideChrome
                            ? max(300, playerViewportHeight)
                            : max(300, min(440, playerViewportHeight * 0.50)))
                        : .infinity
                )
                .animation(reduceMotion ? nil : LumaAnimation.chrome, value: hideChrome)

                flowGap(Self.playerCoverToTitleGap)
                    .frame(maxHeight: hideChrome ? 0 : Self.playerCoverToTitleGap)
                    .opacity(hideChrome ? 0 : 1)

                VStack(spacing: 0) {
                    if surface == .player {
                        TrackInfoSection(
                            playerState: playerState,
                            container: container,
                            contentColor: vm.contentColor,
                            secondaryContentColor: vm.secondaryContentColor,
                            glassTint: vm.glassTint,
                            layout: .standard,
                            showLyrics: false,
                            showsTranslateBelowMenu: false,
                            showsFavoriteStar: true,
                            lyricsViewModel: lyricsViewModel
                        )
                        .transition(.identity)
                        .padding(.horizontal, LumaSpacing.l)
                    }

                    if (surface == .player || surface == .lyrics || surface == .queue), !playerState.isLiveStream {
                        ScrubberView(
                            playerState: playerState,
                            playerService: container?.playerService,
                            contentColor: vm.contentColor,
                            secondaryContentColor: vm.secondaryContentColor,
                            isExpensiveNetwork: container?.serverState.isExpensive ?? false
                        )
                        .padding(.horizontal, LumaSpacing.l)
                        .padding(.top, showingQueue ? 0 : LumaSpacing.xxxl + LumaSpacing.xs)
                        .disabled(!playerState.isPlaybackAvailable || !playerState.isSeekable)
                        .opacity(playerState.isPlaybackAvailable && playerState.isSeekable ? 1.0 : 0.4)
                    }

                    if surface == .player || surface == .lyrics || surface == .queue {
                        PlaybackControlsView(
                            playerState: playerState,
                            playerService: container?.playerService,
                            isPlaybackAvailable: playerState.isPlaybackAvailable,
                            contentColor: vm.contentColor,
                            secondaryContentColor: vm.secondaryContentColor,
                            phonePortraitControls: true
                        )
                        .padding(.top, Self.playerControlsSpacing)

                        if dynamicTypeSize < .accessibility1 {
                            VolumeSection(contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor)
                                .padding(.horizontal, LumaSpacing.xxl)
                                .padding(.top, Self.playerControlsSpacing + 6)
                        }
                    }
                }
                .modifier(lyricsChromeTransform(hideChrome))
                .frame(maxHeight: hideChrome ? 0 : nil)
                .clipped()
                .offset(y: Self.playerChromeYOffset)

                // All compact surfaces share one lower-chrome baseline so switching between
                // player, lyrics, and queue never makes the controls jump upward.
                flowGap(hideChrome ? 0 : (showingQueue ? LumaSpacing.xs : 4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(LumaAnimation.surface, value: surface)

            // Reserve content space; the single toolbar lives above all three
            // surfaces and therefore never changes identity or layout on selection.
            Color.clear.frame(height: hideChrome ? 0 : ImmersivePlayerMetrics.flowingFooterReservation)
        }
        .overlay(alignment: .top) {
            topBar
                .padding(.top, 2)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        playerTopInset = max(geo.safeAreaInsets.top, 0) + 14
                        playerViewportHeight = geo.size.height
                    }
                    .onChange(of: geo.safeAreaInsets.top) { _, top in
                        playerTopInset = max(top, 0) + 14
                    }
                    .onChange(of: geo.size.height) { _, height in
                        playerViewportHeight = height
                    }
            }
        }
        } // end compact flowing
        #else
        desktopSurfaceStack(playerState, coverArtId: coverArtId, isPlaying: isPlaying, showingQueue: showingQueue)
        #endif
    }

    #if os(iOS)
    /// Lightened artwork atmosphere used by the portrait player's translucent
    /// seek/volume tracks. Keeping the tint close to white preserves legibility
    /// while letting the cover colour show through the unfilled track.
    private var portraitControlTint: Color {
        let base = vm.atmosphereMid == .black ? vm.atmosphereBottom : vm.atmosphereMid
        return base.blended(with: .white, amount: 0.55)
    }

    /// Player, lyrics and queue share this entire hierarchy. Only upper content
    /// visibility changes; the seek/transport/volume/output views stay mounted.
    private func portraitPlayer(_ state: PlayerState, coverArtId: String, backgroundColor: Color) -> some View {
        GeometryReader { geometry in
            let top = geometry.safeAreaInsets.top
            let bottom = geometry.safeAreaInsets.bottom
            let size = CGSize(width: geometry.size.width, height: geometry.size.height + top + bottom)
            let metrics = ImmersivePlayerMetrics(size: size, topInset: top, bottomInset: bottom)
            let hideChrome = showLyrics && (lyricsViewModel?.prefersHiddenChrome == true)
            let sliderBackground = backdropTint
                ?? container?.artworkImageCache.preparedPalette(for: coverArtId)?.edgeAnalysis?.bottomBackground
                ?? vm.atmosphereBottom
            let sliderPalette = ImmersiveSliderPalette.make(
                tint: portraitControlTint,
                background: sliderBackground
            )
            ImmersivePlayerControlsLayout(topInset: top, bottomInset: bottom, expandedPanel: hideChrome,
                showsStandardArtwork: !immersiveArtwork && surface == .player,
                panelBottomSpacing: surface == .queue ? 0 : LumaSpacing.l,
                panelTopLift: surface == .player ? 0 : ImmersivePlayerMetrics.panelHeaderLift) {
                TrackInfoSection(
                    playerState: state, container: container,
                    contentColor: ImmersivePlayerInk.primary, secondaryContentColor: ImmersivePlayerInk.artist,
                    glassTint: vm.glassTint, layout: .immersivePortrait,
                    showsFavoriteStar: true, lyricsViewModel: lyricsViewModel
                )
                .opacity(surface == .player ? 1 : 0)
                .allowsHitTesting(surface == .player)
                .accessibilityHidden(surface != .player)
                ZStack {
                    if !state.isLiveStream {
                        ScrubberView(playerState: state, playerService: container?.playerService,
                            contentColor: ImmersivePlayerInk.controls,
                            secondaryContentColor: ImmersivePlayerInk.timing,
                            isExpensiveNetwork: container?.serverState.isExpensive ?? false, immersivePortrait: true,
                            backgroundTint: portraitControlTint,
                            sliderPalette: sliderPalette,
                            playerSurface: surface)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.42), value: sliderPalette)
                            .disabled(!state.isPlaybackAvailable || !state.isSeekable)
                            .opacity(state.isPlaybackAvailable && state.isSeekable ? 1 : 0.4)
                    }
                }
                .modifier(lyricsChromeTransform(hideChrome))
                PlaybackControlsView(playerState: state, playerService: container?.playerService,
                    isPlaybackAvailable: state.isPlaybackAvailable, contentColor: ImmersivePlayerInk.primary,
                    secondaryContentColor: ImmersivePlayerInk.controls, spreadsTransport: true, phonePortraitControls: true)
                    .modifier(lyricsChromeTransform(hideChrome))
                VolumeSection(contentColor: ImmersivePlayerInk.controls,
                    secondaryContentColor: ImmersivePlayerInk.controls,
                    backgroundTint: portraitControlTint,
                    sliderPalette: sliderPalette)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.42), value: sliderPalette)
                    .modifier(lyricsChromeTransform(hideChrome))
                BottomToolbar(surface: $surface, isLiveStream: state.isLiveStream,
                    lyricsEnabled: lyricsViewModel?.isLyricsButtonEnabled ?? false,
                    lyricsViewModel: lyricsViewModel, translateEnabled: false,
                    contentColor: ImmersivePlayerInk.primary,
                    secondaryContentColor: ImmersivePlayerInk.controls,
                    playerState: state, showsRouteName: true, phonePortrait: true,
                    phonePortraitPalette: sliderPalette)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.42), value: sliderPalette)
                    .modifier(lyricsChromeTransform(hideChrome))
                portraitPanels(state, coverArtId: coverArtId, hideChrome: hideChrome)
            }
            .frame(width: size.width, height: size.height)
            .background {
                ImmersiveNowPlayingBackground(
                    coverArtId: coverArtId,
                    initialImage: playerCoverImage(for: coverArtId),
                    fallbackColor: backgroundColor,
                    metrics: metrics,
                    lowerEdgeRGB: container?.artworkImageCache
                        .preparedPalette(for: coverArtId)?.edgeAnalysis?.packedBottomBackground
                )
                .opacity(showsImmersivePlayer ? 1 : 0)
            }
            .offset(y: -top)
        }
        .overlay(alignment: .top) { topBar.padding(.top, LumaSpacing.xs) }
        .preferredColorScheme(.dark)
    }

    private func portraitPanels(_ state: PlayerState, coverArtId: String,
                                hideChrome: Bool) -> some View {
        ZStack {
            if immersiveArtwork {
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if !immersiveArtwork {
                StandardPlayerArtworkSlot(isPlaying: state.playbackState.hasPlaybackIntent,
                                          reduceMotion: reduceMotion) { _ in
                    CoverArtView(id: coverArtId, size: ArtworkTier.hero.decodePixels, tier: .hero,
                                 initialImage: playerCoverImage(for: coverArtId))
                }
                .trackSkipSwipe(playerState: state)
                .opacity(surface == .player ? 1 : 0)
                .allowsHitTesting(surface == .player)
                .accessibilityHidden(surface != .player)
            }
            if (showLyrics && lyricsViewModel != nil) || surface == .queue {
                // One header stays mounted while lyrics and queue swap, and the
                // 72-point cover remains in normal layout flow. The previous
                // matched-geometry morph could leave the cover at a source frame
                // instead of the header, so the panel uses a plain crossfade.
                VStack(spacing: 0) {
                    portraitPanelHeader(state, coverArtId: coverArtId)

                    if showLyrics, let lyricsVM = lyricsViewModel {
                        LyricsView(viewModel: lyricsVM, bottomChromeInset: hideChrome ? 0 : LumaSpacing.s,
                            extendsToBottomEdge: hideChrome, onInteraction: showLyricsChrome, onChromeScroll: setLyricsChrome, consumesLineTapToRevealChrome: hideChrome,
                            presentationIsVisible: showLyrics)
                            .id(lyricsVM.songId)
                            .animation(nil, value: surface)
                            .padding(.top, LumaSpacing.s)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .bottomTrailing) {
                                if !hideChrome, shouldShowLyricsTranslate(lyricsVM) {
                                    LumaLyricsTranslateButton(lyricsViewModel: lyricsVM,
                                        contentColor: ImmersivePlayerInk.primary,
                                        buttonSize: ImmersivePlayerMetrics.dismissTapHeight)
                                        .padding(.trailing, 24)
                                        .padding(.bottom, LumaSpacing.s)
                                }
                            }
                            .transition(.opacity)
                    } else if surface == .queue {
                        VStack(spacing: 0) {
                            queuePills(state)
                                .padding(.horizontal, LumaSpacing.xxxl)
                                .padding(.top, 12)
                            InlineQueueList(playerState: state, contentColor: ImmersivePlayerInk.primary,
                                secondaryContentColor: ImmersivePlayerInk.artist, loadArtwork: isQueueVisible(state),
                                compactPhoneLayout: true)
                                .environment(\.playbackVisualsPresented, isQueueVisible(state))
                                .padding(.top, 3)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
            }
        }
        // The square artwork slot must not cut off its animated drop shadow.
        .clipShape(Rectangle().inset(by: !immersiveArtwork && surface == .player ? -LumaSpacing.xxxl : 0))
        .contentShape(Rectangle())
        // This last layout slot overlaps the title/favorite row. In immersive
        // player mode it contains decoration only and must pass every tap through.
        .allowsHitTesting(surface != .player || !immersiveArtwork)
    }

    private func portraitPanelHeader(_ state: PlayerState, coverArtId: String) -> some View {
        HStack(spacing: LumaSpacing.m) {
            Button(action: closePlayerPanel) {
                CoverArtCard(id: coverArtId, size: ImmersivePlayerMetrics.panelHeaderSide, tier: .thumb,
                             initialImage: playerCoverImage(for: coverArtId))
                    .frame(width: ImmersivePlayerMetrics.panelHeaderSide, height: ImmersivePlayerMetrics.panelHeaderSide)
            }
            .buttonStyle(.plain)
            .frame(width: ImmersivePlayerMetrics.panelHeaderSide, height: ImmersivePlayerMetrics.panelHeaderSide)
            .accessibilityLabel(Text("Now Playing"))
            TrackInfoSection(playerState: state, container: container,
                contentColor: ImmersivePlayerInk.primary, secondaryContentColor: ImmersivePlayerInk.artist,
                glassTint: vm.glassTint, layout: .lyricsHeader, showsTranslateBelowMenu: false,
                showsCoverThumbnail: false, showsFavoriteStar: true, lyricsViewModel: lyricsViewModel)
        }
        .padding(.leading, LumaSpacing.xxxl)
        .padding(.trailing, 26)
        .frame(height: ImmersivePlayerMetrics.panelHeaderSide)
    }

    /// One stable overlay for player, lyrics and queue. Surface content can grow
    /// or collapse without moving the output picker, selection circles or labels.
    private func portraitFooter(_ state: PlayerState) -> some View {
        GeometryReader { geometry in
            let hideChrome = showLyrics && (lyricsViewModel?.prefersHiddenChrome == true)
            let sliderPalette = ImmersiveSliderPalette.make(
                tint: portraitControlTint,
                background: backdropTint ?? vm.atmosphereBottom
            )
            PortraitPlayerFooterLayout(topInset: geometry.safeAreaInsets.top,
                                       bottomInset: geometry.safeAreaInsets.bottom) {
                BottomToolbar(
                    surface: $surface, isLiveStream: state.isLiveStream,
                    lyricsEnabled: lyricsViewModel?.isLyricsButtonEnabled ?? false,
                    lyricsViewModel: lyricsViewModel, translateEnabled: false,
                    contentColor: usesImmersivePortraitLayout ? ImmersivePlayerInk.primary : vm.contentColor,
                    secondaryContentColor: usesImmersivePortraitLayout ? ImmersivePlayerInk.controls : vm.secondaryContentColor,
                    playerState: state, phonePortrait: true,
                    phonePortraitPalette: sliderPalette
                )
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.42), value: sliderPalette)
                .modifier(lyricsChromeTransform(hideChrome))
            }
        }
    }

    /// Keep the artwork in the same slot while the right column switches surfaces.
    private func phoneLandscapeSurface(_ state: PlayerState, coverArtId: String, showingQueue: Bool) -> some View {
        let hideChrome = showLyrics && lyricsViewModel?.prefersHiddenChrome == true
        let isPlaying = state.playbackState.hasPlaybackIntent
        return PhoneLandscapePlayerColumns {
            CoverArtView(id: coverArtId, size: ArtworkTier.hero.decodePixels, tier: .hero,
                         initialImage: playerCoverImage(for: coverArtId))
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: LumaCornerRadius.large, style: .continuous))
                .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
                .modifier(PlayerArtworkPlaybackModifier(isPlaying: isPlaying, reduceMotion: reduceMotion))
                .trackSkipSwipe(playerState: state)
                .onTapGesture {
                    if surface == .player { toggleArtworkPlayback(state) }
                    else { closePlayerPanel() }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    if surface == .player { toggleArtworkPlayback(state) }
                    else { closePlayerPanel() }
                }
        } controls: {
            VStack(spacing: 8) {
                TrackInfoSection(
                    playerState: state, container: container,
                    contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor,
                    glassTint: vm.glassTint, layout: .phoneLandscape, showLyrics: showLyrics,
                    showsTranslateBelowMenu: false, showsFavoriteStar: true,
                    lyricsViewModel: lyricsViewModel
                )
                .fixedSize(horizontal: false, vertical: true)
                if showLyrics {
                    desktopLyricsPanel(state)
                } else if showingQueue {
                    queuePills(state)
                    InlineQueueList(playerState: state, contentColor: vm.contentColor,
                                    secondaryContentColor: vm.secondaryContentColor, loadArtwork: true)
                        .environment(\.colorScheme, vm.isLightBackground ? .light : .dark)
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            if !state.isLiveStream {
                                ScrubberView(playerState: state, playerService: container?.playerService,
                                         contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor,
                                             isExpensiveNetwork: container?.serverState.isExpensive ?? false,
                                             phoneLandscape: true)
                                    .disabled(!state.isPlaybackAvailable || !state.isSeekable)
                            }
                            GeometryReader { controls in
                                PlaybackControlsView(playerState: state, playerService: container?.playerService,
                                                     isPlaybackAvailable: state.isPlaybackAvailable,
                                                 contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor,
                                                     compactLayout: true, spreadsTransport: true)
                                    .padding(.horizontal, min(36, max(0, (controls.size.width - 176) / 2)))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .frame(height: 64)
                            VolumeSection(contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.bottom, showLyrics ? 0 : 104)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                BottomToolbar(surface: $surface, isLiveStream: state.isLiveStream,
                              lyricsEnabled: lyricsViewModel?.isLyricsButtonEnabled ?? false,
                              lyricsViewModel: lyricsViewModel,
                              contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor,
                              playerState: state, showsRouteName: true, phoneLandscape: true)
                    .overlay(alignment: .trailing) {
                        if showLyrics, let lyricsVM = lyricsViewModel, shouldShowLyricsTranslate(lyricsVM) {
                            LumaLyricsTranslateButton(lyricsViewModel: lyricsVM, contentColor: vm.contentColor,
                                buttonSize: ImmersivePlayerMetrics.dismissTapHeight)
                                .padding(.trailing, 16 + (ImmersivePlayerMetrics.footerHeight - ImmersivePlayerMetrics.dismissTapHeight) / 2)
                                .offset(y: -(ImmersivePlayerMetrics.footerHeight + ImmersivePlayerMetrics.landscapeTranslationGap))
                        }
                    }
                    .padding(.bottom, 55)
                    .modifier(lyricsChromeTransform(hideChrome))
            }
        }
        .overlay(alignment: .top) { topBar.padding(.top, 27) }
        .ignoresSafeArea()
        .statusBarHidden(true)
    }
    #endif

    @ViewBuilder
    private func desktopSurfaceStack(
        _ playerState: PlayerState,
        coverArtId: String,
        isPlaying: Bool,
        showingQueue: Bool
    ) -> some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, LumaSpacing.s)

            desktopPlayerSurface(
                playerState,
                coverArtId: coverArtId,
                isPlaying: isPlaying,
                showingQueue: showingQueue
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func desktopPlayerSurface(
        _ playerState: PlayerState,
        coverArtId: String,
        isPlaying: Bool,
        showingQueue: Bool
    ) -> some View {
        let sidePanelOpen = showLyrics || showingQueue
        let isPhoneLandscape = horizontalSizeClass == .compact && verticalSizeClass == .compact

        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            let availableHeight = proxy.size.height
            let isShortHeight = availableHeight < 760

            // Music.app keeps the sleeve large but leaves a stable column for the
            // title, scrubber, transport, volume and output controls beneath it.
            let coverTopInset = isPhoneLandscape ? 8
                : (isShortHeight ? 24 : max(32, min(72, availableHeight * 0.06)))
            let artToInfoGap: CGFloat = isPhoneLandscape ? 8
                : (isShortHeight ? 14 : LumaSpacing.xxxxl - LumaSpacing.s)
            let titleToScrubberGap: CGFloat = isPhoneLandscape ? 4
                : (isShortHeight ? 10 : LumaSpacing.xl)
            let scrubberToTransportGap: CGFloat = isPhoneLandscape ? 4
                : (isShortHeight ? 10 : LumaSpacing.xxl)
            let transportToVolumeGap: CGFloat = isPhoneLandscape ? 4
                : (isShortHeight ? 10 : LumaSpacing.xl)
            let columnGap: CGFloat = isPhoneLandscape
                ? LumaSpacing.l
                : max(LumaSpacing.xxl, availableWidth * LumaWideLayout.playerColumnGapFraction)
            let horizontalPadding: CGFloat = isPhoneLandscape ? LumaSpacing.l : LumaSpacing.xxxl

            let belowCoverHeight = 46 + 36 + 72 + 36
                + artToInfoGap + titleToScrubberGap + scrubberToTransportGap + transportToVolumeGap
            let coverByWidth = availableWidth * (sidePanelOpen ? 0.42 : 0.46)
            let coverByHeight = availableHeight - coverTopInset - belowCoverHeight - 12
            let coverSize: CGFloat = isPhoneLandscape
                ? LumaWideLayout.playerCoverCapCompactHeight
                : max(260, min(coverByWidth, coverByHeight, LumaWideLayout.playerCoverMax))
            let leftColumnWidth = coverSize + 48
            let controlsWidth = coverSize

            HStack(alignment: .top, spacing: columnGap) {
                if !sidePanelOpen { Spacer(minLength: 0) }

                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: coverTopInset)

                    CoverArtView(
                        id: coverArtId,
                        size: max(700, Int(coverSize * 2)),
                        initialImage: playerCoverImage(for: coverArtId)
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: coverSize, height: coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: LumaCornerRadius.large, style: .continuous))
                    .shadow(color: .black.opacity(isPlaying ? 0.30 : 0.22),
                            radius: isPlaying ? 28 : 20, y: isPlaying ? 12 : 8)
                    .scaleEffect(isPlaying ? 1.0 : 0.94)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: isPlaying)
                    .trackSkipSwipe(playerState: playerState)
                    .onTapGesture {
                        if sidePanelOpen { closePlayerPanel() }
                        else { toggleArtworkPlayback(playerState) }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(sidePanelOpen ? Text("Now Playing") : Text("Album Artwork"))
                    .accessibilityAction {
                        if sidePanelOpen { closePlayerPanel() }
                        else { toggleArtworkPlayback(playerState) }
                    }

                    Color.clear
                        .frame(height: artToInfoGap)

                    VStack(spacing: 0) {
                        TrackInfoSection(
                            playerState: playerState,
                            container: container,
                            contentColor: vm.contentColor,
                            secondaryContentColor: vm.secondaryContentColor,
                            glassTint: vm.glassTint,
                            layout: .widePlayer,
                            showLyrics: false,
                            showsTranslateBelowMenu: false,
                            showsFavoriteStar: true,
                            lyricsViewModel: lyricsViewModel
                        )
                        .frame(width: controlsWidth)

                        if !playerState.isLiveStream {
                            ScrubberView(
                                playerState: playerState,
                                playerService: container?.playerService,
                                contentColor: vm.contentColor,
                                secondaryContentColor: vm.secondaryContentColor,
                                isExpensiveNetwork: container?.serverState.isExpensive ?? false,
                                widePlayer: true
                            )
                            .frame(width: controlsWidth)
                            .padding(.top, titleToScrubberGap)
                            .disabled(!playerState.isPlaybackAvailable || !playerState.isSeekable)
                            .opacity(playerState.isPlaybackAvailable && playerState.isSeekable ? 1.0 : 0.4)
                        }

                        PlaybackControlsView(
                            playerState: playerState,
                            playerService: container?.playerService,
                            isPlaybackAvailable: playerState.isPlaybackAvailable,
                            contentColor: vm.contentColor,
                            secondaryContentColor: vm.secondaryContentColor,
                            showsShuffleRepeat: !playerState.isLiveStream,
                            widePlayer: true
                        )
                        .frame(width: controlsWidth)
                        .padding(.top, scrubberToTransportGap)

                        if atmosphereReady, dynamicTypeSize < .accessibility1 {
                            VolumeSection(
                                contentColor: vm.contentColor,
                                secondaryContentColor: vm.secondaryContentColor
                            )
                            .frame(width: controlsWidth)
                            .padding(.top, transportToVolumeGap)
                        }
                    }
                }
                .frame(width: leftColumnWidth)
                .frame(maxHeight: .infinity, alignment: .top)

                if showLyrics {
                    desktopLyricsPanel(playerState)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if showingQueue {
                    desktopQueuePanel(playerState)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func desktopLyricsPanel(_ playerState: PlayerState) -> some View {
        Group {
            if let lyricsVM = lyricsViewModel {
                LyricsView(viewModel: lyricsVM, lineAlignment: .trailing, density: .spacious,
                    wideStage: true,
                    usesMeasuredScrollAnchor: usesPhoneLandscape,
                    phoneLandscape: usesPhoneLandscape,
                    // iPad/Mac keep the lower chrome fixed while the reader scrolls.
                    // Hiding it changes the safe-area inset, which also changes the
                    // wide player's height-derived artwork size (a zoom on scroll).
                    bottomChromeInset: 0,
                    extendsToBottomEdge: false,
                    onInteraction: nil, onChromeScroll: nil,
                    consumesLineTapToRevealChrome: false,
                    presentationIsVisible: showLyrics)
                    .id(lyricsVM.songId)
            } else {
                ContentUnavailableView(
                    "No Lyrics",
                    systemImage: "text.quote",
                    description: Text("Play a song to see lyrics here.")
                )
                .foregroundStyle(vm.secondaryContentColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.trailing, usesPhoneLandscape ? 0 : LumaSpacing.xxxxl + LumaSpacing.l)
        .overlay(alignment: .topTrailing) {
            if let lyricsVM = lyricsViewModel,
               shouldShowLyricsTranslate(lyricsVM) {
                LumaLyricsTranslateButton(
                    lyricsViewModel: lyricsVM,
                    contentColor: vm.contentColor,
                    buttonSize: 44,
                    iconSize: 17
                )
                // Music.app's Sing control sits at the top of the lyric column,
                // not in the bottom transport chrome.
                .padding(.top, 56)
                .padding(.trailing, 24)
            }
        }
    }

    /// The full player (and its LyricsViewModel) is recreated on every
    /// presentation. Preserve the user's layer choices in the container-owned
    /// session state before the old view model is released.
    private func captureLyricsPresentation() {
        guard let lyricsViewModel, let state = container?.lyricsPresentationState else { return }
        state.areTranslationsVisible = lyricsViewModel.areTranslationsVisible
        state.arePronunciationsVisible = lyricsViewModel.arePronunciationsVisible
    }

    /// Restore layer visibility only after the new lyric document has loaded;
    /// applying it before `load()` would be overwritten by the seeding pass.
    private func restoreLyricsPresentation(to lyricsVM: LyricsViewModel) {
        guard let state = container?.lyricsPresentationState else { return }
        if state.areTranslationsVisible { lyricsVM.areTranslationsVisible = true }
        if state.arePronunciationsVisible { lyricsVM.arePronunciationsVisible = true }
    }

    /// Applies a Siri-requested lyric layer after the existing lyrics pipeline
    /// has loaded. Translation generation stays inside LyricsViewModel.
    private func applyLyricsMode(_ mode: LumaLyricsViewMode, to lyricsVM: LyricsViewModel) async {
        switch mode {
        case .lyrics:
            // Opening the lyrics surface (including from the mini player or
            // Siri) must not discard the layer choices restored from the
            // previous player session. Explicit hide actions remain available
            // in the lyrics menu.
            break
        case .translation:
            LyricsTranslationSettings.shared.isTranslationEnabled = true
            if lyricsVM.hasStoredTranslation {
                lyricsVM.revealTranslation()
            } else {
                await lyricsVM.translateCurrentLyrics()
            }
            lyricsVM.areTranslationsVisible = true
        case .pronunciation:
            lyricsVM.arePronunciationsVisible = true
        }
        lyricsVM.scrollRestoreToken += 1
    }

    private func shouldShowLyricsTranslate(_ lyricsVM: LyricsViewModel) -> Bool {
        guard LyricsTranslationSettings.shared.isTranslationEnabled else { return false }
        guard case .loaded = lyricsVM.state else { return false }
        return lyricsVM.needsTranslation
    }

    @ViewBuilder
    private func desktopQueuePanel(_ playerState: PlayerState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: LumaSpacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Continue Playing", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.lumaSectionTitle)
                        .foregroundStyle(vm.contentColor)
                    if let album = playerState.currentTrack?.albumName, !album.isEmpty {
                        Text("From \(album)")
                            .font(.lumaCaption)
                            .foregroundStyle(vm.secondaryContentColor)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: LumaSpacing.m) {
                    Button {
                        HapticFeedback.light.trigger()
                        Task { await container?.playerService.setAutoExtendEnabled(!playerState.isAutoExtendEnabled) }
                    } label: {
                        Image(systemName: "infinity")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(playerState.isAutoExtendEnabled ? Color.lumaAccent : vm.secondaryContentColor)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Auto-extend with Smart Shuffle", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

                    Button {
                        HapticFeedback.light.trigger()
                        Task { await container?.playerService.toggleShuffle() }
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(playerState.isShuffled ? Color.lumaAccent : vm.secondaryContentColor)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playerState.isShuffled ? String(localized: "Shuffle On", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Shuffle Off", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }
            }
            .padding(.trailing, LumaSpacing.l)
            .padding(.bottom, LumaSpacing.m)

            InlineQueueList(
                playerState: playerState,
                contentColor: vm.contentColor,
                secondaryContentColor: vm.secondaryContentColor,
                loadArtwork: true
            )
            .environment(\.colorScheme, vm.isLightBackground ? .light : .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.trailing, LumaSpacing.l)

            queueStatusLine(playerState)
                .padding(.trailing, LumaSpacing.l)
                .padding(.vertical, LumaSpacing.s)
        }
    }

    private func showLyricsChrome() {
        setLyricsChrome(.reveal)
    }

    private func setLyricsChrome(_ action: LyricsChromeScrollAction) {
        // Wide iPad/Mac player: the lyric column scrolls inside a fixed
        // safe-area inset. Collapsing the footer here would also re-measure
        // the artwork column and looked like an unwanted zoom.
        guard !usesDesktopDetail else { return }
        let hidden = action == .hide
        guard surface == .lyrics, let lyricsViewModel,
              lyricsViewModel.prefersHiddenChrome != hidden else { return }
        withAnimation(reduceMotion ? nil : LumaAnimation.chrome) {
            lyricsViewModel.prefersHiddenChrome = hidden
        }
    }

    private func lyricsChromeTransform(_ hidden: Bool) -> some ViewModifier {
        PlayerLyricsChromeVisibility(hidden: hidden, reduceMotion: reduceMotion)
    }

    #if os(iOS)
    private func flowGap(_ floor: CGFloat) -> some View {
        Color.clear.frame(minHeight: floor, maxHeight: floor)
    }

    private func flowingCover(
        _ playerState: PlayerState,
        coverArtId: String,
        isSource: Bool,
        isPlaying: Bool
    ) -> some View {
        GeometryReader { geo in
            let side = min(
                max(0, geo.size.width - playerCoverHPadding * 2),
                geo.size.height
            )
            let corner = max(12, side * 0.035)
            let scale: CGFloat = isSource
                ? (isPlaying ? 1.0 : Self.playerCoverPausedScale)
                : 1.0
            let artSide: CGFloat = isSource ? side : 64
            let artCorner: CGFloat = isSource ? corner : LumaCornerRadius.standard

            CoverArtView(id: coverArtId, size: 600, initialImage: playerCoverImage(for: coverArtId), contentMode: .fill)
                .frame(width: artSide, height: artSide)
                .clipShape(RoundedRectangle(cornerRadius: artCorner, style: .continuous))
                .shadow(color: .black.opacity(isSource ? 0.4 : 0), radius: isPlaying ? 28 : 18, y: isPlaying ? 14 : 10)
                .scaleEffect(scale)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84),
                    value: isPlaying
                )
                .matchedGeometryEffect(id: "queueCover", in: morphNS, isSource: isSource)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func flowingLyricsContent(
        _ playerState: PlayerState,
        lyricsVM: LyricsViewModel,
        hideChrome: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: LumaSpacing.m) {
                Button(action: closePlayerPanel) {
                    Color.clear.frame(width: 64, height: 64).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Now Playing"))
                .matchedGeometryEffect(id: "queueCover", in: morphNS, isSource: surface == .lyrics)

                TrackInfoSection(
                    playerState: playerState,
                    container: container,
                    contentColor: vm.contentColor,
                    secondaryContentColor: vm.secondaryContentColor,
                    glassTint: vm.glassTint,
                    layout: .lyricsHeader,
                    showLyrics: true,
                    showsTranslateBelowMenu: false,
                    showsCoverThumbnail: false,
                    showsFavoriteStar: true,
                    lyricsViewModel: lyricsVM
                )
                .transition(.identity)
            }
            .padding(.horizontal, LumaSpacing.l)
            .padding(.top, LumaSpacing.xs)
            .padding(.bottom, LumaSpacing.s)

            LyricsView(
                viewModel: lyricsVM,
                bottomChromeInset: hideChrome ? 0 : 8,
                extendsToBottomEdge: hideChrome,
                onInteraction: showLyricsChrome, onChromeScroll: setLyricsChrome,
                consumesLineTapToRevealChrome: hideChrome,
                presentationIsVisible: showLyrics
            )
            // Layout/matched artwork animate at the surface level; rebuilding every word's
            // masks and measurements inside that transaction makes the transition hitch.
            .animation(nil, value: surface)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
            .overlay(alignment: .bottomTrailing) {
                if !hideChrome, shouldShowLyricsTranslate(lyricsVM) {
                    LumaLyricsTranslateButton(
                        lyricsViewModel: lyricsVM,
                        contentColor: vm.contentColor,
                        buttonSize: 46,
                        iconSize: 16
                    )
                    .padding(.trailing, 28)
                    .padding(.bottom, LumaSpacing.s)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : LumaAnimation.chrome, value: hideChrome)
        }
    }

    private func flowingQueueContent(_ playerState: PlayerState) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: LumaSpacing.m) {
                Button(action: closePlayerPanel) {
                    Color.clear.frame(width: 64, height: 64).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Now Playing"))
                .matchedGeometryEffect(id: "queueCover", in: morphNS, isSource: surface == .queue)

                TrackInfoSection(
                    playerState: playerState,
                    container: container,
                    contentColor: vm.contentColor,
                    secondaryContentColor: vm.secondaryContentColor,
                    glassTint: vm.glassTint,
                    layout: .lyricsHeader,
                    showLyrics: false,
                    showsCoverThumbnail: false,
                    showsFavoriteStar: true,
                    lyricsViewModel: nil
                )
            }
            .padding(.horizontal, LumaSpacing.l)
            .padding(.top, LumaSpacing.s)

            queuePills(playerState)
                .padding(.horizontal, LumaSpacing.l)
                .padding(.top, LumaSpacing.m)
                .padding(.bottom, LumaSpacing.s)

            InlineQueueList(
                playerState: playerState,
                contentColor: vm.contentColor,
                secondaryContentColor: vm.secondaryContentColor,
                loadArtwork: true
            )
            .environment(\.colorScheme, vm.isLightBackground ? .light : .dark)
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)

        }
    }
    #endif

    private func isQueueVisible(_ playerState: PlayerState) -> Bool {
        surface == .queue && !playerState.isLiveStream
    }

    @ViewBuilder
    private func queueSurface(_ playerState: PlayerState, coverArtId: String) -> some View {
        VStack(spacing: 0) {
            collapsedTrackHeader(playerState, coverArtId: coverArtId)
                .padding(.horizontal, LumaSpacing.l)
                .padding(.top, LumaSpacing.xs)

            queuePills(playerState)
                .padding(.horizontal, LumaSpacing.l)
                .padding(.top, LumaSpacing.m)
                .padding(.bottom, LumaSpacing.s)

            InlineQueueList(
                playerState: playerState,
                contentColor: vm.contentColor,
                secondaryContentColor: vm.secondaryContentColor,
                loadArtwork: isQueueVisible(playerState)
            )
            .environment(\.playbackVisualsPresented, isQueueVisible(playerState))
            .environment(\.colorScheme, vm.isLightBackground ? .light : .dark)
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)

            queueStatusLine(playerState)
                .padding(.horizontal, LumaSpacing.l)
                .padding(.vertical, LumaSpacing.s)
        }
    }

    private func collapsedTrackHeader(_ playerState: PlayerState, coverArtId: String) -> some View {
        HStack(spacing: LumaSpacing.m) {
            CoverArtView(id: coverArtId, size: 120)
                .frame(width: 64, height: 64)
                .lumaCoverStyle(cornerRadius: LumaCornerRadius.standard)
                .morphCover(!reduceMotion, in: morphNS, isSource: isQueueVisible(playerState))

            TrackInfoSection(
                playerState: playerState,
                container: container,
                contentColor: vm.contentColor,
                secondaryContentColor: vm.secondaryContentColor,
                glassTint: vm.glassTint,
                layout: .standard,
                showLyrics: showLyrics,
                showsFavoriteStar: true,
                lyricsViewModel: lyricsViewModel
            )
        }
    }

    private func queuePills(_ playerState: PlayerState) -> some View {
        HStack(spacing: usesWidePlayerLayout ? LumaSpacing.s : 13) {
            queuePill(systemImage: "shuffle", isActive: playerState.isShuffled,
                      label: playerState.isShuffled ? "Shuffle On" : "Shuffle Off") {
                Task { await container?.playerService.toggleShuffle() }
            }
            queuePill(systemImage: playerState.repeatMode.systemImage, isActive: playerState.repeatMode != .off,
                      label: "Repeat") {
                Task { await container?.playerService.setRepeatMode(playerState.repeatMode.next) }
            }
            queuePill(systemImage: "infinity", isActive: playerState.isAutoExtendEnabled,
                      label: "Auto-extend with Smart Shuffle") {
                Task { await container?.playerService.setAutoExtendEnabled(!playerState.isAutoExtendEnabled) }
            }
            let crossfadeEnabled = (container?.crossfadeSettings.duration ?? 0) > 0
            queuePill(systemImage: "circle.circle", isActive: crossfadeEnabled,
                      label: "Crossfade") {
                guard let settings = container?.crossfadeSettings else { return }
                settings.duration = crossfadeEnabled ? 0 : 4
                Task { await container?.playerService.crossfadeSettingsDidChange() }
            }
        }
    }

    private func queuePill(systemImage: String, isActive: Bool, label: String, action: @escaping () -> Void) -> some View {
        // Phone landscape follows Apple Music's neutral white capsules; the wider
        // iPad/macOS layout keeps the accent-tinted pills.
        PlayerQueueModeButton(systemImage: systemImage, isActive: isActive, label: label,
            compact: !usesWidePlayerLayout || usesPhoneLandscape, contentColor: vm.contentColor,
            secondaryContentColor: vm.secondaryContentColor, action: action)
    }

    private func upNextHeader(_ playerState: PlayerState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Up Next")
                .font(.lumaSectionTitle)
                .foregroundStyle(vm.contentColor)
            if let album = playerState.currentTrack?.albumName, !album.isEmpty {
                Text(album)
                    .font(.lumaCaption)
                    .foregroundStyle(vm.secondaryContentColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func queueStatusLine(_ playerState: PlayerState) -> some View {
        let upNextCount = max(playerState.queue.count - playerState.currentIndex - 1, 0)
        var bits: [String] = ["\(upNextCount) up next"]
        if playerState.repeatMode == .all {
            bits.append("Repeating all")
        } else if playerState.repeatMode == .one {
            bits.append("Repeating one")
        }
        if playerState.isShuffled { bits.append("Shuffled") }
        if playerState.isAutoExtendEnabled { bits.append("Auto-extend on") }
        return Text(bits.joined(separator: " · "))
            .font(.lumaCaption)
            .foregroundStyle(vm.secondaryContentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
    }

    @ViewBuilder
    private func sharedFooter(_ playerState: PlayerState) -> some View {
        // Only the phone player folds its footer while reading lyrics. The wide
        // player keeps the transport footprint fixed so scrolling never resizes
        // the lyric viewport or the height-derived artwork column.
        let hideChrome = !usesDesktopDetail
            && showLyrics
            && lyricsViewModel?.prefersHiddenChrome == true
        VStack(spacing: 0) {
            if surface == .player, !usesWidePlayerLayout {
                if !playerState.isLiveStream {
                    ScrubberView(
                        playerState: playerState,
                        playerService: container?.playerService,
                        contentColor: vm.contentColor,
                        secondaryContentColor: vm.secondaryContentColor,
                        isExpensiveNetwork: container?.serverState.isExpensive ?? false
                    )
                    .padding(.horizontal, LumaSpacing.l)
                    .padding(.top, LumaSpacing.m)
                    .disabled(!playerState.isPlaybackAvailable || !playerState.isSeekable)
                    .opacity(playerState.isPlaybackAvailable && playerState.isSeekable ? 1.0 : 0.4)
                }

                PlaybackControlsView(
                    playerState: playerState,
                    playerService: container?.playerService,
                    isPlaybackAvailable: playerState.isPlaybackAvailable,
                    contentColor: vm.contentColor,
                    secondaryContentColor: vm.secondaryContentColor
                )
                .padding(.top, LumaSpacing.s)

                if dynamicTypeSize < .accessibility1 {
                    VolumeSection(contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor)
                        .padding(.horizontal, LumaSpacing.l)
                        .padding(.top, LumaSpacing.s)
                }
            }

            BottomToolbar(
                surface: $surface,
                isLiveStream: playerState.isLiveStream,
                lyricsEnabled: lyricsViewModel?.isLyricsButtonEnabled ?? false,
                lyricsViewModel: lyricsViewModel,
                // Wide player: translation moves to the lyric-column Sing slot.
                translateEnabled: usesWidePlayerLayout
                    ? false
                    : (lyricsViewModel.map(shouldShowLyricsTranslate) ?? false),
                contentColor: vm.contentColor,
                secondaryContentColor: vm.secondaryContentColor,
                playerState: playerState,
                spreadToEdges: usesWidePlayerLayout,
                showsRouteName: !usesWidePlayerLayout
            )
            .padding(.horizontal, usesWidePlayerLayout ? LumaSpacing.xxxl : LumaSpacing.l)
            .padding(.top, usesWidePlayerLayout ? LumaSpacing.xs : LumaSpacing.m)
            .padding(.bottom, usesWidePlayerLayout ? LumaSpacing.xxl : LumaSpacing.xxl)
            .safeAreaPadding(.horizontal, usesWidePlayerLayout ? LumaSpacing.xl : 0)
        }
        .modifier(lyricsChromeTransform(hideChrome))
        .frame(maxHeight: hideChrome ? 0 : nil)
        .clipped()
    }

    private var topBar: some View {
        PlayerDismissHandle(
            contentColor: (usesImmersivePortraitLayout || usesPhoneLandscape) ? ImmersivePlayerInk.primary : vm.contentColor,
            action: closePlayer
        )
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .top)
        .contentShape(Rectangle())
    }

    private func toggleArtworkPlayback(_ state: PlayerState) {
        guard isLandscapeViewport, state.isPlaybackAvailable else { return }
        HapticFeedback.transport.trigger()
        Task { await container?.playerService.togglePlayPause() }
    }

    private func closePlayer() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

private struct PlayerLyricsChromeVisibility: ViewModifier {
    let hidden: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden && !reduceMotion ? 14 : 0)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}
