// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import SwiftData
import AppIntents
import OSLog

struct ArtistDetailView: View {
    let artist: ArtistID3

    @Environment(\.appContainer) private var container
    @State private var viewModel: ArtistDetailViewModel?
    @State private var selectedOutOfLibraryArtist: SimilarArtistRecommendation?
    @Query private var artistFavoriteMatches: [FavoriteRecord]
    @AppStorage("coverArtUploadVersion") private var coverVersion = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var portrait: ArtistPortraitTreatment?
    @State private var sharpPortrait: PlatformImage?
    @State private var collapsed = false
    private static let portraitCache: NSCache<NSString, ArtistPortraitTreatment> = {
        let cache = NSCache<NSString, ArtistPortraitTreatment>()
        cache.countLimit = 24
        return cache
    }()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    private let heroHeight: CGFloat = 540
    @State private var showBiographySheet = false
    @State private var showPinLimitAlert = false
    /// Identity of this page instance: a repeated `[ARTIST-PAGE] task start` with a new id means the
    /// page was destroyed and re-created while it was on top (the back-gesture regression signature).
    @State private var pageInstanceID = UUID()
    @Namespace private var albumZoomNamespace
    @State private var similarArtistRouteToken = UUID()

    init(artist: ArtistID3) {
        self.artist = artist
        let itemId = artist.id
        let type = FavoriteType.artist.rawValue
        _artistFavoriteMatches = Query(filter: #Predicate<FavoriteRecord> {
            $0.itemId == itemId && $0.itemType == type
        })
    }

    init(artistId: String, artistName: String, coverArtId: String?) {
        self.init(artist: ArtistID3(id: artistId, name: artistName, coverArt: coverArtId))
    }

    private var isArtistFavorite: Bool {
        guard let serverId = container?.serverState.activeServer?.id else { return false }
        return artistFavoriteMatches.contains { $0.serverId == serverId }
    }
    private var isOnline: Bool { container?.serverState.isOnline == true }

    // MARK: Theming — cover extract → refined Apple Music atmosphere.
    private var atmosphere: AlbumAtmosphere {
        AlbumAtmosphere.from(
            dominantColor: portrait?.color ?? .clear,
            appearance: AlbumAtmosphere.appearance(
                colorScheme: colorScheme,
                increaseContrast: colorSchemeContrast == .increased
            )
        )
    }
    private var portraitKey: String {
        let token = container?.artworkImageCache.palettePreparationToken(for: heroCoverArtId) ?? heroCoverArtId
        return "\(artist.id)#\(coverVersion)#\(token)"
    }
    private var navigationScheme: ColorScheme? {
        guard !collapsed, let portrait else { return atmosphere.preferredColorScheme }
        return LumaColors.prefersLightControl(on: portrait.navigationColor) ? .dark : .light
    }
    /// Lets Siri AI resolve “this artist” while the artist page is on screen.
    private var onscreenEntityIdentifier: EntityIdentifier? {
        guard #available(iOS 27.0, macOS 27.0, *) else { return nil }
        return OnscreenEntityAnnotation.artistIdentifier(
            id: artist.id,
            name: artist.name,
            serverId: container?.serverState.activeServer?.id
        )
    }

    private var bodyColor: Color { atmosphere.isThemed ? atmosphere.pageColor : systemBackgroundColor }
    private var headerTextColor: Color { atmosphere.contentColor }
    private var headerSecondaryColor: Color { atmosphere.secondaryContentColor }
    private var systemBackgroundColor: Color {
        #if canImport(UIKit)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }
    /// The artist photo (server artist cover) drives the hero; falls back to the latest release's cover, then
    /// the artist id (placeholder glyph).
    private var heroCoverArtId: String {
        if let cover = viewModel?.artist?.coverArt, !cover.isEmpty { return cover }
        if let cover = artist.coverArt, !cover.isEmpty { return cover }
        if let latest = latestReleaseCoverArtId { return latest }
        return artist.id
    }
    /// Cover of the most recent release (max year) — hero fallback + the featured release (Gate 2).
    private var latestReleaseCoverArtId: String? {
        viewModel.flatMap { latestRelease($0) }?.coverArt
    }

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: LumaSpacing.l)
    ]

    var body: some View {
        Group {
            if let vm = viewModel {
                if let error = vm.error, vm.artist == nil {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "Unable to Load Artist",
                        subtitle: error.displayMessage,
                        action: .init(label: "Retry") { Task { await vm.load() } }
                    )
                } else if vm.artist == nil {
                    skeletonGrid
                } else {
                    let albums = vm.artist?.album ?? []
                    if albums.isEmpty {
                        EmptyStateView(
                            systemImage: "square.stack",
                            title: "No Albums",
                            subtitle: "This artist has no albums in the library."
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                artistHero(vm: vm)
                                LazyVStack(alignment: .leading, spacing: LumaSpacing.xl) {
                                    if let featured = latestRelease(vm) {
                                        featuredReleaseSection(featured)
                                    }
                                    if vm.isLoadingTopSongs {
                                        topSongsSkeleton
                                    } else if !vm.topSongs.isEmpty {
                                        topSongsSection(vm: vm)
                                    }
                                    albumsSections
                                    if vm.isLoadingSimilarArtists || !vm.similarArtists.isEmpty {
                                        similarArtistsSection(vm: vm)
                                    }
                                }
                                .padding(.vertical, LumaSpacing.l)
                                .frame(maxWidth: .infinity)
                                // Force the themed scheme so the shared cells contrast the tinted body.
                                .environment(\.colorScheme, atmosphere.preferredColorScheme ?? colorScheme)
                            }
                        }
                        .onScrollGeometryChange(for: Bool.self) { geometry in
                            geometry.contentOffset.y + geometry.contentInsets.top > heroHeight * 0.68
                        } action: { _, value in collapsed = value }
                        .chromeAppearance(navigationScheme)
                        .ignoresSafeArea(.container, edges: .top)
                        .lumaSoftTopScrollEdge(isVisible: collapsed)
                        .lumaStatusBarScrim(isLightPage: atmosphere.isLight, isEnabled: collapsed)
                        // Use the same solid color as the final stop of the portrait mask.
                        .background { bodyColor.ignoresSafeArea() }
                        .refreshable { await vm.reloadAll() }
                        .miniPlayerBottomMargin()
                        .transition(.opacity)
                    }
                }
            } else {
                skeletonGrid
            }
        }
        .lumaContentReveal(isReady: viewModel?.artist != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appEntityIdentifier(onscreenEntityIdentifier)
        .background { bodyColor.ignoresSafeArea() }
        .overlay {
            if viewModel == nil || (viewModel?.artist == nil && viewModel?.error == nil) {
                bodyColor.ignoresSafeArea()
                    .overlay { ProgressView().tint(headerTextColor) }
            }
        }
        .task(id: portraitKey) { await loadPortrait(key: portraitKey, coverID: heroCoverArtId) }
        .navigationTitle("")
        .navigationBarTitleDisplayModeInline()
        #if os(iOS)
        .lumaImmersiveStatusBar(colorScheme: navigationScheme, scrolledChromeProgress: collapsed ? 1 : 0,
                                floatingOverArtwork: true)
        // Let NavigationStack retain its own interactive pop recognizers.
        .navigationBarBackButtonHidden(false)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                artistMoreMenu
                    .tint(navigationScheme.map { $0 == .dark ? Color.white : .black } ?? headerTextColor)
            }
        }
        .alert(String(localized: "Pin Limit Reached", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), isPresented: $showPinLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(PinError.limitReached.errorDescription ?? "")
        }
        .task {
            Logger.ui.debug(
                "[ARTIST-PAGE] task start instance=\(pageInstanceID, privacy: .public) id=\(artist.id, privacy: .public)"
            )
            guard let c = container else { return }
            if viewModel == nil {
                viewModel = ArtistDetailViewModel(
                    artistId: artist.id,
                    libraryService: c.libraryService,
                    recommendationService: c.recommendationService,
                    imageResolver: c.externalArtistImageResolver
                )
            }
            // Skip network when popping back from an album — VM already has warm data.
            await viewModel?.load()
            await viewModel?.loadTopSongs()
            await viewModel?.loadSimilarArtists()
        }
        .onAppear {
            Logger.ui.debug("[NAV] artist appear instance=\(pageInstanceID, privacy: .public) artist=\(artist.id, privacy: .public)")
        }
        .onDisappear {
            Logger.ui.debug("[NAV] artist disappear instance=\(pageInstanceID, privacy: .public) artist=\(artist.id, privacy: .public)")
        }
        .sheet(item: $selectedOutOfLibraryArtist) { rec in
            OutOfLibraryArtistSheet(
                artist: rec,
                imageURL: viewModel?.outOfLibraryArtistImages[rec.id] ?? nil,
                providers: container?.externalProvidersStore.load() ?? []
            )
        }
        // Presented as a sheet, not `.navigationDestination(isPresented:)`: declaring an isPresented
        // destination from inside a page that is itself a pushed path entry desyncs the stack (the pushed
        // page can be re-created or the back button stops responding). The album page's description sheet
        // uses the same shape.
        .sheet(isPresented: $showBiographySheet) {
            NavigationStack {
                ArtistInfoView(
                    artistName: artist.name,
                    coverArtId: heroCoverArtId,
                    biography: viewModel?.artistBiography,
                    genres: viewModel?.primaryGenres ?? [],
                    musicBrainzId: viewModel?.musicBrainzId
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                            showBiographySheet = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Hero

    /// Immersive artist hero: photo full-bleed + name + Info / Play / Favorite over it.
    private func artistHero(vm: ArtistDetailViewModel) -> some View {
        let albums = vm.artist?.album ?? []
        let count = albums.count
        return ZStack(alignment: .bottom) {
            artistBackdrop
            VStack(spacing: LumaSpacing.s) {
                Text(artist.name)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundStyle(headerTextColor)
                    .multilineTextAlignment(.center)
                Text(LumaCountLabel.albums(count))
                    .font(.lumaCaption)
                    .foregroundStyle(headerSecondaryColor)
                    .padding(.bottom, LumaSpacing.xs)
                HStack(spacing: LumaSpacing.l) {
                    // Info — mirrors the favorite star on the right so Play stays centred.
                    Button {
                        HapticFeedback.light.trigger()
                        showBiographySheet = true
                    } label: {
                        Image(systemName: "info")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(headerTextColor)
                            .lumaGlassButton(size: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "About", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

                    // High-contrast Play disc with the glyph cut out of its center.
                    Button {
                        Task { await playAll() }
                    } label: {
                        Circle()
                            .fill(headerTextColor)
                            .frame(width: 66, height: 66)
                            .overlay {
                                // Reveal the themed hero through the glyph.
                                Image(systemName: "play.fill")
                                    .font(.system(size: 26, weight: .bold))
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isPlayLoading || albums.isEmpty)
                    .accessibilityLabel(String(localized: "Play", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .accessibilityHint(String(localized: "Shuffles this artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

                    // Smaller favorite star.
                    Button {
                        HapticFeedback.light.trigger()
                        let wasFavorite = isArtistFavorite
                        Task {
                            guard let container else { return }
                            do {
                                if wasFavorite {
                                    try await container.favoritesService.unstar(itemType: .artist, itemId: artist.id)
                                } else {
                                    try await container.favoritesService.star(itemType: .artist, itemId: artist.id)
                                }
                            } catch {
                                container.toastService.showError(error.localizedDescription)
                            }
                        }
                    } label: {
                        Image(systemName: isArtistFavorite ? "star.fill" : "star")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isArtistFavorite ? .white : headerTextColor)
                            .lumaGlassButton(
                                size: 44,
                                tint: isArtistFavorite ? Color.lumaAccent.opacity(0.78) : nil
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(container?.serverState.activeServer == nil)
                    .accessibilityLabel(
                        isArtistFavorite
                            ? String(localized: "Remove from Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                            : String(localized: "Add to Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                    )
                }
            }
            .padding(.horizontal, LumaSpacing.l)
            .padding(.bottom, LumaSpacing.l)
        }
        .frame(minHeight: heroHeight, alignment: .bottom)
    }

    private var artistBackdrop: some View {
        GeometryReader { geo in
            let y = geo.frame(in: .scrollView).minY
            let stretch = max(0, y)
            let height = geo.size.height + stretch
            let progress = min(1, max(0, -y / max(1, geo.size.height * 0.72)))
            let blend = progress * progress * (3 - 2 * progress)
            let shift = reduceMotion ? 0 : min(max(0, -y) * 0.12, geo.size.height * 0.09)
            ZStack {
                if let sharpPortrait {
                    Image(platformImage: sharpPortrait).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: height)
                        .offset(y: shift)
                    if let blurred = portrait?.blurred {
                        Image(decorative: blurred, scale: 1).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: height)
                            .offset(y: shift)
                            .mask(LinearGradient(stops: [
                                .init(color: .black.opacity(0.65 * blend), location: 0),
                                .init(color: .black.opacity(0.65 * blend), location: 0.50 - 0.26 * blend),
                                .init(color: .black, location: 0.83 - 0.15 * blend)
                            ], startPoint: .top, endPoint: .bottom))
                    }
                }
                LinearGradient(stops: [.init(color: bodyColor.opacity(0), location: 0.51 - 0.12 * blend),
                                       .init(color: bodyColor, location: 0.82 - 0.06 * blend)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: height)
            .clipped()
            .offset(y: -stretch)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func loadPortrait(key: String, coverID: String) async {
        let cache = container?.artworkImageCache
        portrait = Self.portraitCache.object(forKey: key as NSString)
        sharpPortrait = cache?.cachedImage(for: coverID, tier: .hero)
        let image = await cache?.load(coverArtId: coverID, tier: .hero)
        guard !Task.isCancelled, key == portraitKey, let image else { return }
        sharpPortrait = image
        guard portrait == nil else { return }
        let result = await Task.detached(priority: .utility) { AlbumColorAnalyzer.artistPortrait(from: image) }.value
        guard !Task.isCancelled, key == portraitKey, let result else { return }
        Self.portraitCache.setObject(result, forKey: key as NSString)
        withAnimation(reduceMotion ? nil : LumaAnimation.theme) { portrait = result }
    }

    // MARK: - Body sections (Gate 2)

    /// The most recent release — featured + the hero fallback cover.
    private func latestRelease(_ vm: ArtistDetailViewModel) -> AlbumID3? {
        vm.latestRelease
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(String(localized: String.LocalizationValue(title), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            .font(.lumaSectionTitle)
            .foregroundStyle(headerTextColor)
            .padding(.horizontal, LumaSpacing.l)
    }

    /// Featured (latest) release — a prominent card, Apple-Music style.
    private func featuredReleaseSection(_ album: AlbumID3) -> some View {
        VStack(alignment: .leading, spacing: LumaSpacing.s) {
            sectionHeader("Latest Release")
            AlbumNavigationLink(album: album, namespace: albumZoomNamespace, sourceContext: "featured") { sourceID, namespace in
                HStack(spacing: LumaSpacing.m) {
                    CoverArtView(id: album.coverArt ?? album.id, size: 260, tier: .hero)
                        .frame(width: 120, height: 120)
                        .lumaMatchedTransitionSource(id: sourceID, in: namespace)
                        .clipShape(RoundedRectangle(cornerRadius: LumaCornerRadius.standard, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        if let date = ReleaseDateFormatting.displayDate(
                            from: album.releaseDate ?? album.originalReleaseDate,
                            fallbackYear: album.year
                        ) {
                            Text(verbatim: date)
                                .font(.lumaCaption)
                                .foregroundStyle(headerSecondaryColor)
                        }
                        Text(album.name)
                            .font(.lumaCellTitle)
                            .foregroundStyle(headerTextColor)
                            .lineLimit(2)
                        Text(LumaCountLabel.songs(album.songCount))
                            .font(.lumaCaption)
                            .foregroundStyle(headerSecondaryColor)
                    }
                    Spacer(minLength: 0)
                }
                .padding(LumaSpacing.m)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: LumaCornerRadius.large, style: .continuous))
                // Make the WHOLE card (incl. the Spacer / background) tappable — a styled label in a plain
                // NavigationLink otherwise only registers taps on the opaque content (cover/text), not the gaps.
                .contentShape(RoundedRectangle(cornerRadius: LumaCornerRadius.large, style: .continuous))
                .padding(.horizontal, LumaSpacing.l)
            }
            .buttonStyle(.plain)
            .albumLongPressMenu(album)
        }
    }

    /// Top (most-played) songs ranking.
    private func topSongsSection(vm: ArtistDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: LumaSpacing.s) {
            sectionHeader("Top Songs")
            VStack(spacing: 0) {
                ForEach(Array(vm.topSongs.prefix(5).enumerated()), id: \.element.id) { index, song in
                    Button {
                        Task { try? await container?.playerService.play(tracks: vm.topSongs, startIndex: index) }
                    } label: {
                        SongRow(
                            song: song,
                            index: index + 1,
                            showCoverArt: true,
                            showArtist: false,
                            titleColor: headerTextColor,
                            secondaryColor: headerSecondaryColor
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, LumaSpacing.l)
        }
    }

    private var topSongsSkeleton: some View {
        VStack(alignment: .leading, spacing: LumaSpacing.s) {
            sectionHeader("Top Songs")
            VStack(spacing: LumaSpacing.m) {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: LumaSpacing.m) {
                        SkeletonBlock(width: 44, height: 44, cornerRadius: LumaCornerRadius.standard)
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBlock(width: 180, height: 13, cornerRadius: 4)
                            SkeletonBlock(width: 120, height: 11, cornerRadius: 4)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, LumaSpacing.l)
        }
        .allowsHitTesting(false)
    }

    /// Albums grouped by release type (Albums, Singles & EPs, Compilations, Live Album).
    private var albumsSections: some View {
        ForEach((viewModel?.albumSections ?? []).filter { !$0.1.isEmpty }, id: \.0) { section, items in
            VStack(alignment: .leading, spacing: LumaSpacing.s) {
                sectionHeader(section.rawValue)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: LumaSpacing.m) {
                        ForEach(items) { album in
                            AlbumNavigationLink(album: album, namespace: albumZoomNamespace, sourceContext: section.rawValue) { sourceID, namespace in
                                VStack(alignment: .leading, spacing: LumaSpacing.xs) {
                                    CoverArtView(id: album.coverArt ?? album.id, size: 480, tier: .hero, contentMode: .fit)
                                        .frame(width: 160, height: 160)
                                        .lumaMatchedTransitionSource(id: sourceID, in: namespace)
                                        .clipShape(RoundedRectangle(cornerRadius: LumaCornerRadius.large, style: .continuous))
                                    Text(album.name)
                                        .font(.lumaCellTitle)
                                        .foregroundStyle(headerTextColor)
                                        .lineLimit(1)
                                    if let year = ReleaseDateFormatting.yearOnly(from: album.releaseDate ?? album.originalReleaseDate) ?? album.year {
                                        Text(verbatim: "\(year)")
                                            .font(.lumaCaption)
                                            .foregroundStyle(headerSecondaryColor)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: 160, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .albumLongPressMenu(album)
                        }
                    }
                    .padding(.horizontal, LumaSpacing.l)
                }
            }
        }
    }

    /// Legacy flat albums section — kept for reference, replaced by albumsSections.
    private func albumsSection(_ albums: [AlbumID3]) -> some View {
        VStack(alignment: .leading, spacing: LumaSpacing.s) {
            sectionHeader("Albums")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: LumaSpacing.m) {
                    // Most recent first (albums without a date sort last).
                    ForEach(ArtistAlbumCategorizer.sortedByNewest(albums)) { album in
                        AlbumNavigationLink(album: album, namespace: albumZoomNamespace, sourceContext: "all") { sourceID, namespace in
                            VStack(alignment: .leading, spacing: LumaSpacing.xs) {
                                CoverArtView(id: album.coverArt ?? album.id, size: 480, tier: .hero)
                                    .frame(width: 160, height: 160)
                                    .lumaMatchedTransitionSource(id: sourceID, in: namespace)
                                    .clipShape(RoundedRectangle(cornerRadius: LumaCornerRadius.large, style: .continuous))
                                Text(album.name)
                                    .font(.lumaCellTitle)
                                    .foregroundStyle(headerTextColor)
                                    .lineLimit(1)
                                if let year = album.year {
                                    Text(verbatim: "\(year)")
                                        .font(.lumaCaption)
                                        .foregroundStyle(headerSecondaryColor)
                                }
                            }
                            .frame(width: 160, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, LumaSpacing.l)
            }
        }
    }

    private func playAll() async {
        guard let c = container else { return }
        viewModel?.isPlayLoading = true
        defer { viewModel?.isPlayLoading = false }
        do {
            let tracks = try await c.libraryService.fetchAllTracks(forArtistID: artist.id)
            try await c.playerService.play(tracks: tracks.shuffled(), startIndex: 0)
        } catch LumaError.artistTracksUnavailable {
            c.toastService.showError("Unable to load artist tracks. Please check your connection and try again.")
        } catch {
            c.toastService.showError("Playback failed. Please try again.")
        }
    }

    // MARK: - More menu

    private var isArtistPinned: Bool {
        container?.pinService.isPinned(itemType: .artist, itemId: artist.id) == true
    }

    @ViewBuilder
    private var artistMoreMenu: some View {
        Menu {
            Button {
                playInstantMix(container: container, itemID: artist.id, source: .artist)
            } label: {
                Label(String(localized: "Instant Mix", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "wand.and.stars")
            }
            .disabled(!isOnline)

            Divider()

            if isArtistPinned {
                Button {
                    HapticFeedback.light.trigger()
                    container?.pinService.unpin(itemType: .artist, itemId: artist.id)
                } label: {
                    Label(String(localized: "Unpin from Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "pin.slash")
                }
            } else {
                Button {
                    pinCurrentArtist()
                } label: {
                    Label(String(localized: "Pin to Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "pin")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
        }
        .menuOrder(.fixed)
        .accessibilityLabel(String(localized: "More options", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }

    private func pinCurrentArtist() {
        guard let serverId = container?.serverState.activeServer?.id,
              let pin = container?.pinService else { return }
        do {
            try pin.pin(
                itemType: .artist,
                itemId: artist.id,
                displayName: viewModel?.artist?.name ?? artist.name,
                displaySubtitle: "",
                coverArtId: heroCoverArtId,
                serverId: serverId
            )
            HapticFeedback.success.trigger()
            container?.toastService.showConfirmation(String(localized: "Pinned to Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } catch PinError.limitReached {
            HapticFeedback.warning.trigger()
            showPinLimitAlert = true
        } catch {}
    }

    private var skeletonGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: LumaSpacing.l) {
                ForEach(0..<6, id: \.self) { _ in SkeletonAlbumCard() }
            }
            .padding(LumaSpacing.l)
        }
    }

    // MARK: - Similar Artists Section

    @ViewBuilder
    private func similarArtistsSection(vm: ArtistDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: LumaSpacing.s) {
            Text("Similar Artists")
                .font(.lumaSectionTitle)
                .padding(.horizontal, LumaSpacing.m)

            if vm.isLoadingSimilarArtists {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: LumaSpacing.m) {
                        ForEach(0..<8, id: \.self) { _ in
                            VStack(spacing: LumaSpacing.xs) {
                                SkeletonBlock(width: 64, height: 64, cornerRadius: 32)
                                SkeletonBlock(width: 72, height: 10)
                            }
                            .frame(width: 80)
                        }
                    }
                    .padding(.horizontal, LumaSpacing.m)
                }
                .allowsHitTesting(false)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: LumaSpacing.m) {
                        ForEach(vm.similarArtists) { rec in
                            Group {
                                if rec.inLibrary {
                                    DetailNavigationLink(destination: HomeDestination.artistPush(id: rec.id, name: rec.name,
                                                                                     coverArtId: nil, token: similarArtistRouteToken)) {
                                        SimilarArtistCell(
                                            recommendation: rec,
                                            externalImageURL: vm.outOfLibraryArtistImages[rec.id] ?? nil,
                                            onOutOfLibraryTap: { selectedOutOfLibraryArtist = rec }
                                        )
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    SimilarArtistCell(
                                        recommendation: rec,
                                        externalImageURL: vm.outOfLibraryArtistImages[rec.id] ?? nil,
                                        onOutOfLibraryTap: { selectedOutOfLibraryArtist = rec }
                                    )
                                }
                            }
                            .frame(width: 80)
                        }
                    }
                    .padding(.horizontal, LumaSpacing.m)
                }
            }
        }
    }
}

// MARK: - Out-of-library artist sheet

struct OutOfLibraryArtistSheet: View {
    let artist: SimilarArtistRecommendation
    let imageURL: URL?
    let providers: [ExternalReleaseProvider]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LumaSpacing.l) {
                    ExternalCoverView(url: imageURL) {
                        ArtistPlaceholderView(name: artist.name, size: 120)
                    }
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                    .padding(.top, LumaSpacing.l)

                    VStack(spacing: LumaSpacing.xs) {
                        Text(artist.name)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)

                        Text("Not in your library")
                            .font(.lumaCaption)
                            .foregroundStyle(.secondary)
                    }

                    externalLinksSection
                }
                .padding(LumaSpacing.l)
            }
            .navigationTitle(artist.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var externalLinksSection: some View {
        VStack(spacing: LumaSpacing.s) {
            if !providers.isEmpty {
                ForEach(providers) { provider in
                    if let url = provider.buildURL(artistName: artist.name, albumTitle: "") {
                        externalLinkButton(title: "View on \(provider.name)", url: url, secondary: false)
                    }
                }
            }

            if let mbid = artist.mbid {
                if let lbURL = URL(string: "https://listenbrainz.org/artist/\(mbid)/") {
                    externalLinkButton(
                        title: "View on ListenBrainz",
                        url: lbURL,
                        secondary: !providers.isEmpty
                    )
                }
                if let mbURL = URL(string: "https://musicbrainz.org/artist/\(mbid)") {
                    externalLinkButton(
                        title: "View on MusicBrainz",
                        url: mbURL,
                        secondary: !providers.isEmpty
                    )
                }
            }
        }
        .padding(.horizontal, LumaSpacing.l)
    }

    private func externalLinkButton(title: String, url: URL, secondary: Bool) -> some View {
        Button {
            ExternalLinkOpener.open(url)
        } label: {
            HStack {
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
            }
            .font(.lumaCellTitle)
            .padding(LumaSpacing.m)
            .frame(maxWidth: .infinity)
            .background(secondary
                ? Color.secondary.opacity(0.08)
                : Color.lumaAccent.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: LumaCornerRadius.standard, style: .continuous))
            .foregroundStyle(secondary ? Color.secondary : Color.lumaAccent)
        }
        .buttonStyle(.plain)
    }
}
