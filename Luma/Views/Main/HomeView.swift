// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

struct HomeView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PinnedItem.sortOrder) private var allPinnedItems: [PinnedItem]
    @Query private var recentDownloadedAlbums: [DownloadedAlbum]
    @Query private var recentDownloadedPlaylists: [DownloadedPlaylist]
    init() {
        var albumDescriptor = FetchDescriptor<DownloadedAlbum>(
            sortBy: [SortDescriptor(\DownloadedAlbum.downloadedAt, order: .reverse)]
        )
        albumDescriptor.fetchLimit = 24
        _recentDownloadedAlbums = Query(albumDescriptor)

        var playlistDescriptor = FetchDescriptor<DownloadedPlaylist>(
            sortBy: [SortDescriptor(\DownloadedPlaylist.downloadedAt, order: .reverse)]
        )
        playlistDescriptor.fetchLimit = 24
        _recentDownloadedPlaylists = Query(playlistDescriptor)
    }

    @Namespace private var pinnedZoomNamespace
    @Namespace private var recentlyAddedZoomNamespace
    @Namespace private var playlistZoomNamespace
    @Namespace private var favoritesZoomNamespace
    /// Owned by the Home page, not by each downloaded card. LazyVGrid can rebuild a
    /// card while its album detail is pushed; a per-card namespace then no longer
    /// matches the namespace stored in the navigation route on pop.
    @Namespace private var downloadsZoomNamespace
    /// When false (Pad / Library stack parent), destinations are registered once above.
    @Environment(\.registersHomeDestinations) private var registersHomeDestinations
    @State private var viewModel: HomeViewModel?
    @State private var showCreatePlaylist = false
    @State private var showAccountSheet = false
    @State private var isEditingPins = false
    @State private var isHeaderScrolled = false
    @State private var navigateToAllAlbums = false
    // Local mutable copy for smooth drag-to-reorder; synced from @Query on count changes.
    @State private var localPinnedItems: [PinnedItem] = []
    @State private var offlineSongIDs = Set<String>()
    @State private var offlineAvailability: [String: Bool] = [:]
    @State private var offlineAvailabilityReady = false
    @State private var offlineAvailabilityRefresh = 0
    @State private var dropTargetId: String?
    @ScaledMetric(relativeTo: .caption) private var favoriteShelfTextHeight: CGFloat = 58
    private let recentColumns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: LumaSpacing.m)
    ]
    private let pinnedColumns = [
        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: LumaSpacing.m)
    ]

    private var isOnline: Bool { container?.serverState.isOnline == true }

    private var recentDownloadedItems: [DownloadedItem] {
        guard let sid = container?.serverState.activeServer?.id else { return [] }
        let albumItems = recentDownloadedAlbums.filter { $0.serverId == sid && $0.tracksCount > 0 }.map {
            DownloadedItem(
                id: "\(sid.uuidString):album:\($0.albumId)",
                itemId: $0.albumId,
                type: .album,
                name: $0.name,
                subtitle: $0.artist ?? "",
                coverArtId: $0.coverArtId,
                downloadedAt: $0.downloadedAt,
                serverId: sid
            )
        }
        let playlistItems = recentDownloadedPlaylists.filter { $0.serverId == sid && $0.tracksCount > 0 }.map {
            DownloadedItem(
                id: "\(sid.uuidString):playlist:\($0.playlistId)",
                itemId: $0.playlistId,
                type: .playlist,
                name: $0.name,
                subtitle: "",
                coverArtId: $0.coverArtId,
                downloadedAt: $0.downloadedAt,
                serverId: sid
            )
        }
        return (albumItems + playlistItems)
            .sorted { $0.downloadedAt > $1.downloadedAt }
            .prefix(24)
            .map { $0 }
    }

    private var visiblePinnedItems: [PinnedItem] {
        guard let sid = container?.serverState.activeServer?.id else { return [] }
        let scoped = localPinnedItems.filter { $0.serverId == sid }
        guard container?.serverState.isOnline != true else { return scoped }
        return scoped.filter { isAvailableOffline($0) }
    }

    private func isAvailableOffline(_ item: PinnedItem) -> Bool {
        // The first frame keeps the legacy synchronous answer; subsequent
        // evaluations use the task-owned snapshot below instead of fetching
        // SwiftData from a view computed property on every body pass.
        if offlineAvailabilityReady {
            return offlineAvailability[item.id] ?? false
        }
        return computeOfflineAvailability(item)
    }

    private func computeOfflineAvailability(
        _ item: PinnedItem,
        downloadedSongIDs: Set<String>? = nil
    ) -> Bool {
        let itemId = item.itemId
        let sid = item.serverId
        let songIDs = downloadedSongIDs ?? offlineSongIDs
        switch PinnedItemType(rawValue: item.itemType) {
        case .album:
            let descriptor = FetchDescriptor<DownloadedAlbum>(
                predicate: #Predicate { $0.albumId == itemId && $0.serverId == sid && $0.tracksCount > 0 }
            )
            return (try? modelContext.fetch(descriptor).first) != nil
        case .playlist:
            let descriptor = FetchDescriptor<DownloadedPlaylist>(
                predicate: #Predicate { $0.playlistId == itemId && $0.serverId == sid && $0.tracksCount > 0 }
            )
            return (try? modelContext.fetch(descriptor).first) != nil
        case .song:
            return songIDs.contains(itemId)
        case .artist:
            let descriptor = FetchDescriptor<DownloadedTrack>(
                predicate: #Predicate { $0.artistId == itemId && $0.serverId == sid }
            )
            return ((try? modelContext.fetch(descriptor)) ?? []).contains { songIDs.contains($0.songId) }
        case .none:
            return false
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LumaSpacing.xl) {
                #if os(iOS)
                if !visiblePinnedItems.isEmpty {
                    pinnedSection
                }
                librarySection
                #endif
                #if os(macOS)
                macOSCarousels
                #else
                recentlySection
                #endif
            }
            .padding(.horizontal, LumaSpacing.l)
            .padding(.top, LumaSpacing.m)
            .padding(.bottom, LumaSpacing.xl)
        }
        .miniPlayerBottomMargin()
        .navigationTitle(String(localized: "Library", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .lumaRootTabTitleAlignment()
        .lumaScrollingRootHeader(isScrolled: $isHeaderScrolled)
        .toolbar {
            #if os(iOS)
            if !isHeaderScrolled {
                if isEditingPins {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            HapticFeedback.light.trigger()
                            withAnimation(LumaAnimation.chrome) { isEditingPins = false }
                        } label: {
                            CircleToolbarLabel(systemName: "checkmark", filled: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Done", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                } else {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showCreatePlaylist = true
                        } label: {
                            Image(systemName: "text.badge.plus")
                                .font(.body.weight(.semibold))
                        }
                        .tint(.white)
                        .disabled(!isOnline)
                        .accessibilityLabel(String(localized: "New Playlist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

                        Menu {
                            Button {
                                HapticFeedback.light.trigger()
                                withAnimation(LumaAnimation.chrome) { isEditingPins = true }
                            } label: {
                                Label(
                                    String(localized: "Edit Pins", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                    systemImage: "pin"
                                )
                            }
                            .disabled(visiblePinnedItems.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.body.weight(.semibold))
                        }
                        .tint(.white)
                        .accessibilityLabel(String(localized: "More", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }

                    // Own ToolbarItem so the profile control sits apart from the action capsule.
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAccountSheet = true
                        } label: {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel(String(localized: "Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                }
            }
            #endif
        }
        .sheet(isPresented: $showCreatePlaylist) { CreatePlaylistSheet { _ in } }
        #if os(iOS)
        .sheet(isPresented: $showAccountSheet) {
            AccountSheetView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        #endif
        #if os(macOS)
        .navigationDestination(isPresented: $navigateToAllAlbums) { AlbumsListView() }
        #endif
        #if os(iOS)
        .modifier(HomeDestinationRegistrar(
            enabled: registersHomeDestinations,
            recentlyAddedZoomNamespace: recentlyAddedZoomNamespace,
            playlistZoomNamespace: playlistZoomNamespace,
            pinnedZoomNamespace: pinnedZoomNamespace
        ))
        #endif
        .onAppear { localPinnedItems = allPinnedItems }
        .task(id: "offline-\(container?.serverState.accountRevision ?? 0)-\(isOnline)-\(localPinnedItems.map(\.id).joined(separator: ","))-\(offlineAvailabilityRefresh)") {
            guard let container, let sid = container.serverState.activeServer?.id,
                  let identity = try? container.serverState.requestIdentity(for: sid) else {
                offlineSongIDs = []
                offlineAvailability = [:]
                offlineAvailabilityReady = false
                return
            }
            let ids = await container.downloadService.downloadedSongIds(serverId: sid)
            guard container.serverState.requestIsCurrent(identity), !Task.isCancelled else { return }
            let items = localPinnedItems.filter { $0.serverId == sid }
            var next: [String: Bool] = [:]
            for item in items {
                next[item.id] = computeOfflineAvailability(item, downloadedSongIDs: ids)
            }
            guard container.serverState.requestIsCurrent(identity), !Task.isCancelled else { return }
            offlineSongIDs = ids
            offlineAvailability = next
            offlineAvailabilityReady = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumaDownloadCompleted)) { _ in
            offlineAvailabilityRefresh &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumaOfflineMetadataChanged)) { _ in
            offlineAvailabilityRefresh &+= 1
        }
        .onChange(of: allPinnedItems.count) { _, _ in localPinnedItems = allPinnedItems }
        .onChange(of: visiblePinnedItems.isEmpty) { _, isEmpty in
            if isEmpty, isEditingPins {
                withAnimation(LumaAnimation.chrome) { isEditingPins = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumaServerCredentialsChanged)) { _ in
            Task {
                await viewModel?.loadLibrary(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumaFavoritesChanged)) { _ in
            Task { await viewModel?.loadStarred(force: true) }
        }
        .task(id: container?.serverState.isOnline) {
            guard let svc = container?.libraryService else { return }
            if viewModel == nil { viewModel = HomeViewModel(libraryService: svc) }
            guard let vm = viewModel, container?.serverState.isOnline == true else { return }
            // Wait for Listen Now's first claim on the Subsonic client before starring/library lists.
            await AppBootGate.waitForHome()
            await vm.loadLibrary()
        }
    }

    // MARK: - Favorites shelf (starred artists / albums / songs)

    #if os(iOS)
    private func favoritesShelfSection(vm: HomeViewModel) -> some View {
        VStack(alignment: .leading, spacing: LumaSpacing.m) {
            HStack {
                Text(String(localized: "Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .font(.lumaSectionTitle)
                Spacer(minLength: 0)
                NavigationLink(value: HomeDestination.libraryFavorites) {
                    Text(String(localized: "See All", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.lumaCaption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }

            if !vm.starredAlbums.isEmpty {
                favoritesHorizontalShelf(title: String(localized: "Albums", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    ForEach(vm.starredAlbums) { album in
                        AlbumNavigationLink(album: album, namespace: favoritesZoomNamespace) { sourceID, namespace in
                            LibraryFavoriteTile(
                                title: album.name,
                                subtitle: album.artist,
                                coverArtId: album.coverArt ?? album.id,
                                shape: .rounded
                            )
                            .lumaMatchedTransitionSource(id: sourceID, in: namespace)
                        }
                        .buttonStyle(.plain)
                        .albumLongPressMenu(album)
                    }
                }
            }

            if !vm.starredArtists.isEmpty {
                favoritesHorizontalShelf(title: String(localized: "Artists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    ForEach(vm.starredArtists) { artist in
                        NavigationLink(value: HomeDestination.artistById(id: artist.id, name: artist.name,
                                                                          coverArtId: artist.coverArt)) {
                            LibraryFavoriteTile(
                                title: artist.name,
                                subtitle: nil,
                                coverArtId: artist.coverArt ?? artist.id,
                                shape: .circle,
                                placeholderSystemImage: "person.fill"
                            )
                        }
                        .buttonStyle(.plain)
                        .artistLongPressMenu(artist)
                    }
                }
            }

            if !vm.starredSongs.isEmpty {
                favoritesHorizontalShelf(title: String(localized: "Songs", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    ForEach(Array(vm.starredSongs.enumerated()), id: \.element.id) { index, song in
                        Button {
                            Task {
                                let tracks = vm.starredSongs.map { DisplayableSong(from: $0) }
                                try? await container?.playerService.play(tracks: tracks, startIndex: index)
                            }
                        } label: {
                            LibraryFavoriteTile(
                                title: song.title,
                                subtitle: song.artist,
                                coverArtId: song.coverArt ?? song.id,
                                shape: .rounded
                            )
                        }
                        .buttonStyle(.plain)
                        .songLongPressMenu(DisplayableSong(from: song))
                        .accessibilityHint(String(localized: "Play", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                }
            }
        }
    }

    private func favoritesHorizontalShelf<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: LumaSpacing.s) {
            Text(title)
                .font(.lumaCaption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: LumaSpacing.m) {
                    content()
                }
                .frame(height: 110 + favoriteShelfTextHeight, alignment: .top)
            }
            .frame(height: 110 + favoriteShelfTextHeight)
        }
    }
    #endif

    // MARK: - macOS carousels

    #if os(macOS)
    @ViewBuilder
    private var macOSCarousels: some View {
        VStack(alignment: .leading, spacing: 32) {
            if isOnline {
                smartShuffleCard
            }
            if let vm = viewModel {
                if vm.isLoading && vm.recentAlbums.isEmpty && vm.recentlyPlayed.isEmpty && vm.mostPlayed.isEmpty {
                    ProgressView("Loading your library...")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if let error = vm.error, vm.recentAlbums.isEmpty {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "Unable to Load",
                        subtitle: error.displayMessage,
                        action: .init(label: "Retry") { Task { await vm.load() } }
                    )
                } else if !vm.isLoading && vm.recentAlbums.isEmpty && vm.recentlyPlayed.isEmpty && vm.mostPlayed.isEmpty {
                    EmptyStateView(
                        systemImage: "music.note.list",
                        title: "No music yet",
                        subtitle: "Add some music to your server to get started"
                    )
                } else {
                    VStack(alignment: .leading, spacing: 32) {
                        if !vm.recentAlbums.isEmpty {
                            CarouselSection(title: "Recently Added", onSeeAll: {
                                #if os(macOS)
                                NotificationCenter.default.post(name: .lumaSelectAlbums, object: nil)
                                #else
                                navigateToAllAlbums = true
                                #endif
                            }) {
                                ForEach(vm.recentAlbums) { album in
                                    CarouselAlbumCard(album: album)
                                }
                            }
                        }
                        if !vm.recentlyPlayed.isEmpty {
                            CarouselSection(title: "Recently Played") {
                                ForEach(vm.recentlyPlayed) { album in
                                    CarouselAlbumCard(album: album)
                                }
                            }
                        }
                        if !vm.mostPlayed.isEmpty {
                            CarouselSection(title: "Most Played") {
                                ForEach(vm.mostPlayed) { album in
                                    CarouselAlbumCard(album: album)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var smartShuffleCard: some View {
        Button {
            Task {
                guard let container else { return }
                do {
                    try await container.playerService.playSmartShuffle()
                } catch {
                    let msg: String
                    if case LumaError.smartShuffleEmpty = error {
                        msg = "Smart Shuffle unavailable — try playing some tracks first or download more music for offline use."
                    } else {
                        msg = "Smart Shuffle failed. Please try again."
                    }
                    container.toastService.showError(msg)
                }
            }
        } label: {
            HStack(spacing: LumaSpacing.s) {
                Image(systemName: "shuffle.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.lumaAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Shuffle")
                        .font(.lumaCellTitle)
                    Text("A random mix from your library")
                        .font(.lumaCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.lumaAccent)
            }
            .padding(LumaSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.lumaAccent.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: LumaCornerRadius.standard, style: .continuous))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - Pinned section

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: LumaSpacing.s) {
            LazyVGrid(columns: pinnedColumns, spacing: LumaSpacing.m) {
                ForEach(visiblePinnedItems) { item in
                    HomePinnedCard(item: item, namespace: pinnedZoomNamespace)
                        .overlay(alignment: .topLeading) {
                            if isEditingPins {
                                Button {
                                    unpin(item)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.title2)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black)
                                }
                                .buttonStyle(.plain)
                                .padding(LumaSpacing.xs)
                                .accessibilityLabel(String(localized: "Unpin", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            }
                        }
                        .scaleEffect(dropTargetId == item.id ? 1.05 : 1.0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: dropTargetId)
                        .draggable(item.id)
                        .dropDestination(for: String.self) { droppedIds, _ in
                            guard let sourceId = droppedIds.first,
                                  sourceId != item.id,
                                  let sourceIdx = localPinnedItems.firstIndex(where: { $0.id == sourceId }),
                                  let destIdx = localPinnedItems.firstIndex(where: { $0.id == item.id })
                            else { return false }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                localPinnedItems.move(
                                    fromOffsets: IndexSet(integer: sourceIdx),
                                    toOffset: destIdx > sourceIdx ? destIdx + 1 : destIdx
                                )
                            }
                            container?.pinService.reorder(items: localPinnedItems)
                            return true
                        } isTargeted: { targeted in
                            dropTargetId = targeted ? item.id : nil
                        }
                }
            }
        }
    }

    /// Removes a pinned item from Home and mirrors it locally for instant feedback.
    private func unpin(_ item: PinnedItem) {
        guard item.serverId == container?.serverState.activeServer?.id else { return }
        guard let type = PinnedItemType(rawValue: item.itemType) else { return }
        HapticFeedback.light.trigger()
        container?.pinService.unpin(itemType: type, itemId: item.itemId)
        withAnimation(LumaAnimation.chrome) {
            localPinnedItems.removeAll { $0.id == item.id }
        }
    }

    // MARK: - Library section

    private var librarySection: some View {
        VStack(spacing: 0) {
            NavigationLink(value: HomeDestination.libraryPlaylists) {
                HomeLibraryRowLabel(title: String(localized: "Playlists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "music.note.list")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 40)
            NavigationLink(value: HomeDestination.libraryArtists) {
                HomeLibraryRowLabel(title: String(localized: "Artists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "music.mic")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 40)
            NavigationLink(value: HomeDestination.libraryAlbums) {
                HomeLibraryRowLabel(title: String(localized: "Albums", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "square.stack")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 40)
            NavigationLink(value: HomeDestination.librarySongs) {
                HomeLibraryRowLabel(title: String(localized: "Songs", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "music.note")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 40)
            NavigationLink(value: HomeDestination.libraryDownloads) {
                HomeLibraryRowLabel(title: String(localized: "Downloaded", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Recently section (online = Recently Added, offline = Recently Downloaded)

    @ViewBuilder
    private var recentlySection: some View {
        if isOnline {
            if let vm = viewModel, !vm.recentAlbums.isEmpty || vm.isLoading {
                VStack(alignment: .leading, spacing: LumaSpacing.s) {
                    Text("Recently Added")
                        .font(.lumaSectionTitle)
                    if vm.isLoading && vm.recentAlbums.isEmpty {
                        EmptyView()
                    } else {
                        LazyVGrid(columns: recentColumns, spacing: LumaSpacing.m) {
                            ForEach(vm.recentAlbums) { album in
                                AlbumNavigationLink(album: album, namespace: recentlyAddedZoomNamespace) { sourceID, namespace in
                                    HomeAlbumCell(album: album, sourceID: sourceID, namespace: namespace)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .lumaContentReveal(isReady: !vm.recentAlbums.isEmpty)
            }
        } else {
            VStack(alignment: .leading, spacing: LumaSpacing.s) {
                Text("Recently Downloaded")
                    .font(.lumaSectionTitle)
                if recentDownloadedItems.isEmpty {
                    EmptyStateView(
                        systemImage: "arrow.down.circle",
                        title: "No downloads yet",
                        subtitle: "Albums and playlists you download will appear here"
                    )
                } else {
                    LazyVGrid(columns: recentColumns, spacing: LumaSpacing.m) {
                        ForEach(recentDownloadedItems) { item in
                            let dest: HomeDestination = item.type == .album
                                ? .albumById(id: item.itemId, name: item.name, subtitle: item.subtitle, coverArtId: item.coverArtId)
                                : .playlistById(id: item.itemId, name: item.name, coverArtId: item.coverArtId)
                            HomeDownloadedItemCard(item: item, destination: dest, namespace: downloadsZoomNamespace)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - LibraryFavoriteTile

#if os(iOS)
private struct LibraryFavoriteTile: View {
    enum ShapeKind {
        case rounded, circle
    }

    let title: String
    let subtitle: String?
    let coverArtId: String
    var shape: ShapeKind = .rounded
    var placeholderSystemImage: String = "music.note"
    private let size: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: LumaSpacing.xs) {
            CoverArtView(
                id: coverArtId,
                size: Int(size * 2),
                placeholderSystemImage: placeholderSystemImage
            )
            .frame(width: size, height: size)
            .modifier(LibraryFavoriteCoverShape(shape: shape))

            Text(title)
                .font(.lumaCaption)
                .fontWeight(.semibold)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(width: size, alignment: .leading)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.lumaCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: size, alignment: .leading)
            }
        }
        .frame(width: size, alignment: .leading)
    }
}

private struct LibraryFavoriteCoverShape: ViewModifier {
    let shape: LibraryFavoriteTile.ShapeKind

    func body(content: Content) -> some View {
        switch shape {
        case .rounded:
            content.lumaCoverStyle(cornerRadius: LumaCornerRadius.standard)
        case .circle:
            content.clipShape(Circle())
        }
    }
}
#endif

// MARK: - HomePinnedCard

private struct HomePinnedCard: View {
    let item: PinnedItem
    let namespace: Namespace.ID
    @Environment(\.appContainer) private var container
    @Environment(\.modelContext) private var modelContext
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @Environment(DominantColorExtractor.self) private var colorExtractor
    @State private var coverImage: PlatformImage?

    private var pinnedType: PinnedItemType {
        PinnedItemType(rawValue: item.itemType) ?? .album
    }

    private var homeNavDestination: HomeDestination? {
        switch pinnedType {
        case .album:
            .albumById(id: item.itemId, name: item.displayName, subtitle: item.displaySubtitle, coverArtId: item.coverArtId)
        case .playlist:
            .playlistById(id: item.itemId, name: item.displayName, coverArtId: item.coverArtId)
        case .artist:
            .artistById(id: item.itemId, name: item.displayName, coverArtId: item.coverArtId)
        case .song:
            nil
        }
    }

    var body: some View {
        Group {
            if let destination = homeNavDestination {
                NavigationLink(value: destination.albumZoom(sourceID: item.itemId, namespace: namespace)) {
                    cardLabel
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    playPinnedSong()
                } label: {
                    cardLabel
                }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: "Play", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }
        }
        .onAppear {
            Task { coverImage = await artworkImageCache.load(coverArtId: item.coverArtId ?? item.itemId) }
        }
        .lazyCollectionContextMenu(
            itemType: pinnedType,
            itemId: item.itemId,
            displayName: item.displayName,
            displaySubtitle: item.displaySubtitle,
            coverArtId: item.coverArtId,
            coverImage: coverImage,
            favoriteType: favoriteTypeForPin
        ) {
            try await loadPinnedSongs()
        }
    }

    private var favoriteTypeForPin: FavoriteType? {
        switch pinnedType {
        case .album: .album
        case .song: .song
        case .artist: .artist
        case .playlist: nil
        }
    }

    private var cardLabel: some View {
        VStack(alignment: .leading, spacing: LumaSpacing.xs) {
            GeometryReader { geo in
                artwork(size: geo.size.width)
            }
            .aspectRatio(1, contentMode: .fit)
            .lumaMatchedTransitionSource(id: item.itemId, in: namespace)
            Text(item.displayName)
                .font(.lumaCaption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func artwork(size: CGFloat) -> some View {
        switch pinnedType {
        case .playlist:
            PlaylistCoverThumbnail(
                playlistId: item.itemId,
                serverId: item.serverId,
                coverArtId: item.coverArtId ?? item.itemId,
                title: item.displayName,
                size: size
            )
        case .artist:
            CoverArtView(id: item.coverArtId ?? item.itemId, size: Int(size * 2), placeholderSystemImage: "person.fill")
                .frame(width: size, height: size)
                .clipShape(Circle())
        case .album, .song:
            CoverArtView(id: item.coverArtId ?? item.itemId, size: Int(size * 2))
                .frame(width: size, height: size)
                .lumaCoverStyle(cornerRadius: LumaCornerRadius.standard)
        }
    }

    private func playPinnedSong() {
        Task {
            let song = DisplayableSong(
                id: item.itemId,
                title: item.displayName,
                artist: item.displaySubtitle.isEmpty ? nil : item.displaySubtitle,
                isDownloaded: isAvailableOfflineSong(item.itemId),
                coverArtId: item.coverArtId
            )
            do {
                try await container?.playerService.play(tracks: [song], startIndex: 0)
            } catch {
                Logger.player.error("[PLAYBACK] pinned song play failed: \(error, privacy: .public)")
            }
        }
    }

    private func isAvailableOfflineSong(_ songId: String) -> Bool {
        let sid = item.serverId
        let descriptor = FetchDescriptor<DownloadedTrack>(predicate: #Predicate { $0.songId == songId && $0.serverId == sid })
        return (try? modelContext.fetch(descriptor).first) != nil
    }

    private func loadPinnedSongs() async throws -> [DisplayableSong] {
        guard let container else { return [] }
        let sid = item.serverId
        let identity = try container.serverState.requestIdentity(for: sid)
        let songs = try await resolvePinnedSongs(container, serverId: sid)
        guard container.serverState.requestIsCurrent(identity), !Task.isCancelled else { throw CancellationError() }
        return songs
    }

    private func resolvePinnedSongs(_ container: AppContainer, serverId sid: UUID) async throws -> [DisplayableSong] {
        let itemId = item.itemId
        switch pinnedType {
        case .album:
            if container.serverState.isOnline, let detail = try? await container.libraryService.album(id: itemId) {
                return (detail.song ?? []).map { DisplayableSong(from: $0) }
            }
            return await container.downloadService.localAlbumData(albumId: itemId, serverId: sid)?.songs ?? []
        case .playlist:
            if container.serverState.isOnline, let detail = try? await container.libraryService.playlist(id: itemId) {
                return (detail.entry ?? []).map { DisplayableSong(from: $0) }
            }
            return await container.downloadService.localPlaylistData(playlistId: itemId, serverId: sid)?.songs ?? []
        case .song:
            let downloaded = await container.downloadService.isDownloaded(songId: itemId, serverId: sid)
            return [DisplayableSong(id: itemId, title: item.displayName,
                artist: item.displaySubtitle.isEmpty ? nil : item.displaySubtitle,
                isDownloaded: downloaded, coverArtId: item.coverArtId)]
        case .artist:
            if container.serverState.isOnline, let artist = try? await container.libraryService.artist(id: itemId) {
                var songs: [DisplayableSong] = []
                for album in (artist.album ?? []).prefix(5) {
                    try Task.checkCancellation()
                    guard container.serverState.activeServer?.id == sid else { throw CancellationError() }
                    if let detail = try? await container.libraryService.album(id: album.id) {
                        songs.append(contentsOf: (detail.song ?? []).map { DisplayableSong(from: $0) })
                    }
                    if songs.count >= 40 { break }
                }
                return songs
            }
            let usable = await container.downloadService.downloadedSongIds(serverId: sid)
            let tracks = (try? modelContext.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
                $0.artistId == itemId && $0.serverId == sid
            }))) ?? []
            return tracks.filter { usable.contains($0.songId) }.map { DisplayableSong(from: $0) }
        }
    }

}

// MARK: - HomeLibraryRowLabel

private struct HomeLibraryRowLabel: View {
    let title: String
    let systemImage: String

    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = 28

    var body: some View {
        HStack(spacing: LumaSpacing.m) {
            Image(systemName: systemImage)
                .font(.title3)
                .fontWeight(.regular)
                .foregroundStyle(.primary)
                .frame(width: iconSide, height: iconSide)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .fontWeight(.regular)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, LumaSpacing.s)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - HomeDownloadedItemCard

private struct HomeDownloadedItemCard: View {
    let item: DownloadedItem
    let destination: HomeDestination
    let namespace: Namespace.ID
    @Environment(\.appContainer) private var container
    @Environment(\.modelContext) private var modelContext
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var coverImage: PlatformImage?

    var body: some View {
        NavigationLink(value: destination.albumZoom(sourceID: item.id, namespace: namespace)) {
            VStack(alignment: .leading, spacing: LumaSpacing.xs) {
                GeometryReader { geo in
                    if item.type == .playlist {
                        PlaylistCoverThumbnail(playlistId: item.itemId, serverId: item.serverId, coverArtId: item.coverArtId ?? item.itemId, title: item.name, size: geo.size.width)
                    } else {
                        CoverArtView(id: item.coverArtId ?? item.itemId, size: Int(geo.size.width * 2))
                            .frame(width: geo.size.width, height: geo.size.width)
                            .lumaCoverStyle(cornerRadius: LumaCornerRadius.standard)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .lumaMatchedTransitionSource(id: item.id, in: namespace)
                Text(item.name)
                    .font(.lumaCaption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.lumaCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: item.id + item.serverId.uuidString + (item.coverArtId ?? item.itemId)) {
            let image = await artworkImageCache.load(coverArtId: item.coverArtId ?? item.itemId)
            guard !Task.isCancelled else { return }
            coverImage = image
        }
        .lazyCollectionContextMenu(
            itemType: item.type == .album ? .album : .playlist,
            itemId: item.itemId,
            displayName: item.name,
            displaySubtitle: item.subtitle,
            coverArtId: item.coverArtId,
            coverImage: coverImage,
            favoriteType: item.type == .album ? .album : nil
        ) {
            guard let container, item.serverId == container.serverState.activeServer?.id else { return [] }
            switch item.type {
            case .album:
                return await container.downloadService.localAlbumData(albumId: item.itemId, serverId: item.serverId)?.songs ?? []
            case .playlist:
                return await container.downloadService.localPlaylistData(playlistId: item.itemId, serverId: item.serverId)?.songs ?? []
            }
        }
    }
}

// MARK: - DownloadedItem

private nonisolated struct DownloadedItem: Identifiable, Sendable {
    nonisolated enum ItemType: Sendable {
        case album
        case playlist
    }
    let id: String
    let itemId: String
    let type: ItemType
    let name: String
    let subtitle: String
    let coverArtId: String?
    let downloadedAt: Date
    let serverId: UUID
}

// MARK: - HomeAlbumCell

private struct HomeAlbumCell: View {
    let album: AlbumID3
    let sourceID: String
    let namespace: Namespace.ID

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var coverImage: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: LumaSpacing.xs) {
            GeometryReader { geo in
                CoverArtView(id: album.coverArt ?? album.id, size: Int(geo.size.width * 2))
                    .frame(width: geo.size.width, height: geo.size.width)
                    .lumaCoverStyle(cornerRadius: LumaCornerRadius.standard)
            }
            .aspectRatio(1, contentMode: .fit)
            .lumaMatchedTransitionSource(id: sourceID, in: namespace)
            Text(album.name)
                .foregroundStyle(.primary)
                .font(.lumaCaption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let artist = album.artist {
                Text(artist)
                    .font(.lumaCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .task(id: album.id) {
            coverImage = await artworkImageCache.load(coverArtId: album.coverArt ?? album.id)
        }
        .lazyCollectionContextMenu(
            itemType: .album,
            itemId: album.id,
            displayName: album.name,
            displaySubtitle: album.artist ?? "",
            coverArtId: album.coverArt,
            coverImage: coverImage,
            favoriteType: .album
        ) {
            let detail = try await container?.libraryService.album(id: album.id)
            return (detail?.song ?? []).map { DisplayableSong(from: $0) }
        }
    }
}

#if os(iOS)
/// Registers `HomeDestination` only when no parent stack already owns that type.
private struct HomeDestinationRegistrar: ViewModifier {
    let enabled: Bool
    let recentlyAddedZoomNamespace: Namespace.ID
    let playlistZoomNamespace: Namespace.ID
    let pinnedZoomNamespace: Namespace.ID

    func body(content: Content) -> some View {
        if enabled {
            content.navigationDestination(for: HomeDestination.self) { destination in
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
                    PlaylistListView(zoomNamespace: playlistZoomNamespace)
                case .libraryFavorites:
                    FavoritesView()
                case .libraryDownloads:
                    DownloadedView()
                case .albumPush(let id, let name, let coverArtId, _):
                    AlbumDetailView(albumId: id, albumName: name, coverArtId: coverArtId)
                case .album(let album):
                    AlbumDetailView(
                        album: album,
                        coverArtId: album.coverArt
                    )
                case .artist(let artist):
                    ArtistDetailView(artist: artist)
                case .playlist(let playlist):
                    PlaylistDetailView(
                        playlist: playlist,
                        coverArtId: playlist.coverArt ?? playlist.id,
                        zoomSourceId: playlist.id,
                        zoomNamespace: playlistZoomNamespace
                    )
                case .downloadedAlbum(let display):
                    AlbumDetailView(
                        albumId: display.albumId,
                        albumName: display.name,
                        coverArtId: display.coverArtId,
                        mode: .downloadedOnly
                    )
                case .albumById(let id, let name, _, let coverArtId):
                    AlbumDetailView(
                        albumId: id,
                        albumName: name,
                        coverArtId: coverArtId
                    )
                case .playlistById(let id, let name, let coverArtId):
                    PlaylistDetailView(
                        playlistId: id,
                        name: name,
                        coverArtId: coverArtId,
                        zoomSourceId: id,
                        zoomNamespace: pinnedZoomNamespace
                    )
                case .artistById(let id, let name, let coverArtId):
                    ArtistDetailView(artist: ArtistID3(id: id, name: name, coverArt: coverArtId))
                case .artistPush(let id, let name, let coverArtId, _):
                    ArtistDetailView(artist: ArtistID3(id: id, name: name, coverArt: coverArtId))
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
        } else {
            content
        }
    }
}
#endif
