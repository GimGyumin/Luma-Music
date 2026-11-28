import SwiftUI
import SwiftSonic

struct HomeShelfHeading: View {
    let title: String
    var showsChevron = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesIPadLayout: Bool {
        LumaDashboardLayout.usesIPadLayout(for: horizontalSizeClass)
    }

    private var chevron: some View {
        #if os(macOS)
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
        #else
        Image(systemName: "chevron.right")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
        #endif
    }

    var body: some View {
        HStack(spacing: 8) {
            #if os(macOS)
            // Music's macOS section headings are compact semibold caps above
            // each shelf, not the larger iOS title style.
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            #else
            Text(title).font(.title2.bold()).foregroundStyle(.primary)
            #endif
            if showsChevron && usesIPadLayout {
                chevron
            }
            Spacer(minLength: 0)
            if showsChevron && !usesIPadLayout {
                chevron
            }
        }
        #if os(macOS)
        .frame(minHeight: 24, alignment: .leading)
        #else
        .frame(minHeight: 36, alignment: .leading)
        #endif
        .contentShape(Rectangle())
    }
}

struct HomePlaylistShelf: View {
    let playlists: [Playlist]
    let mixes: [PersonalMix]
    var isLoadingMixes = false
    @Environment(\.appContainer) private var container
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var orderedMixes: [PersonalMix] {
        PlaylistRecommendationPolicy.ordered(mixes)
    }

    private var isIPadLayout: Bool {
        LumaDashboardLayout.usesIPadLayout(for: horizontalSizeClass)
    }

    private var itemWidth: CGFloat {
        isIPadLayout ? LumaDashboardLayout.regularItemSize : PersonalMixCard.cardWidth
    }

    private var itemSpacing: CGFloat {
        isIPadLayout ? LumaDashboardLayout.regularItemSpacing : 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: HomeDestination.libraryPlaylists) {
                HomeShelfHeading(title: String(localized: "Your Playlists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), showsChevron: true)
            }.buttonStyle(.plain)
            if playlists.isEmpty && orderedMixes.isEmpty && !isLoadingMixes {
                Text("Your playlists and personalized mixes appear here.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: itemSpacing) {
                        ForEach(orderedMixes) { mix in
                            NavigationLink(value: HomeDestination.personalMix(mix.kind)) {
                                PersonalMixCard(mix: mix, width: itemWidth)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(playlists) { playlist in
                            NavigationLink(value: HomeDestination.playlist(playlist)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    PlaylistCoverThumbnail(playlistId: playlist.id,
                                        serverId: container?.serverState.activeServer?.id,
                                        coverArtId: playlist.coverArt ?? playlist.id,
                                        title: playlist.name, size: itemWidth)
                                    Text(playlist.name)
                                        .font(isIPadLayout ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                                        .foregroundStyle(.primary).lineLimit(1)
                                    VStack(alignment: .leading, spacing: 2) {
                                        if !isIPadLayout, let date = playlist.changed {
                                            Text(String(localized: "Updated \(date.formatted(.relative(presentation: .named)))", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                        }
                                        Text(LumaCountLabel.tracks(playlist.songCount))
                                    }.font(.caption).foregroundStyle(.secondary)
                                }.frame(width: itemWidth, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

/// One album recommendation based on listening history.
struct HomeListenAgainCard: View {
    let recommendation: AlbumListenAgainRecommendation
    @Environment(\.appContainer) private var container

    private var coverArtID: String {
        container?.libraryIndexService.albumArtworkSnapshot[recommendation.albumId]
            ?? recommendation.coverArtId
    }

    var body: some View {
        HomeEditorialAlbumCard(coverArtID: coverArtID,
            eyebrow: String(localized: "Listen Again", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            title: recommendation.albumTitle, subtitle: recommendation.artistName)
    }
}




struct RecommendedStationsShelf: View {
    let artists: [ArtistID3]
    @Environment(\.appContainer) private var container
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var startingArtistID: String?
    @State private var stationTask: Task<Void, Never>?

    private var isIPadLayout: Bool {
        LumaDashboardLayout.usesIPadLayout(for: horizontalSizeClass)
    }

    private var itemWidth: CGFloat {
        isIPadLayout ? LumaDashboardLayout.regularItemSize : 160
    }

    private var itemSpacing: CGFloat {
        isIPadLayout ? LumaDashboardLayout.regularItemSpacing : 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeShelfHeading(title: String(localized: "Stations for You", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: itemSpacing) {
                    ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
                        Button {
                            startStation(artist)
                        } label: {
                            RecommendedStationCard(artist: artist, index: index, width: itemWidth)
                                .overlay(alignment: .topTrailing) {
                                    if startingArtistID == artist.id {
                                        ProgressView().padding(12).background(.regularMaterial, in: Circle()).padding(8)
                                    }
                                }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .onDisappear { stationTask?.cancel(); startingArtistID = nil }
    }

    private func startStation(_ artist: ArtistID3) {
        guard let container, startingArtistID != artist.id else { return }
        stationTask?.cancel()
        startingArtistID = artist.id
        stationTask = Task { @MainActor in
            defer { if !Task.isCancelled, startingArtistID == artist.id { startingArtistID = nil } }
            guard let snapshot = await GeneratedPlaylistSource.artistStation(artist)
                .snapshot(in: container, forceRefresh: false), !Task.isCancelled else { return }
            guard !snapshot.tracks.isEmpty else {
                container.toastService.showError("No songs available for this station.")
                return
            }
            do { try await container.playerService.play(tracks: snapshot.tracks.shuffled(), startIndex: 0) }
            catch {
                if !Task.isCancelled { container.toastService.showError(error.localizedDescription) }
            }
        }
    }
}

struct RecommendedStationCard: View {
    let artist: ArtistID3
    let index: Int
    var width: CGFloat = 160
    var body: some View {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    LinearGradient(colors: index.isMultiple(of: 2)
                                        ? [Color(hex: "#17465B"), Color(hex: "#2698AB")]
                                        : [Color(hex: "#1B3A6B"), Color(hex: "#377EEC")],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
                                    CoverArtView(id: artist.coverArt ?? artist.id, size: 280, placeholderSystemImage: "person.fill")
                                        .frame(width: width * 0.72, height: width * 0.72).clipShape(Circle())
                                }
                                .frame(width: width, height: width)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(GeneratedPlaylistSource.artistStation(artist).title)
                                    .font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                Text("Radio Station").font(.subheadline).foregroundStyle(.secondary)
                            }.frame(width: width, alignment: .leading)
    }
}

struct MoodPlaylistShelf: View {
    private let kinds: [PersonalMixKind] = [.focus, .chill, .getUp]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isIPadLayout: Bool {
        LumaDashboardLayout.usesIPadLayout(for: horizontalSizeClass)
    }

    private var itemWidth: CGFloat {
        isIPadLayout ? LumaDashboardLayout.regularItemSize : 140
    }

    private var itemSpacing: CGFloat {
        isIPadLayout ? LumaDashboardLayout.regularItemSpacing : 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeShelfHeading(title: String(localized: "Moods", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: itemSpacing) {
                    ForEach(kinds, id: \.self) { kind in
                        NavigationLink(value: HomeDestination.personalMix(kind)) {
                            MoodPlaylistCard(kind: kind, width: itemWidth)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct MoodPlaylistCard: View {
    let kind: PersonalMixKind
    var width: CGFloat = 140
    var body: some View {
                            VStack(alignment: .leading, spacing: 8) {
                                PersonalMixArtwork(kind: kind, showsTitle: false, showsSymbol: true)
                                    .frame(width: width, height: width)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(String(localized: String.LocalizationValue(kind.localizationKey), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                    .font(.body.weight(.semibold)).foregroundStyle(.primary)
                            }.frame(width: width, alignment: .leading)
    }
}

struct SmartShuffleBanner: View {
    let albums: [AlbumID3]
    var isLoading = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 4) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Smart Shuffle", systemImage: "shuffle").font(.headline)
                    Text("Rediscover Your Library").font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text("A new mix, every time").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    HStack(spacing: 8) {
                        if isLoading { ProgressView().tint(.white) }
                        else { Image(systemName: "play.fill") }
                        Text("Shuffle").font(.headline)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.white.opacity(0.18), in: Capsule())
                }.frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    ForEach(Array(albums.prefix(3).enumerated()), id: \.element.id) { index, album in
                        CoverArtView(id: album.coverArt ?? album.id, size: 240)
                            .frame(width: 82, height: 82)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .rotationEffect(.degrees(Double(index - 1) * 12))
                            .offset(x: CGFloat(index - 1) * 6, y: CGFloat(index - 1) * 30)
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
                    }
                }.frame(width: 100, height: 150)
            }
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 202, alignment: .leading)
            .background(LinearGradient(colors: [Color(hex: "#1B3A6B"), Color(hex: "#377EEC")], startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

/// Portrait artwork with an integrated caption, shared by recent additions and listening history.
struct HomeEditorialAlbumCard: View {
    let coverArtID: String
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        HomeFeaturedCard(eyebrow: eyebrow, title: title, subtitle: subtitle) {
            CoverArtView(id: coverArtID, size: 800, fillsFrame: true)
        }
    }
}

private struct HomeFeaturedCard<Artwork: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder let artwork: () -> Artwork
    @Environment(\.dynamicTypeSize) private var typeSize

    #if os(macOS)
    // Matches the measured 236 pt Music editorial poster width at wide sizes.
    private let width: CGFloat = 236
    #else
    private let width: CGFloat = 262
    #endif

    var body: some View {
        let height = typeSize.isAccessibilitySize ? width * 1.75 : width * 4 / 3
        ZStack(alignment: .bottomLeading) {
            artwork()
                .frame(width: width, height: height)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.18), .black.opacity(0.68)],
                           startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(eyebrow).foregroundStyle(.white.opacity(0.78))
                Text(title).fontWeight(.semibold).lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
                Text(subtitle).foregroundStyle(.white.opacity(0.88)).lineLimit(2)
            }
            .font(.body)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                Rectangle().fill(.ultraThinMaterial)
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
            }
        }
        .foregroundStyle(.white)
        .frame(width: width, height: height)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}

struct HomeFeaturedAlbumsShelf: View {
    let listenAgain: AlbumListenAgainRecommendation?
    let recentlyAdded: [AlbumID3]
    let featuredMix: PersonalMix?
    @Namespace private var albumNamespace
    @Environment(\.appContainer) private var container

    private var featuredSpacing: CGFloat {
        #if os(macOS)
        14
        #else
        12
        #endif
    }

    var body: some View {
        let recentAlbum = recentlyAdded.first { $0.id != listenAgain?.albumId } ?? recentlyAdded.first
        if listenAgain != nil || recentAlbum != nil || featuredMix != nil {
            VStack(alignment: .leading, spacing: 16) {
                HomeShelfHeading(title: String(localized: "Top Picks", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: featuredSpacing) {
                        if let listenAgain {
                            NavigationLink(value: HomeDestination.albumById(id: listenAgain.albumId,
                                name: listenAgain.albumTitle, subtitle: listenAgain.artistName,
                                coverArtId: listenAgain.coverArtId)) {
                                HomeListenAgainCard(recommendation: listenAgain)
                            }.buttonStyle(.plain)
                        }
                        if let album = recentAlbum {
                            AlbumNavigationLink(album: album, namespace: albumNamespace) { sourceID, namespace in
                                HomeEditorialAlbumCard(
                                    coverArtID: container?.libraryIndexService.albumArtworkSnapshot[album.id] ?? album.coverArt ?? album.id,
                                    eyebrow: String(localized: "Recently Added", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                    title: album.name, subtitle: album.artist ?? "")
                                    .lumaMatchedTransitionSource(id: sourceID, in: namespace)
                            }.buttonStyle(.plain).albumLongPressMenu(album)
                        }
                        if let featuredMix {
                            NavigationLink(value: HomeDestination.personalMix(featuredMix.kind)) {
                                HomeFeaturedCard(
                                    eyebrow: String(localized: "Made for you", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                    title: String(localized: String.LocalizationValue(featuredMix.kind.localizationKey), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                    subtitle: LumaCountLabel.tracks(featuredMix.tracks.count)
                                ) {
                                    PersonalMixArtwork(kind: featuredMix.kind)
                                        .aspectRatio(1, contentMode: .fit)
                                        .frame(maxHeight: .infinity, alignment: .top)
                                        .background(Color(hex: featuredMix.kind.gradientHexes.bottom))
                                        .accessibilityHidden(true)
                                }
                            }.buttonStyle(.plain)
                        }
                    }.scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
            }
        }
    }
}
