// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

/// Home uses the user's playlists and listening history, with one horizontal row per section.
struct DashboardHomeView: View {
    @Environment(\.appContainer) private var container
    @State private var vm: DiscoverViewModel?
    @State private var loadedServerID: String?
    @State private var listenAgain: AlbumListenAgainRecommendation?
    @State private var featuredMixOrder: [PersonalMixKind] = Self.featuredMixKinds
    @State private var songToAddToPlaylist: DisplayableSong?
    @State private var isHeaderScrolled = false
    private var isOnline: Bool { container?.serverState.isOnline != false }
    private var homeHorizontalPadding: CGFloat {
        #if os(macOS)
        32
        #else
        16
        #endif
    }

    private static let featuredMixKinds: [PersonalMixKind] = [.getUp, .heavyRotation, .newMusic, .essentials]

    private var featuredMix: PersonalMix? {
        guard let vm, vm.personalMixesLoaded else { return nil }
        for kind in featuredMixOrder {
            if let mix = vm.personalMixes.first(where: { $0.kind == kind && !$0.tracks.isEmpty }) {
                return mix
            }
        }
        return nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                // Music's Home owns a large page header inside the scroll content;
                // the macOS shell hides the window toolbar for this root page.
                #if os(macOS)
                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .font(.system(size: 26, weight: .bold))
                        .symbolRenderingMode(.monochrome)
                    Text(String(localized: "Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.system(size: 28, weight: .bold))
                }
                .padding(.top, 8)
                #endif

                let featuredMix = self.featuredMix
                if let feed = container?.homeDiscoveryFeed {
                    HomeFeaturedAlbumsShelf(listenAgain: listenAgain,
                        recentlyAdded: feed.recentlyAdded, featuredMix: featuredMix)
                }
                if let vm {
                    albumShelf("Recently Played", albums: vm.recentlyPlayed)
                }
                if let feed = container?.homeDiscoveryFeed {
                    HomePlaylistShelf(
                        playlists: feed.playlists,
                        mixes: (vm?.personalMixes ?? []).filter { $0.kind != featuredMix?.kind },
                        isLoadingMixes: vm?.personalMixesLoaded != true
                    )
                    if !feed.favoriteSongs.isEmpty {
                        favoriteSongs(feed.favoriteSongs)
                    }
                }
                if let vm {
                    if vm.isErrorState {
                        EmptyStateView(systemImage: "wifi.exclamationmark", title: "Unable to Load",
                            subtitle: "Check your connection and try again.",
                            action: .init(label: "Retry") { Task { await reload(forceRefresh: true) } })
                    } else if vm.isInitialLoading {
                        EmptyView()
                    } else {
                        albumShelf("In Heavy Rotation", albums: vm.mostPlayed)
                        albumShelf("Rediscover", albums: vm.suggestedSelection)
                        if let feed = container?.homeDiscoveryFeed {
                            albumShelf("Recently Added from Your Artists", albums: feed.recentAlbumsFromYourArtists(vm.mostPlayed))
                            albumShelf("Recently Added", albums: feed.recentlyAdded)
                            ForEach(HomeDiscoveryFeed.genreShelves(from: feed.recentlyAdded + vm.mostPlayed + vm.suggestedSelection), id: \.title) { shelf in
                                albumShelf(shelf.title, albums: shelf.albums, localized: false)
                            }
                        }
                        MoodPlaylistShelf()
                    }
                } else { EmptyView() }
            }
            .padding(.horizontal, homeHorizontalPadding)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .miniPlayerBottomMargin()
        .navigationTitle(String(localized: "Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .lumaAccountProfileToolbar(isVisible: isOnline && !isHeaderScrolled, usesInlineTitle: !isOnline)
        .lumaScrollingRootHeader(isScrolled: $isHeaderScrolled, enabled: isOnline)
        .lumaServerReachability()
        .lumaContentWidth(.fill)
        .task(id: "\(container?.serverState.activeServer?.id.uuidString ?? ""):\(isOnline)") {
            guard let container else { return }
            guard isOnline else {
                AppBootGate.markHomeReady()
                return
            }
            let sid = container.serverState.activeServer?.id.uuidString
            if vm == nil || loadedServerID != sid {
                vm = DiscoverViewModel(libraryService: container.libraryService,
                    recommendationService: container.recommendationService,
                    personalMixService: container.personalMixService, serverId: sid)
                loadedServerID = sid
                featuredMixOrder = Self.featuredMixKinds.shuffled()
                listenAgain = nil
            }
            await loadListenAgain(container: container, serverID: sid)
            guard !Task.isCancelled else { return }
            await vm?.loadHomeDashboard(serverId: sid)
            guard !Task.isCancelled else { return }
            await container.homeDiscoveryFeed.load()
        }
        .refreshable { await reload(forceRefresh: true) }
        .onReceive(NotificationCenter.default.publisher(for: .lumaFavoritesChanged)) { _ in
            guard isOnline else { return }
            Task { await container?.homeDiscoveryFeed.load(forceRefresh: true) }
        }
        .sheet(item: $songToAddToPlaylist) { song in AddToPlaylistSheet(song: song) }
    }

    @ViewBuilder
    private func albumShelf(_ title: String, albums: [AlbumID3], localized: Bool = true) -> some View {
        if !albums.isEmpty {
            AdaptiveAlbumShelf(title: localized ? String(localized: String.LocalizationValue(title), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : title,
                albums: albums, prominent: true, showsSeeAll: true)
        }
    }

    private func favoriteSongs(_ songs: [DisplayableSong]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: HomeDestination.libraryFavorites) {
                HomeShelfHeading(title: String(localized: "Your Favorite Songs", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), showsChevron: true)
            }.buttonStyle(.plain)
            VStack(spacing: 0) {
                ForEach(Array(songs.prefix(3).enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index + 1, showCoverArt: true, isFavorite: true,
                        onAddToPlaylist: { songToAddToPlaylist = $0 }, showsEllipsisInsteadOfDuration: true,
                        onPlay: {
                            Task { try? await container?.playerService.play(tracks: songs, startIndex: index) }
                        })
                }
            }
        }
    }

    private func reload(forceRefresh: Bool) async {
        if let container {
            await loadListenAgain(container: container,
                                  serverID: container.serverState.activeServer?.id.uuidString)
        }
        await vm?.loadHomeDashboard(forceRefresh: forceRefresh, serverId: container?.serverState.activeServer?.id.uuidString)
        await container?.homeDiscoveryFeed.load(forceRefresh: forceRefresh)
        if forceRefresh { featuredMixOrder.shuffle() }
    }

    private func loadListenAgain(container: AppContainer, serverID: String?) async {
        guard let serverID else {
            listenAgain = nil
            return
        }
        let recommendation = await container.statsService
            .albumListenAgainRecommendation(serverId: serverID)
        guard !Task.isCancelled,
              container.serverState.activeServer?.id.uuidString == serverID else { return }
        listenAgain = recommendation
    }

}
