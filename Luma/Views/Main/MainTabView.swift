// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData
import SwiftSonic
import OSLog
#if os(iOS)
import UIKit
#endif

struct MainTabView: View {
    @Environment(\.appContainer) private var container
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale
    @AppStorage("coverArtUploadVersion") private var sidebarCoverVersion = 0
    @State private var sidebarArtwork = SidebarArtworkStore()
    #endif
    @State private var searchPath = NavigationPath()
    #if os(macOS)
    @State private var searchText = ""
    #endif
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var discoverPath = NavigationPath()
    @State private var recentlyAddedPath = NavigationPath()
    @State private var artistsPath = NavigationPath()
    @State private var albumsPath = NavigationPath()
    @State private var playlistsPath = NavigationPath()
    @State private var playlistPaths: [String: NavigationPath] = [:]
    @State private var songsPath = NavigationPath()
    @State private var pinPaths: [String: NavigationPath] = [:]
    @State private var downloadsPath = NavigationPath()
    @Query(sort: \PinnedItem.sortOrder) private var allPinnedItems: [PinnedItem]
    @State private var selectedTab: AppTab = .home
    @State private var mountedTabs: Set<AppTab> = [.home]
    @State private var showingFullPlayer = false
    @State private var openPlayerWithLyrics = false
    @State private var openPlayerWithQueue = false
    @State private var openPlayerLyricsMode: LumaLyricsViewMode = .lyrics
    @State private var showAccountSheet = false
    @State private var showAudioQualitySettings = false
    /// The quality card can request settings while the player cover is still up.
    /// Present after the cover finishes dismissing, not during its transition.
    @State private var pendingAudioQualitySettings = false
    @State private var showCreatePlaylist = false
    @State private var showSidebarEditor = false
    /// Path change requested from the full player / a notification, applied after the player's cover is
    /// completely gone. `mode` decides whether the tab's existing stack is preserved.
    @State private var pendingNavigation: (destination: HomeDestination, tab: AppTab, mode: NavigationMode)?
    @Namespace private var playerZoom
    private let fullPlayerZoomID = "full-player"
    /// Identity of this `tabs` hierarchy, so a device log can tell a re-render from a rebuild.
    @State private var tabsInstanceID = UUID()

    #if os(iOS)
    private var showsSidebarLibrarySections: Bool {
        // Large iPhones can become regular-width in landscape. Keep their tab
        // destinations mounted while rotating instead of swapping in iPad tabs.
        horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
    }
    #endif

    private enum AppTab: Hashable {
        case home, discover, library, search
        case recentlyAdded, artists, albums, songs, playlists, downloads
        /// A server playlist opened from its own sidebar row. The string is the
        /// playlist id, so each row keeps an independent navigation path.
        case playlist(String)
        /// A pinned album, artist, or playlist promoted into the Library sidebar.
        case pin(String)
    }

    /// Whether a deferred navigation replaces the tab's stack or pushes onto it.
    private enum NavigationMode {
        /// Show the destination as the only entry (deep-link semantics).
        case replace
        /// Push the destination on top of what the user was looking at, so Back returns there.
        case append
    }

    /// Preserve mounted tab state. User re-taps are handled by SearchTabReselectObserver.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                #if os(iOS)
                if case .pin(let id) = newValue,
                   let pin = sidebarPinnedItems.first(where: { $0.id == id }),
                   PinnedItemType(rawValue: pin.itemType) == .song {
                    playPinnedSong(pin)
                    return
                }
                #endif
                guard newValue != selectedTab else {
                    #if os(macOS)
                    if newValue == .search {
                        NotificationCenter.default.post(name: .lumaFocusSearch, object: nil)
                    }
                    #endif
                    return
                }
                mountedTabs.insert(newValue)
                selectedTab = newValue
            }
        )
    }

    private var accountDisplayName: String {
        let username = container?.serverState.activeServer?.username.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return username.isEmpty
            ? String(localized: "Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            : username
    }

    private func tabVisualsPresented(_ tab: AppTab) -> Bool {
        selectedTab == tab && !showingFullPlayer && !showAccountSheet && !showCreatePlaylist
    }

    @ViewBuilder
    private func pinnedItemRootView(_ pin: PinnedItem) -> some View {
        switch PinnedItemType(rawValue: pin.itemType) {
        case .album:
            AlbumDetailView(albumId: pin.itemId, albumName: pin.displayName, coverArtId: pin.coverArtId)
        case .artist:
            ArtistDetailView(artistId: pin.itemId, artistName: pin.displayName, coverArtId: pin.coverArtId)
        case .playlist:
            PlaylistDetailView(playlistId: pin.itemId, name: pin.displayName, coverArtId: pin.coverArtId)
        case .song, .none:
            EmptyView()
        }
    }

    #if os(iOS)
    /// Server playlists exposed as first-class sidebar rows under “All Playlists”.
    /// Only present on a regular-width iPad where the sidebar hierarchy is shown.
    private var sidebarPlaylists: [Playlist] {
        guard showsSidebarLibrarySections else { return [] }
        return container?.homeDiscoveryFeed.playlists ?? []
    }

    private var sidebarPlaylistIDs: [String] {
        sidebarPlaylists.map(\.id)
    }

    /// The active account's pins, in Home's order. An empty result removes the
    /// entire Pinned group, not just its rows. Song rows play without leaving the current tab.
    private var sidebarPinnedItems: [PinnedItem] {
        guard showsSidebarLibrarySections,
              let sid = container?.serverState.activeServer?.id else { return [] }
        return allPinnedItems.filter {
            $0.serverId == sid && PinnedItemType(rawValue: $0.itemType) != nil
        }
    }

    private var sidebarPinnedIDs: [String] {
        sidebarPinnedItems.map(\.id)
    }

    private var sidebarArtworkScope: SidebarArtworkStore.Scope {
        .init(serverID: container?.serverState.activeServer?.id,
              accountRevision: container?.serverState.accountRevision ?? 0,
              coverVersion: sidebarCoverVersion, displayScale: displayScale)
    }

    private var sidebarArtworkRequest: SidebarArtworkStore.Request? {
        guard showsSidebarLibrarySections else { return nil }
        let entries = sidebarPinnedItems.map { pin in
            SidebarArtworkStore.Entry(coverArtID: pin.coverArtId ?? pin.itemId,
                playlistID: pin.itemType == PinnedItemType.playlist.rawValue ? pin.itemId : nil,
                isArtist: pin.itemType == PinnedItemType.artist.rawValue)
        } + sidebarPlaylists.map {
            SidebarArtworkStore.Entry(coverArtID: $0.coverArt ?? $0.id, playlistID: $0.id)
        }
        var seen = Set<SidebarArtworkStore.Entry>()
        return .init(scope: sidebarArtworkScope, entries: entries.filter { seen.insert($0).inserted },
                     networkRevision: container?.serverState.artworkNetworkRevision ?? 0)
    }

    private func playPinnedSong(_ pin: PinnedItem) {
        guard let container,
              let identity = try? container.serverState.requestIdentity(for: pin.serverId) else { return }
        let songID = pin.itemId
        let title = pin.displayName
        let artist = pin.displaySubtitle
        let coverArtID = pin.coverArtId
        Task {
            let downloaded = await container.downloadService.isDownloaded(songId: songID, serverId: identity.serverID)
            guard !Task.isCancelled, container.serverState.requestIsCurrent(identity) else { return }
            do {
                let song = DisplayableSong(id: songID, title: title,
                    artist: artist.isEmpty ? nil : artist, isDownloaded: downloaded, coverArtId: coverArtID)
                try await container.playerService.play(tracks: [song], startIndex: 0)
            } catch is CancellationError {
                return
            } catch {
                guard container.serverState.requestIsCurrent(identity) else { return }
                container.toastService.showError(String(localized: "Unable to load tracks.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                Logger.player.error("[PLAYBACK] sidebar pinned song failed: \(error, privacy: .public)")
            }
        }
    }
    #endif

    private func playlistPathBinding(_ id: String) -> Binding<NavigationPath> {
        Binding(
            get: { playlistPaths[id] ?? NavigationPath() },
            set: { playlistPaths[id] = $0 }
        )
    }

    private func pinPathBinding(_ id: String) -> Binding<NavigationPath> {
        Binding(
            get: { pinPaths[id] ?? NavigationPath() },
            set: { pinPaths[id] = $0 }
        )
    }

    // MARK: - Tabs View
    @ViewBuilder
    private var tabs: some View {
        TabView(selection: tabSelection) {
            // Search first so the sidebar lists it at the top (Apple Music).
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack(path: $searchPath) {
                    #if os(macOS)
                    SearchView(searchQuery: $searchText, path: $searchPath)
                        .environment(\.registersHomeDestinations, true)
                    #else
                    SearchView(path: $searchPath)
                        .environment(\.registersHomeDestinations, true)
                    #endif
                }
                .environment(\.detailNavigationPath, $searchPath)
                .environment(\.playbackVisualsPresented, tabVisualsPresented(.search))
                .onChange(of: searchPath.count) { old, new in logPathChange(.search, from: old, to: new) }
            }

            Tab("Home", systemImage: homeTabSymbol, value: AppTab.home) {
                NavigationStack(path: $homePath) {
                    DashboardHomeView()
                        // Destination registration must survive cellular/reachability changes.
                        .navigationDestination(for: HomeDestination.self) { destination in
                            homeDestinationView(destination)
                        }
                }
                .environment(\.detailNavigationPath, $homePath)
                .environment(\.playbackVisualsPresented, tabVisualsPresented(.home))
                .onChange(of: homePath.count) { old, new in logPathChange(.home, from: old, to: new) }
            }

            Tab(discoverTabTitle, systemImage: discoverTabSymbol, value: AppTab.discover) {
                NavigationStack(path: $discoverPath) {
                    DiscoverView()
                        // Destination registration must survive cellular/reachability changes.
                        .navigationDestination(for: HomeDestination.self) { destination in
                            homeDestinationView(destination)
                        }
                }
                .environment(\.detailNavigationPath, $discoverPath)
                .environment(\.playbackVisualsPresented, tabVisualsPresented(.discover))
                .onChange(of: discoverPath.count) { old, new in logPathChange(.discover, from: old, to: new) }
            }

            // Library hub — keep it available in every tab presentation, including the
            // iPad floating tab bar and sidebar.
            Tab("Library", systemImage: "music.note.square.stack.fill", value: AppTab.library) {
                NavigationStack(path: $libraryPath) {
                    HomeView()
                        .environment(\.registersHomeDestinations, false)
                        .navigationDestination(for: HomeDestination.self) { destination in
                            libraryDestinationView(destination)
                        }
                }
                .environment(\.detailNavigationPath, $libraryPath)
                .environment(\.playbackVisualsPresented, tabVisualsPresented(.library))
                .onChange(of: libraryPath.count) { old, new in logPathChange(.library, from: old, to: new) }
            }
            #if os(iOS)
            .hidden(showsSidebarLibrarySections)
            #endif
            #if os(iOS)
            if showsSidebarLibrarySections {
                TabSection(String(localized: "Library", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    // Pinned albums/artists/playlists sit above the library rows,
                    // matching Music's sidebar. Each keeps its own navigation path.
                    if !sidebarPinnedItems.isEmpty {
                        TabSection {
                            ForEach(sidebarPinnedItems) { pin in
                                Tab(value: AppTab.pin(pin.id)) {
                                    NavigationStack(path: pinPathBinding(pin.id)) {
                                        lazySidebarRoot(when: .pin(pin.id)) {
                                            pinnedItemRootView(pin)
                                        }
                                        .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                                    }
                                    .environment(\.detailNavigationPath, pinPathBinding(pin.id))
                                    .environment(\.playbackVisualsPresented, tabVisualsPresented(.pin(pin.id)))
                                    .onChange(of: pinPaths[pin.id]?.count ?? 0) { old, new in
                                        logPathChange(.pin(pin.id), from: old, to: new)
                                    }
                                } label: {
                                    PinnedSidebarLabel(pin: pin, artwork: sidebarArtwork, scope: sidebarArtworkScope)
                                }
                                .tabPlacement(.sidebarOnly)
                            }
                        } header: {
                            Label(String(localized: "Pinned", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "pin")
                        }
                        .customizationID("luma.sidebar.pinned")
                    }

                    Tab("Recently Added", systemImage: "clock", value: AppTab.recentlyAdded) {
                        NavigationStack(path: $recentlyAddedPath) {
                            lazySidebarRoot(when: .recentlyAdded) { RecentlyAddedAlbumsView() }
                                .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                        }
                        .environment(\.detailNavigationPath, $recentlyAddedPath)
                        .environment(\.playbackVisualsPresented, tabVisualsPresented(.recentlyAdded))
                        .onChange(of: recentlyAddedPath.count) { old, new in logPathChange(.recentlyAdded, from: old, to: new) }
                    }
                    Tab("Artists", systemImage: "music.mic", value: AppTab.artists) {
                        NavigationStack(path: $artistsPath) {
                            lazySidebarRoot(when: .artists) { ArtistListView() }
                                .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                        }
                        .environment(\.detailNavigationPath, $artistsPath)
                        .environment(\.playbackVisualsPresented, tabVisualsPresented(.artists))
                        .onChange(of: artistsPath.count) { old, new in logPathChange(.artists, from: old, to: new) }
                    }
                    Tab("Albums", systemImage: "square.stack", value: AppTab.albums) {
                        NavigationStack(path: $albumsPath) {
                            lazySidebarRoot(when: .albums) { AlbumsListView() }
                                .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                        }
                        .environment(\.detailNavigationPath, $albumsPath)
                        .environment(\.playbackVisualsPresented, tabVisualsPresented(.albums))
                        .onChange(of: albumsPath.count) { old, new in logPathChange(.albums, from: old, to: new) }
                    }
                    Tab("Songs", systemImage: "music.note", value: AppTab.songs) {
                        NavigationStack(path: $songsPath) {
                            lazySidebarRoot(when: .songs) { SongsListView() }
                                .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                        }
                        .environment(\.detailNavigationPath, $songsPath)
                        .environment(\.playbackVisualsPresented, tabVisualsPresented(.songs))
                        .onChange(of: songsPath.count) { old, new in logPathChange(.songs, from: old, to: new) }
                    }
                    Tab("Downloads", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                        NavigationStack(path: $downloadsPath) {
                            // Never gated: this is where offline listening lives.
                            lazySidebarRoot(when: .downloads, serverBacked: false) { DownloadedView() }
                                .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                        }
                        .environment(\.detailNavigationPath, $downloadsPath)
                        .environment(\.playbackVisualsPresented, tabVisualsPresented(.downloads))
                        .onChange(of: downloadsPath.count) { old, new in logPathChange(.downloads, from: old, to: new) }
                    }
                }
                .defaultVisibility(.hidden, for: .tabBar)

                TabSection(String(localized: "Playlists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    Tab("All Playlists", systemImage: "square.grid.3x3", value: AppTab.playlists) {
                        NavigationStack(path: $playlistsPath) {
                            lazySidebarRoot(when: .playlists) { PlaylistListView() }
                                .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                        }
                        .environment(\.detailNavigationPath, $playlistsPath)
                        .environment(\.playbackVisualsPresented, tabVisualsPresented(.playlists))
                        .onChange(of: playlistsPath.count) { old, new in logPathChange(.playlists, from: old, to: new) }
                    }

                    // Server playlists sit directly below “All Playlists”, each with
                    // its live cover thumbnail and title. They are sidebar-only so the
                    // iPhone tab bar keeps its compact five-destination layout.
                    ForEach(sidebarPlaylists) { playlist in
                        Tab(value: AppTab.playlist(playlist.id)) {
                            NavigationStack(path: playlistPathBinding(playlist.id)) {
                                lazySidebarRoot(when: .playlist(playlist.id)) {
                                    PlaylistDetailView(playlist: playlist)
                                }
                                .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                            }
                            .environment(\.detailNavigationPath, playlistPathBinding(playlist.id))
                            .environment(\.playbackVisualsPresented, tabVisualsPresented(.playlist(playlist.id)))
                            .onChange(of: playlistPaths[playlist.id]?.count ?? 0) { old, new in
                                logPathChange(.playlist(playlist.id), from: old, to: new)
                            }
                        } label: {
                            PlaylistSidebarLabel(playlist: playlist, artwork: sidebarArtwork, scope: sidebarArtworkScope)
                        }
                        .tabPlacement(.sidebarOnly)
                    }
                }
                .sectionActions {
                    Button(String(localized: "New Playlist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "plus") {
                        showCreatePlaylist = true
                    }
                }
                .defaultVisibility(.hidden, for: .tabBar)
                .customizationID("luma.sidebar.playlists")
            }
            #endif
        }
        #if os(iOS)
        .tabViewStyle(.sidebarAdaptable)
        // iPadOS starts in the full sidebar (Apple Music style) instead of the
        // compact top tab bar. The system still remembers any later choice.
        .defaultAdaptableTabBarPlacement(.sidebar)
        // Keep the switch inside the sidebar chrome instead of above it. The
        // standard toggle is removed from the content bar; `tabViewSidebar`
        // hosts the replacement in the sidebar's own header.
        .toolbar(removing: .sidebarToggle)
        .contentToolbar(for: .tabViewSidebar) {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSidebarEditor = true
                } label: {
                    Text(String(localized: "Edit", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.body)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                LumaSidebarToggleButton()
            }
        }
        .tabViewSidebarBottomBar {
            SidebarAccountButton(username: accountDisplayName) { showAccountSheet = true }
        }
        .tint(showsSidebarLibrarySections ? .blue : .lumaAccent)
        #endif
    }

    private var homeTabSymbol: String {
        #if os(iOS)
        if showsSidebarLibrarySections { return "house" }
        #endif
        return "house.fill"
    }

    private var discoverTabSymbol: String {
        #if os(iOS)
        if showsSidebarLibrarySections { return "square.grid.2x2" }
        #endif
        return "square.grid.2x2.fill"
    }

    private var discoverTabTitle: String {
        #if os(iOS)
        if showsSidebarLibrarySections {
            return String(localized: "New Music", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        #endif
        return String(localized: "Discover", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    #if os(iOS)
    /// Mount on first selection and preserve the root thereafter, including scroll/task state.
    @ViewBuilder
    private func lazySidebarRoot<Content: View>(
        when tab: AppTab,
        serverBacked: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if selectedTab == tab || mountedTabs.contains(tab) {
            if serverBacked {
                content().lumaServerReachability(showsDeviceOffline: false)
            } else {
                content()
            }
        } else {
            Color.clear
        }
    }
    #endif

    @ViewBuilder
    private func homeDestinationView(_ destination: HomeDestination) -> some View {
        libraryDestinationView(destination)
    }

    @ViewBuilder
    private func libraryDestinationView(_ destination: HomeDestination) -> some View {
        switch destination {
        case .zoomAlbum(let route):
            AlbumZoomDestinationView(route: route)
        case .albumCollection(let collection):
            AlbumShelfCollectionView(collection: collection)
        case .libraryAlbums:
            AlbumsListView()
        case .libraryArtists:
            ArtistListView()
        case .librarySongs:
            SongsListView()
        case .libraryPlaylists:
            PlaylistListView()
        case .libraryFavorites:
            FavoritesView()
        case .libraryDownloads:
            DownloadedView()
        case .albumPush(let id, let name, let coverArtId, _):
            AlbumDetailView(albumId: id, albumName: name, coverArtId: coverArtId)
        case .album(let album):
            AlbumDetailView(album: album)
        case .artist(let artist):
            ArtistDetailView(artist: artist)
        case .albumById(let id, let name, _, let coverArtId):
            AlbumDetailView(albumId: id, albumName: name, coverArtId: coverArtId)
        case .artistById(let id, let name, let coverArtId):
            ArtistDetailView(artistId: id, artistName: name, coverArtId: coverArtId)
        case .artistPush(let id, let name, let coverArtId, _):
            ArtistDetailView(artistId: id, artistName: name, coverArtId: coverArtId)
        case .playlist(let playlist):
            PlaylistDetailView(playlist: playlist)
        case .playlistById(let id, let name, let coverArtId):
            PlaylistDetailView(playlistId: id, name: name, coverArtId: coverArtId)
        case .downloadedAlbum(let display):
            AlbumDetailView(
                albumId: display.albumId,
                albumName: display.name,
                coverArtId: display.coverArtId,
                mode: .downloadedOnly
            )
        case .replay:
            WrappedView()
        case .replayPeriod(let period):
            WrappedView(initialPeriod: period)
        case .offlineArtist(let artist):
            OfflineArtistAlbumsView(artist: artist)
        case .offlineAlbum(let album):
            AlbumDetailView(
                albumId: album.albumId,
                albumName: album.albumName,
                coverArtId: album.coverArtId
            )
        case .personalMix(let kind):
            PlaylistDetailView(generatedSource: .personalMix(kind))
        }
    }

    private func logPathChange(_ tab: AppTab, from old: Int, to new: Int) {
        Logger.ui.debug("[NAV] path tab=\(String(describing: tab), privacy: .public) \(old, privacy: .public) -> \(new, privacy: .public) tabs=\(tabsInstanceID, privacy: .public)")
    }

    var body: some View {
#if os(iOS)
        navigationObservedTabs
#else
        tabs
            .safeAreaInset(edge: .bottom) {
                MiniPlayerAccessoryView(
                    showingFullPlayer: $showingFullPlayer
                )
            }
            .lumaFullScreenCover(isPresented: $showingFullPlayer) {
                FullPlayerView()
                    .environment(\.playbackVisualsPresented, showingFullPlayer)
            }
#endif
    }

#if os(iOS)
    // Opaque subview boundaries keep each modifier chain independently
    // type-checkable without changing the mounted navigation hierarchy.
    private var playerAccessoryTabs: some View {
        Group {
            // Keep the TabView modifiers structurally stable. Album detail pages
            // register their chrome transition from a UIKit lifecycle bridge; making
            // `.toolbar` / `.tabBarMinimizeBehavior` depend on that observed state
            // caused the TabView to rebuild while the album was appearing, which
            // reattached the bridge and produced an endless willAppear/willDisappear
            // loop (and `NavigationRequestObserver` multi-update warnings).
            if #available(iOS 26.1, *) {
                tabs
                    .tabBarMinimizeBehavior(selectedTab == .search ? .never : .onScrollDown)
                    .tabViewBottomAccessory(isEnabled: true) {
                        miniPlayerAccessory(usesSystemAccessory: true)
                    }
            } else if #available(iOS 26.0, *) {
                tabs
                    .tabBarMinimizeBehavior(selectedTab == .search ? .never : .onScrollDown)
                    .tabViewBottomAccessory {
                        miniPlayerAccessory(usesSystemAccessory: true)
                    }
            } else {
                tabs.safeAreaInset(edge: .bottom, spacing: 0) {
                    miniPlayerAccessory(usesSystemAccessory: false)
                }
            }
        }
    }

    private var playerPresentedTabs: some View {
        playerAccessoryTabs
        .onReceive(NotificationCenter.default.publisher(for: .lumaOpenFullPlayer)) { _ in
            showingFullPlayer = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumaOpenFullPlayerLyrics)) { _ in
            presentFullPlayer(lyrics: true, queue: false,
                              mode: SiriPlayerRequestStore.consumeLyrics() ?? .lyrics)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumaOpenAudioQualitySettings)) { _ in
            if showingFullPlayer {
                pendingAudioQualitySettings = true
                showingFullPlayer = false
            } else {
                showAudioQualitySettings = true
            }
        }
        .onAppear {
            guard let mode = SiriPlayerRequestStore.consumeLyrics() else { return }
            presentFullPlayer(lyrics: true, queue: false, mode: mode)
        }
        .lumaFullScreenCover(isPresented: $showingFullPlayer, onDismiss: fullPlayerDidDismiss) {
            FullPlayerView(openWithLyrics: openPlayerWithLyrics, openWithQueue: openPlayerWithQueue,
                           openWithLyricsMode: openPlayerLyricsMode)
                .environment(\.playbackVisualsPresented, showingFullPlayer)
                .presentationBackground(.black)
                .lumaZoomTransition(sourceID: fullPlayerZoomID, in: playerZoom)
        }
        .onChange(of: showingFullPlayer) { _, presented in
            if presented {
                NotificationCenter.default.post(name: .lumaFullPlayerPresentationChanged,
                    object: nil, userInfo: ["isPresented": true])
            }
        }
        .modifier(TabBarChromeAppearance())
    }

    private var sidebarObservedTabs: some View {
        playerPresentedTabs
        .onChange(of: selectedTab) { _, tab in mountedTabs.insert(tab) }
        .onChange(of: showsSidebarLibrarySections) { _, hidesLibraryTab in
            // The dedicated Library hub tab is hidden on a regular-width iPad
            // because its destinations live in the sidebar section.
            if hidesLibraryTab, selectedTab == .library {
                selectedTab = .recentlyAdded
            }
            // Playlist rows are sidebar-only; leave an invalid selection behind
            // when the window becomes compact.
            if !hidesLibraryTab, case .playlist = selectedTab {
                selectedTab = .home
            }
        }
        .onChange(of: sidebarPlaylistIDs) { _, ids in
            if case .playlist(let id) = selectedTab, !ids.contains(id) {
                selectedTab = showsSidebarLibrarySections ? .playlists : .library
            }
        }
        .onChange(of: sidebarPinnedIDs) { _, ids in
            if case .pin(let id) = selectedTab, !ids.contains(id) {
                selectedTab = showsSidebarLibrarySections ? .recentlyAdded : .library
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumaPlaylistDeleted)) { _ in
            refreshSidebarPlaylists()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumaPlaylistMetadataChanged)) { note in
            guard showsSidebarLibrarySections,
                  let serverID = note.userInfo?["serverID"] as? UUID,
                  serverID == container?.serverState.activeServer?.id else { return }
            refreshSidebarPlaylists()
        }
        .task(id: sidebarArtworkRequest) {
            await sidebarArtwork.load(sidebarArtworkRequest, container: container)
        }
    }

    private var sheetPresentedTabs: some View {
        sidebarObservedTabs
        .sheet(isPresented: $showAccountSheet) {
            AccountSheetView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAudioQualitySettings) {
            if let settings = container?.streamingSettings {
                NavigationStack {
                    AudioQualitySettingsView(settings: settings)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(String(localized: "Done", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                                    showAudioQualitySettings = false
                                }
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showSidebarEditor) {
            SidebarPinsEditor()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCreatePlaylist) {
            CreatePlaylistSheet { _ in
                refreshSidebarPlaylists()
            }
        }
    }

    private var navigationObservedTabs: some View {
        sheetPresentedTabs
        .onReceive(NotificationCenter.default.publisher(for: .lumaNavigateToArtist)) { note in
            handleNavigateToArtist(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumaNavigateToAlbum)) { note in
            handleNavigateToAlbum(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumaNavigateToPlaylist)) { note in
            handleNavigateToPlaylist(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumaSearchInApp)) { _ in
            selectedTab = .search
        }
        .task {
            // Rebuild indicator: one line per `MainTabView` instance. A new id here (without a
            // relaunch) means the whole tab hierarchy — every stack and pushed page — was rebuilt,
            // which is what leaves a pushed page's back gesture dead.
            Logger.ui.debug("[TABS] MainTabView instance=\(tabsInstanceID, privacy: .public) appeared")
            if #available(iOS 27.0, *), UserDefaults.standard.string(forKey: "luma.siri.pendingSearchQuery") != nil {
                selectedTab = .search
            }
        }
        .task(id: "\(container?.serverState.activeServer?.id.uuidString ?? "-"):\(showsSidebarLibrarySections)") {
            // The sidebar lists server playlists directly. Home normally warms
            // this feed, but a launch straight into Search or a deep link must
            // populate the sidebar too; the feed coalesces concurrent loads.
            // iPad-only: the iPhone tab bar has no playlist rows.
            guard showsSidebarLibrarySections, let container else { return }
            await container.homeDiscoveryFeed.load()
        }
        .background {
            SearchTabReselectObserver(isSearchSelected: selectedTab == .search) {
                NotificationCenter.default.post(name: .lumaFocusSearch, object: nil)
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func refreshSidebarPlaylists() {
        guard showsSidebarLibrarySections, let feed = container?.homeDiscoveryFeed else { return }
        Task { await feed.load(forceRefresh: true) }
    }

    private func miniPlayerAccessory(usesSystemAccessory: Bool) -> some View {
        MiniPlayerAccessoryView(showingFullPlayer: $showingFullPlayer,
            onOpenLyrics: { presentFullPlayer(lyrics: true, queue: false) },
            onOpenQueue: { presentFullPlayer(lyrics: false, queue: true) },
            usesSystemAccessory: usesSystemAccessory)
            .environment(\.marqueePaused, showingFullPlayer)
            .lumaMatchedTransitionSource(id: fullPlayerZoomID, in: playerZoom)
    }

    private func presentFullPlayer(lyrics: Bool, queue: Bool, mode: LumaLyricsViewMode = .lyrics) {
        openPlayerWithLyrics = lyrics
        openPlayerWithQueue = queue
        openPlayerLyricsMode = mode
        showingFullPlayer = true
    }

    private func resetFullPlayerLaunchFlags() {
        openPlayerWithLyrics = false
        openPlayerWithQueue = false
        openPlayerLyricsMode = .lyrics
    }

    private func fullPlayerDidDismiss() {
        #if os(iOS)
        NotificationCenter.default.post(name: .lumaFullPlayerPresentationChanged,
            object: nil, userInfo: ["isPresented": false])
        #endif
        resetFullPlayerLaunchFlags()
        if pendingAudioQualitySettings {
            pendingAudioQualitySettings = false
            showAudioQualitySettings = true
            return
        }
        guard let request = pendingNavigation else { return }
        pendingNavigation = nil
        Logger.ui.debug("[NAV] pending execute tab=\(String(describing: request.tab), privacy: .public) mode=\(String(describing: request.mode), privacy: .public)")
        switch request.mode {
        case .replace: performNavigation(to: request.destination, tab: request.tab)
        case .append: appendDestination(request.destination, to: request.tab)
        }
    }

    private func handleNavigateToArtist(_ note: Notification) {
        guard let id = note.userInfo?["artistId"] as? String else { return }
        let name = note.userInfo?["artistName"] as? String ?? ""
        let cover = note.userInfo?["coverArtId"] as? String
        // One token per tap. `HomeDestination` artist values are equal by content, and NavigationStack maps
        // an equal path value onto the entry that already holds it — an artist already in the path would be
        // reused (pop, not push) and the back button would point at a removed entry. Created here so it
        // stays stable for the life of the entry.
        let dest = HomeDestination.artistPush(id: id, name: name, coverArtId: cover, token: UUID())
        // Push into the tab the user is looking at (the player covers it) so Back returns to the page they
        // came from instead of dropping the whole path.
        navigateAppending(to: dest, tab: selectedTab)
    }

    private func handleNavigateToAlbum(_ note: Notification) {
        guard let id = note.userInfo?["albumId"] as? String else { return }
        let name = note.userInfo?["albumName"] as? String ?? ""
        let cover = note.userInfo?["coverArtId"] as? String
        Logger.ui.debug("[NAV] notification album id=\(id, privacy: .public) tab=\(String(describing: self.selectedTab), privacy: .public) player=\(self.showingFullPlayer, privacy: .public)")
        let dest = HomeDestination.albumById(id: id, name: name, subtitle: "", coverArtId: cover)
        navigateReplacingPath(to: dest, tab: .home)
    }

    private func handleNavigateToPlaylist(_ note: Notification) {
        guard let id = note.userInfo?["playlistId"] as? String else { return }
        let name = note.userInfo?["name"] as? String ?? ""
        let cover = note.userInfo?["coverArtId"] as? String
        let dest = HomeDestination.playlistById(id: id, name: name, coverArtId: cover)
        #if os(iOS)
        // The Library hub tab is hidden in the iPad sidebar; use All Playlists
        // as the visible destination for Siri/Spotlight playlist links.
        let targetTab: AppTab = showsSidebarLibrarySections ? .playlists : .library
        #else
        let targetTab: AppTab = .library
        #endif
        navigateReplacingPath(to: dest, tab: targetTab)
    }

    /// Dismiss the player first, then navigate from its real completion callback. A fixed
    /// delay races the full-screen dismissal animation and can leave the destination under
    /// a stale black presentation layer.
    private func navigateReplacingPath(to destination: HomeDestination, tab: AppTab) {
        Logger.ui.debug("[NAV] replace request tab=\(String(describing: tab), privacy: .public) player=\(self.showingFullPlayer, privacy: .public)")
        if showingFullPlayer {
            pendingNavigation = (destination, tab, .replace)
            showingFullPlayer = false
        } else {
            performNavigation(to: destination, tab: tab)
        }
    }

    /// Pushes the destination onto the tab the user is in, after any presentation has fully gone.
    private func navigateAppending(to destination: HomeDestination, tab: AppTab) {
        Logger.ui.debug("[NAV] append request tab=\(String(describing: tab), privacy: .public) player=\(self.showingFullPlayer, privacy: .public)")
        if showingFullPlayer {
            pendingNavigation = (destination, tab, .append)
            showingFullPlayer = false
        } else {
            appendDestination(destination, to: tab)
        }
    }

    private func performNavigation(to destination: HomeDestination, tab: AppTab) {
        selectedTab = tab
        applyingAfterPresentationsSettle {
            // Give TabView one update cycle to mount the selected NavigationStack.
            await Task.yield()
            var path = NavigationPath()
            path.append(destination)
            replacePath(path, in: tab)
        }
    }

    private func appendDestination(_ destination: HomeDestination, to tab: AppTab) {
        applyingAfterPresentationsSettle {
            await Task.yield()
            appendPath(destination, in: tab)
        }
    }

    /// A zoom-dismissed cover (and any closing sheet) keeps its presentation layer on top for a runloop or
    /// two after `onDismiss`, and the tab's stack only mounts on the following update cycle. Mutating a
    /// NavigationPath in that window leaves the pushed page under that stale layer: it renders blank (or
    /// black) and taps on the back button never reach it. Wait until UIKit reports no presented controller,
    /// then apply the change on the next main-queue pass. Bounded so a stuck presentation cannot block
    /// navigation forever.
    private func applyingAfterPresentationsSettle(_ change: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            #if os(iOS)
            var attempts = 0
            while Self.hasPresentedViewController(), attempts < 40 {
                attempts += 1
                try? await Task.sleep(for: .milliseconds(16))
            }
            #endif
            await Task.yield()
            await change()
        }
    }

    private func replacePath(_ path: NavigationPath, in tab: AppTab) {
        Logger.ui.debug("[NAV] replace requested tab=\(String(describing: tab), privacy: .public) count=\(path.count, privacy: .public)")
        switch tab {
        case .home: homePath = path
        case .library: libraryPath = path
        case .discover: discoverPath = path
        case .search: searchPath = path
        case .recentlyAdded: recentlyAddedPath = path
        case .artists: artistsPath = path
        case .albums: albumsPath = path
        case .songs: songsPath = path
        case .playlists: playlistsPath = path
        case .downloads: downloadsPath = path
        case .playlist(let id): playlistPaths[id] = path
        case .pin(let id): pinPaths[id] = path
        }
    }

    private func appendPath(_ destination: HomeDestination, in tab: AppTab) {
        Logger.ui.debug("[NAV] append requested tab=\(String(describing: tab), privacy: .public)")
        switch tab {
        case .home: homePath.append(destination)
        case .library: libraryPath.append(destination)
        case .discover: discoverPath.append(destination)
        case .search: searchPath.append(destination)
        case .recentlyAdded: recentlyAddedPath.append(destination)
        case .artists: artistsPath.append(destination)
        case .albums: albumsPath.append(destination)
        case .songs: songsPath.append(destination)
        case .playlists: playlistsPath.append(destination)
        case .downloads: downloadsPath.append(destination)
        case .playlist(let id):
            var path = playlistPaths[id] ?? NavigationPath()
            path.append(destination)
            playlistPaths[id] = path
        case .pin(let id):
            var path = pinPaths[id] ?? NavigationPath()
            path.append(destination)
            pinPaths[id] = path
        }
    }


    #if os(iOS)
    /// True while any view controller sits above the key window's root (the full player's cover, a sheet, an
    /// alert…). The path change must wait for it to go.
    private static func hasPresentedViewController() -> Bool {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return false }
        var controller = root
        while let presented = controller.presentedViewController { controller = presented }
        return controller !== root
    }
    #endif
#endif
}

#if os(iOS)
/// A fixed, full-width account row with a blurred backdrop extending to the
/// bottom safe area, separated from the scrolling sidebar by a fine top rule.
private struct SidebarAccountButton: View {
    let username: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LumaProfileAvatar(username: username, size: 32)
                Text(username)
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, ignoresSafeAreaEdges: [.horizontal, .bottom])
        .overlay(alignment: .top) { Divider() }
        .accessibilityLabel(String(localized: "Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .accessibilityValue(username)
        .accessibilityIdentifier("ipad.sidebar.account")
    }
}

/// Keep real Label semantics for native TabView title/icon extraction. Artwork
/// rows share one icon column and row height.
private struct SidebarArtworkLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            configuration.title
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44)
    }
}

/// One playlist row in the TabView sidebar: live cover thumbnail + title,
/// matching the “All Playlists” hierarchy rather than a generic list glyph.
private struct PlaylistSidebarLabel: View {
    let playlist: Playlist
    let artwork: SidebarArtworkStore
    let scope: SidebarArtworkStore.Scope

    var body: some View {
        Label {
            Text(playlist.name)
        } icon: {
            if let image = artwork.image(for: .init(coverArtID: playlist.coverArt ?? playlist.id, playlistID: playlist.id), scope: scope) {
                Image(uiImage: image).renderingMode(.original)
            } else {
                Image(systemName: "music.note.list")
            }
        }
        .labelStyle(SidebarArtworkLabelStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(playlist.name))
    }
}

#endif

#if os(iOS)
/// Pinned album, artist, playlist, or song in the Library sidebar section.
private struct PinnedSidebarLabel: View {
    let pin: PinnedItem
    let artwork: SidebarArtworkStore
    let scope: SidebarArtworkStore.Scope

    private var type: PinnedItemType {
        PinnedItemType(rawValue: pin.itemType) ?? .album
    }

    private var entry: SidebarArtworkStore.Entry {
        .init(coverArtID: pin.coverArtId ?? pin.itemId,
              playlistID: type == .playlist ? pin.itemId : nil,
              isArtist: type == .artist)
    }

    var body: some View {
        Label {
            Text(pin.displayName)
        } icon: {
            if let image = artwork.image(for: entry, scope: scope) {
                Image(uiImage: image).renderingMode(.original)
            } else {
                Image(systemName: type == .artist ? "person.crop.circle" : "music.note")
            }
        }
        .labelStyle(SidebarArtworkLabelStyle())
        .padding(.leading, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(pin.displayName))
    }
}
#endif

#if os(iOS)
/// Compact sheet for reordering or removing the pins that appear above the
/// Library rows in the iPad sidebar.
private struct SidebarPinsEditor: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PinnedItem.sortOrder) private var allPins: [PinnedItem]
    @State private var localPins: [PinnedItem] = []

    private var activePins: [PinnedItem] {
        guard let sid = container?.serverState.activeServer?.id else { return [] }
        return allPins.filter {
            $0.serverId == sid && PinnedItemType(rawValue: $0.itemType) != nil
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if localPins.isEmpty {
                    ContentUnavailableView("Pinned", systemImage: "pin.slash")
                } else {
                    ForEach(localPins) { pin in
                        HStack(spacing: 10) {
                            PinnedEditorArtwork(pin: pin)
                                .frame(width: 32, height: 32)
                            Text(pin.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .onMove { offsets, destination in
                        localPins.move(fromOffsets: offsets, toOffset: destination)
                        container?.pinService.reorder(items: localPins)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let pin = localPins[index]
                            if let type = PinnedItemType(rawValue: pin.itemType) {
                                container?.pinService.unpin(itemType: type, itemId: pin.itemId)
                            }
                        }
                        localPins.remove(atOffsets: offsets)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(Text("Edit Pins"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                        dismiss()
                    }
                }
            }
            .onAppear { localPins = activePins }
            .onChange(of: allPins.map(\.id)) { _, _ in
                localPins = activePins
            }
        }
    }
}

private struct PinnedEditorArtwork: View {
    let pin: PinnedItem

    private var type: PinnedItemType {
        PinnedItemType(rawValue: pin.itemType) ?? .album
    }

    private var shape: AnyShape {
        type == .artist
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    var body: some View {
        Group {
            if type == .playlist {
                PlaylistCoverThumbnail(
                    playlistId: pin.itemId,
                    serverId: pin.serverId,
                    coverArtId: pin.coverArtId ?? pin.itemId,
                    title: pin.displayName,
                    size: 32,
                    showsTitleOverlay: false,
                    cornerRadius: 5
                )
            } else {
                CoverArtView(id: pin.coverArtId ?? pin.itemId, size: 80)
            }
        }
        .clipShape(shape)
    }
}
#endif
