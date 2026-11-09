// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import SwiftData
import AppIntents
import OSLog
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Mode

struct AlbumShelfBackgroundKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

enum AlbumDetailMode: Sendable {
    case full           // show all album songs (default — online catalog browsing)
    case downloadedOnly // show only downloaded tracks (Downloads/Offline contexts for purely-partial albums)
}

/// Resolves an already-visible album cover into a page theme before the detail view's
/// first frame is built. Album grids/lists normally have the thumbnail in RAM by the
/// time navigation starts; using it here keeps the toolbar and root mini-player from
/// briefly retaining the previous page's light/dark appearance.
struct AlbumDetailView: View {
    @Environment(\.appContainer) private var container

    private enum Source {
        case album(AlbumID3)
        case identifier(id: String, name: String)
    }

    private let source: Source
    private let coverArtId: String?
    private let suppliedDominantColor: Color
    private let suppliedCoverImage: PlatformImage?
    private let mode: AlbumDetailMode

    @Environment(DominantColorExtractor.self) private var colorExtractor
    @Environment(ArtworkImageCache.self) private var artworkImageCache

    init(
        album: AlbumID3,
        coverArtId: String? = nil,
        initialDominantColor: Color = .clear,
        initialCoverImage: PlatformImage? = nil,
        mode: AlbumDetailMode = .full
    ) {
        source = .album(album)
        self.coverArtId = coverArtId ?? album.coverArt
        suppliedDominantColor = initialDominantColor
        suppliedCoverImage = initialCoverImage
        self.mode = mode
    }

    init(
        albumId: String,
        albumName: String,
        coverArtId: String? = nil,
        initialDominantColor: Color = .clear,
        initialCoverImage: PlatformImage? = nil,
        mode: AlbumDetailMode = .full
    ) {
        source = .identifier(id: albumId, name: albumName)
        self.coverArtId = coverArtId
        suppliedDominantColor = initialDominantColor
        suppliedCoverImage = initialCoverImage
        self.mode = mode
    }

    var body: some View {
        let themeKey = coverArtId ?? resolvedAlbumID
        // Prefer the exact image supplied by the source card, then the thumbnail that
        // was just painted in the list. No network or disk work is started from body.
        let preparedImage = suppliedCoverImage
            ?? artworkImageCache.cachedImage(for: themeKey, tier: .thumb)
            ?? artworkImageCache.cachedImage(for: themeKey, tier: .hero)
        let preparedColor = immediateThemeColor(key: themeKey)
        let preparedAnalysis = artworkImageCache.preparedPalette(for: themeKey)?.edgeAnalysis
        let preparedPreference = artworkImageCache.artworkPreference(for: resolvedAlbumID)

        Group {
            if let album = resolvedAlbum {
                AlbumDetailContentView(
                    album: album,
                    coverArtId: coverArtId,
                    initialDominantColor: preparedColor,
                    initialCoverImage: preparedImage,
                    initialArtworkAnalysis: preparedAnalysis,
                    initialArtworkPreference: preparedPreference,
                    mode: mode
                )
            } else {
                AlbumDetailContentView(
                    albumId: resolvedAlbumID,
                    albumName: resolvedAlbumName,
                    coverArtId: coverArtId,
                    initialDominantColor: preparedColor,
                    initialCoverImage: preparedImage,
                    initialArtworkAnalysis: preparedAnalysis,
                    initialArtworkPreference: preparedPreference,
                    mode: mode
                )
            }
        }
        .appEntityIdentifier(onscreenEntityIdentifier)
    }

    /// Lets Siri AI resolve “this album” while the album page is on screen.
    private var onscreenEntityIdentifier: EntityIdentifier? {
        guard #available(iOS 27.0, macOS 27.0, *) else { return nil }
        return OnscreenEntityAnnotation.albumIdentifier(
            id: resolvedAlbumID,
            title: resolvedAlbumName,
            artist: resolvedAlbum?.artist,
            serverId: container?.serverState.activeServer?.id
        )
    }

    private var resolvedAlbum: AlbumID3? {
        guard case let .album(album) = source else { return nil }
        return album
    }

    private var resolvedAlbumID: String {
        switch source {
        case let .album(album): album.id
        case let .identifier(id, _): id
        }
    }

    private var resolvedAlbumName: String {
        switch source {
        case let .album(album): album.name
        case let .identifier(_, name): name
        }
    }

    private func immediateThemeColor(key: String) -> Color {
        if let override = colorExtractor.colorOverride(for: key) { return override }
        if let cached = artworkImageCache.preparedPalette(for: key)?.background { return cached }
        if suppliedDominantColor != .clear { return suppliedDominantColor }
        // Library preparation owns decoding, color clustering and edge analysis.
        // Both the first frame and the page task remain cache-only lookups.
        return .clear
    }
}

struct AlbumDetailContentView: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(TabBarChromeState.self) private var tabBarChrome
    let albumId: String
    let initialName: String
    /// Present when the source card already knows the artist. Showing it on the
    /// first zoom frame keeps the header from growing when album metadata lands.
    let initialArtist: String?
    let coverArtId: String?
    private let initialDominantColor: Color
    private let initialCoverImage: PlatformImage?
    let mode: AlbumDetailMode

    init(album: AlbumID3, coverArtId: String? = nil, initialDominantColor: Color = .clear, initialCoverImage: PlatformImage? = nil, initialArtworkAnalysis: ArtworkEdgeAnalysis? = nil, initialArtworkPreference: AlbumArtworkPreference = .automatic, mode: AlbumDetailMode = .full) {
        albumId = album.id
        initialName = album.name
        initialArtist = album.artist
        let resolvedCoverArtId = coverArtId ?? album.coverArt
        self.coverArtId = resolvedCoverArtId
        self.initialDominantColor = initialDominantColor
        self.initialCoverImage = initialCoverImage
        let itemId = album.id
        let type = FavoriteType.album.rawValue
        let aid = album.id
        _albumFavoriteMatches = Query(filter: #Predicate<FavoriteRecord> {
            $0.itemId == itemId && $0.itemType == type
        })
        _downloadedAlbumTracks = Query(filter: #Predicate<DownloadedTrack> { $0.albumId == aid })
        self.mode = mode
        _dominantColor = State(initialValue: initialDominantColor)
        _artworkAnalysis = State(initialValue: initialArtworkAnalysis)
        _artworkPreference = State(initialValue: initialArtworkPreference)
    }

    init(albumId: String, albumName: String, coverArtId: String? = nil, initialDominantColor: Color = .clear, initialCoverImage: PlatformImage? = nil, initialArtworkAnalysis: ArtworkEdgeAnalysis? = nil, initialArtworkPreference: AlbumArtworkPreference = .automatic, mode: AlbumDetailMode = .full) {
        self.albumId = albumId
        self.initialName = albumName
        self.initialArtist = nil
        self.coverArtId = coverArtId
        self.initialDominantColor = initialDominantColor
        self.initialCoverImage = initialCoverImage
        let itemId = albumId
        let type = FavoriteType.album.rawValue
        let aid = albumId
        _albumFavoriteMatches = Query(filter: #Predicate<FavoriteRecord> {
            $0.itemId == itemId && $0.itemType == type
        })
        _downloadedAlbumTracks = Query(filter: #Predicate<DownloadedTrack> { $0.albumId == aid })
        self.mode = mode
        _dominantColor = State(initialValue: initialDominantColor)
        _artworkAnalysis = State(initialValue: initialArtworkAnalysis)
        _artworkPreference = State(initialValue: initialArtworkPreference)
    }

    @Environment(\.appContainer) var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.albumNavigationAttempt) private var albumNavigationAttempt
    @Environment(DominantColorExtractor.self) var colorExtractor
    @Environment(ArtworkImageCache.self) var artworkImageCache
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State var viewModel: AlbumDetailViewModel?
    @State private var openTrace: PerformanceTrace?
    @State var dominantColor: Color = .clear
    /// Seed for the first frame only; the real value comes from the container's width on the first
    /// layout pass below. Deliberately *not* derived from `UIScreen.main`: on iPad (and in Split
    /// View / Slide Over) the screen is far wider than this view's column, which produced a hero up
    /// to ~1250 pt tall for one frame before the geometry corrected it.
    @State var pageWidth: CGFloat = 310
    @State var artworkAnalysis: ArtworkEdgeAnalysis?
    @State var artworkPreference: AlbumArtworkPreference = .automatic
    @AppStorage("coverArtUploadVersion") var coverArtUploadVersion = 0
    @State var artworkRevision = 0
    @State var paletteRequestID: String?
    var paletteIdentity: String { "\(albumCoverId):\(coverArtUploadVersion):\(artworkRevision):\(container?.serverState.accountRevision ?? 0)" }
    @State var artworkTopInset: CGFloat = 59
    @State var headerRevealed = false
    @State private var toolbarRevealed = false
    @State private var revealTask: Task<Void, Never>?
    @AppStorage("luma.visuals.albumFollowsAppearance") private var albumFollowsAppearance = false
    @AppStorage("luma.visuals.immersiveAlbums") var immersiveAlbums = true

    var artworkStyle: AlbumArtworkStyle {
        usesDesktopDetail || !immersiveAlbums ? .standard : artworkPreference.style(analysis: artworkAnalysis)
    }
    var usesFullBleedArtwork: Bool { artworkStyle != .standard }
    var albumControlSide: CGFloat {
        artworkStyle == .faded ? LumaAlbumLayout.fadedControlSide : LumaAlbumLayout.controlSide
    }
    var contentBackgroundColor: Color {
        switch artworkStyle {
        case .uniform: return artworkAnalysis?.background ?? dominantColor
        case .faded: return artworkAnalysis?.fadedBackground ?? AlbumArtworkStyle.fadedContentBackground
        case .standard: return dominantColor
        }
    }
    var heroHeight: CGFloat {
        if artworkStyle == .faded {
            let inset = LumaAlbumLayout.fadedTopInset(for: artworkAnalysis?.fadedTreatment ?? .textured)
            return pageWidth * (1 + inset)
        }
        return usesFullBleedArtwork ? pageWidth : max(LumaAlbumLayout.minimumCoverSide, pageWidth - LumaAlbumLayout.coverSideInset * 2)
    }
    @State var showDeleteAlert = false
    @State var songToAddToPlaylist: DisplayableSong?
    @State var showDescriptionSheet = false
    @State var showPinLimitAlert = false
    /// Compact scroll: 0 at top → 1 after ~heroHeight for nav bar material.
    @State var navChromeProgress: CGFloat = 0
    /// Identity for the artist pushed from this album page's header. `HomeDestination` artist values are
    /// equal by content, and `NavigationStack` reuses the entry holding an equal value — an artist page
    /// reached *from* this album must still push a fresh entry (otherwise the stack pops to an earlier
    /// artist page and the back button points at a removed entry). One token per album page instance.
    @State var artistRouteToken = UUID()
    /// Stable, page-local identity for albums pushed from the related releases shelves.
    /// A detail-to-detail path must not depend on a refreshed AlbumID3 payload.
    @Namespace var relatedAlbumZoomNamespace
    /// Identity of this page instance. `album → artist → back` regressions have twice been a page in
    /// the stack being destroyed and re-created; one log line per instance makes that visible instead
    /// of guessed at (the fixes themselves live in the navigation structure).
    @State private var pageInstanceID = UUID()
    /// The `isOnline` value this page already loaded for. A `.task` restart that carries the same
    /// value — the page was rebuilt, or SwiftUI re-applied the same id — must not re-run the whole
    /// album + More-By + description load behind whatever page is open on top of this one.
    @State private var loadedForOnlineState: Bool?
    @Query private var albumFavoriteMatches: [FavoriteRecord]
    @Query var downloadedAlbumTracks: [DownloadedTrack]

    var usesDesktopDetail: Bool {
        LumaWideLayout.usesDesktopDetail(horizontalSizeClass: horizontalSizeClass)
    }

    var isAlbumFavorite: Bool {
        guard let serverId = container?.serverState.activeServer?.id else { return false }
        return albumFavoriteMatches.contains { $0.serverId == serverId }
    }
    var downloadedCount: Int { downloadedAlbumTracks.count }
    var isOnline: Bool { container?.serverState.isOnline == true }
    /// Cover id the album theme is keyed on.
    var albumCoverId: String { viewModel?.coverArtId ?? coverArtId ?? albumId }
    private var usesWhiteAlbumInk: Bool {
        atmosphere.isThemed && !atmosphere.isLight
    }
    private var albumChromeColorScheme: ColorScheme? {
        guard atmosphere.isThemed else { return nil }
        return usesWhiteAlbumInk ? .dark : .light
    }
    private var albumStatusBarColorScheme: ColorScheme? {
        if usesFullBleedArtwork, navChromeProgress == 0,
           let artworkAnalysis, artworkAnalysis.packedTopBackground != nil {
            return LumaColors.prefersLightControl(on: artworkAnalysis.topBackground) ? .dark : .light
        }
        return albumChromeColorScheme
    }
    var albumNavigationBarColorScheme: ColorScheme? {
        albumStatusBarColorScheme
    }
    var navigationInk: Color {
        switch albumNavigationBarColorScheme {
        case .light: .black
        case .dark: .white
        default: .primary
        }
    }
    var headerTextColor: Color { atmosphere.contentColor }
    var headerSecondaryColor: Color { atmosphere.text2 }
    var albumMetadataInk: Color { headerSecondaryColor }
    /// Title + artist name render as pure white/black ink over the floating cover, like
    /// Apple Music's high-contrast presentation — independent of the cover tint.
    var heroTitleInk: Color {
        headerTextColor
    }
    /// Contrast-aware accent for the now-playing row (bars + title).
    private var heroIconColor: Color {
        if atmosphere.isThemed { return headerTextColor }
        return LumaColors.accentForeground(on: systemBackgroundColor)
    }
    /// Play CTA: black/white fill; label uses cover color when contrast allows.
    var heroButtonVariant: (background: Color, foreground: Color) {
        LumaColors.heroButtonVariant(on: atmosphere.isThemed ? atmosphere.pageColor : systemBackgroundColor,
                                    labelTint: artworkStyle == .faded ? atmosphere.pageColor : nil)
    }
    var atmosphere: AlbumAtmosphere {
        AlbumAtmosphere.from(
            dominantColor: contentBackgroundColor,
            colorScheme: colorScheme,
            increaseContrast: colorSchemeContrast == .increased,
            respectSystemAppearance: albumFollowsAppearance
        )
    }
    var theme: PlaylistTheme { atmosphere.heroTheme }
    var relatedShelfBaseColor: Color { atmosphere.isThemed ? atmosphere.pageColor : systemBackgroundColor }
    /// Unthemed pages use the system background; derive the shelf lightness from the
    /// current appearance instead of treating that white/black surface as dark.
    var relatedShelfIsLight: Bool {
        atmosphere.isThemed ? atmosphere.isLight : colorScheme == .light
    }
    /// Bottom shelves (“Other versions” / “More by”) own the mini-player inset fill.
    private var showsMoreByShelf: Bool {
        guard mode == .full, let vm = viewModel, !displaySongs().isEmpty else { return false }
        guard vm.artistId != nil else { return false }
        return !vm.otherAlbumVersions.isEmpty
            || !vm.moreAlbumsByArtist.isEmpty
    }
    private var systemBackgroundColor: Color {
        #if canImport(UIKit)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var effectiveInitialImage: PlatformImage? {
        artworkImageCache.cachedImage(for: albumCoverId, tier: .hero)
            ?? (albumCoverId == (coverArtId ?? albumId) ? initialCoverImage : nil)
            ?? artworkImageCache.cachedImage(for: albumCoverId)
    }

    // MARK: - Song filtering

    private var offlineFallbackSongs: [DisplayableSong] {
        downloadedAlbumTracks
            .map { DisplayableSong(from: $0) }
            .sorted(by: AlbumDetailViewModel.albumTrackOrder)
    }

    private func filteredSongs(_ vmSongs: [DisplayableSong]) -> [DisplayableSong] {
        switch mode {
        case .full:
            return vmSongs
        case .downloadedOnly:
            let downloadedIds = Set(downloadedAlbumTracks.map(\.songId))
            return vmSongs.filter { downloadedIds.contains($0.id) }
        }
    }

    func displaySongs() -> [DisplayableSong] {
        switch mode {
        case .downloadedOnly:
            if let vm = viewModel, vm.error == nil, !vm.songs.isEmpty {
                return filteredSongs(vm.songs)
            }
            return offlineFallbackSongs
        case .full:
            // Prefer the VM's catalog list, but back-stop with downloaded tracks whenever
            // the VM produced nothing — whether it errored OR returned an empty-success
            // payload (captive proxy / Cloudflare-WARP). This is the view-level safety net
            // that keeps a downloaded album readable through normal nav, not just Downloads.
            if let vm = viewModel, !vm.songs.isEmpty {
                return vm.songs
            }
            if isOnline, viewModel == nil || viewModel?.isLoading == true { return [] }
            return offlineFallbackSongs
        }
    }

    private var isPrimaryContentReady: Bool {
        guard let viewModel else { return false }
        // An error still owns a real page (retry / offline copy); reveal it
        // instead of leaving the opaque loading cover forever.
        return viewModel.isPrimaryContentReady || (!viewModel.isLoading && viewModel.error != nil)
    }

    var showsTrackContent: Bool {
        headerRevealed && isPrimaryContentReady
    }

    /// `unthemed` album atmosphere uses `.clear`; a clear loading cover would
    /// reveal the previous screen through the new page. Always paint an opaque
    /// page color, falling back to the system background until the palette lands.
    private var pageCoverColor: Color {
        atmosphere.isThemed ? atmosphere.pageColor : systemBackgroundColor
    }

    private var albumPage: some View {
        // Keep one root view for the lifetime of the page. The content is mounted
        // behind an opaque page-color cover until the primary payload is ready;
        // the ScrollView/LazyVStack identity never changes, so navigation and
        // pop snapshots stay stable. This avoids the old "part of the header
        // appears, then the rest loads in" behavior.
        ZStack {
            pageCoverColor.ignoresSafeArea()

            Group {
                if usesDesktopDetail {
                    desktopAlbumBody
                } else {
                    compactAlbumBody
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await viewModel?.load() }
        // More by reserves its own bottom inset; otherwise use the shared margin.
        .modifier(AlbumMiniPlayerMargin(enabled: !showsMoreByShelf))
        .lumaSoftTopScrollEdge(isVisible: !usesFullBleedArtwork || navChromeProgress > 0)
        .lumaStatusBarScrim(isLightPage: albumStatusBarColorScheme == .light,
                               isEnabled: !usesFullBleedArtwork || navChromeProgress > 0)
        .lumaDestructiveAlert(
            "Remove downloaded album?",
            isPresented: $showDeleteAlert,
            message: "The audio files will be deleted from this device."
        ) {
            Task { await viewModel?.deleteDownload() }
        }
        .sheet(item: $songToAddToPlaylist) { song in
            AddToPlaylistSheet(song: song)
        }
        .sheet(isPresented: $showDescriptionSheet) {
            let description = viewModel?.albumDescription ?? ""
            NavigationStack {
                ScrollView {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle(String(localized: "About", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .navigationBarTitleDisplayModeInline()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { showDescriptionSheet = false }
                    }
                }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
        }
        .backgroundPreferenceValue(AlbumRelatedShelfBoundsKey.self) { anchor in
            ZStack {
                if usesFullBleedArtwork {
                    atmosphere.pageColor.ignoresSafeArea()
                } else {
                    AlbumAtmosphereBackground(atmosphere: atmosphere)
                }
                AlbumRelatedShelfContinuation(
                    anchor: anchor,
                    baseColor: relatedShelfBaseColor,
                    isLight: relatedShelfIsLight
                )
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        guard viewModel?.acceptsPresentationUpdates != false else { return }
                        pageWidth = proxy.size.width
                    }
                    .onChange(of: proxy.size.width) { _, w in
                        guard viewModel?.acceptsPresentationUpdates != false else { return }
                        pageWidth = w
                    }
            }
        }
        .lumaContentWidth()
        .environment(\.lumaPlayingAccent, heroIconColor)
        .environment(\.colorScheme, albumChromeColorScheme ?? colorScheme)
        .chromeAppearance(albumChromeColorScheme)
        .navigationTitle("")
        .navigationBarTitleDisplayModeInline()
    }

    private var albumChrome: some View {
        albumPage
        #if os(iOS)
        .navigationBarBackButtonHidden(false)
        .toolbarColorScheme(albumNavigationBarColorScheme, for: .navigationBar)
        #else
        .navigationBarBackButtonHidden(true)
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .navigation) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(headerTextColor)
                        .lumaHeroButton(size: 34)
                }
                .buttonStyle(.plain)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: LumaSpacing.xs) {
                    LumaShareButtonWithOptions(
                        itemID: albumId,
                        shareOptions: ShareSettings.shared.makeAlbumOptions(albumName: albumDisplayName),
                        fallbackText: albumShareText,
                        style: .circle(foreground: navigationInk, size: 44)
                    )
                    .buttonStyle(.plain)

                    albumMoreMenu
                }
                .environment(\.colorScheme, albumNavigationBarColorScheme ?? colorScheme)
                .opacity(toolbarRevealed ? 1 : 0)
                .allowsHitTesting(toolbarRevealed)
                .accessibilityHidden(!toolbarRevealed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: toolbarRevealed)
            }
        }
        .alert("Pin Limit Reached", isPresented: $showPinLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(PinError.limitReached.errorDescription ?? "")
        }
        #if os(iOS)
        .background {
            AlbumPresentationLifecycle(
                pageID: "\(albumId)#\(albumNavigationAttempt)",
                onDeparture: { viewModel?.suspendPendingLoad() },
                onReturn: { await viewModel?.resumePendingLoadIfNeeded() },
                chrome: self.tabBarChrome
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            AlbumArtworkTopInsetReader { inset in
                if viewModel?.acceptsPresentationUpdates != false { artworkTopInset = inset }
            }
                .frame(width: 0, height: 0)
        }
        .lumaImmersiveStatusBar(
            colorScheme: albumChromeColorScheme,
            scrolledChromeProgress: navChromeProgress,
            floatingOverArtwork: usesFullBleedArtwork,
            statusBarColorScheme: albumStatusBarColorScheme,
            navigationBarColorScheme: albumNavigationBarColorScheme
        )
        #endif
    }

    var body: some View {
        albumChrome
        // Keyed on connectivity so the list re-loads from the right source when
        // NWPathMonitor flips isOnline — same pattern as AlbumDetailMacOS and
        // PlaylistDetailView. Guarded by the connectivity state actually loaded, so an id change that
        // carries no new value cannot re-run the whole load (see `loadedForOnlineState`).
        .task(id: container?.serverState.isOnline) {
            guard let c = container else { return }
            if viewModel == nil {
                viewModel = AlbumDetailViewModel(
                    albumId: albumId,
                    libraryService: c.libraryService,
                    downloadService: c.downloadService,
                    toastService: c.toastService,
                    serverState: c.serverState,
                    libraryIndex: c.libraryIndexService,
                    streamingSettings: c.streamingSettings
                )
                Logger.ui.debug("[ALBUM-STATE] viewModel created attempt=\(albumNavigationAttempt, privacy: .public) album=\(albumId, privacy: .public)")
            }
            let isOnline = c.serverState.isOnline
            Logger.ui.debug(
                "[ALBUM-PAGE] task start instance=\(pageInstanceID, privacy: .public) attempt=\(albumNavigationAttempt, privacy: .public) album=\(albumId, privacy: .public) online=\(isOnline, privacy: .public) loaded=\(String(describing: loadedForOnlineState), privacy: .public)"
            )
            // SwiftUI restarts .task when a pushed page is uncovered. If optional album-info
            // work was cancelled after tracks appeared, preserve the completed primary load.
            if loadedForOnlineState == nil,
               viewModel?.isPrimaryContentReady == true,
               viewModel?.isOffline == !isOnline {
                loadedForOnlineState = isOnline
            }
            guard loadedForOnlineState != isOnline else { return }
            await viewModel?.load()
            if !Task.isCancelled, viewModel?.acceptsPresentationUpdates == true,
               viewModel?.isPrimaryContentReady == true {
                loadedForOnlineState = isOnline
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: OriginalArtwork.didInstall)) { note in
            if viewModel?.acceptsPresentationUpdates != false, note.object as? String == albumCoverId {
                artworkRevision &+= 1
            }
        }
        .task(id: paletteIdentity) {
            let requestedCoverID = albumCoverId
            await resolveDominantColor(coverArtId: requestedCoverID)
        }
        .onChange(of: viewModel?.isPrimaryContentReady) { _, ready in
            Logger.ui.debug("[ALBUM-STATE] primary-ready=\(ready == true, privacy: .public) attempt=\(albumNavigationAttempt, privacy: .public) album=\(albumId, privacy: .public) loading=\(viewModel?.isLoading == true, privacy: .public)")
            guard ready == true, let trace = openTrace else { return }
            trace.finish(.success)
            openTrace = nil
        }
        .onChange(of: usesDesktopDetail) { _, desktop in
            Logger.ui.debug("[ALBUM-STATE] root=\(desktop ? "desktop" : "compact", privacy: .public) attempt=\(albumNavigationAttempt, privacy: .public) album=\(albumId, privacy: .public)")
        }
        .onChange(of: artworkRevision) { _, revision in
            Logger.ui.debug("[ALBUM-ART] revision=\(revision, privacy: .public) attempt=\(albumNavigationAttempt, privacy: .public) album=\(albumId, privacy: .public) cover=\(albumCoverId, privacy: .public)")
        }
        .onAppear(perform: handleAppear)
        .onChange(of: isPrimaryContentReady) { _, ready in
            if ready { startStagedRevealIfNeeded() }
        }
        .onDisappear {
            Logger.ui.debug("[NAV] album disappear instance=\(pageInstanceID, privacy: .public) attempt=\(albumNavigationAttempt, privacy: .public) album=\(albumId, privacy: .public)")
            revealTask?.cancel()
            revealTask = nil
            openTrace?.finish(.cancelled)
            openTrace = nil
            let closeTrace = DiagnosticsCenter.shared.begin(.albumClose)
            Task { @MainActor in
                await Task.yield()
                closeTrace.finish(Task.isCancelled ? .cancelled : .success)
            }
        }
    }

    private func handleAppear() {
        Logger.ui.debug("[NAV] album appear instance=\(pageInstanceID, privacy: .public) attempt=\(albumNavigationAttempt, privacy: .public) album=\(albumId, privacy: .public)")
        startStagedRevealIfNeeded()
        guard openTrace == nil else { return }
        let trace = DiagnosticsCenter.shared.begin(.albumOpen)
        openTrace = trace
        if viewModel?.isPrimaryContentReady == true {
            trace.finish(.success)
            openTrace = nil
        }
    }

    /// The page is covered by its representative color until the primary payload
    /// is actually ready. Once ready, hero/tracks reveal together (with the track
    /// rows overlapping the hero fade) and the share/more cluster lands last.
    /// This is readiness-based, not a fixed timer: an uncached album never shows
    /// a half-built header while waiting on the network.
    private func startStagedRevealIfNeeded() {
        guard isPrimaryContentReady else { return }
        guard revealTask == nil, !headerRevealed else {
            if !toolbarRevealed {
                revealTask = Task { @MainActor in
                    if !reduceMotion {
                        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                    }
                    toolbarRevealed = true
                }
            }
            return
        }
        revealTask = Task { @MainActor in
            if !reduceMotion {
                withAnimation(.easeOut(duration: 0.24)) {
                    headerRevealed = true
                }
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            } else {
                headerRevealed = true
            }
            guard !Task.isCancelled else { return }
            if reduceMotion {
                toolbarRevealed = true
            } else {
                withAnimation(.easeOut(duration: 0.16)) {
                    toolbarRevealed = true
                }
            }
        }
    }

}
