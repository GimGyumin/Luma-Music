// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData
import SwiftSonic
import OSLog
import AppIntents

struct PlaylistListView: View {
    let zoomNamespace: Namespace.ID?
    @Environment(\.appContainer) private var container
    @State private var viewModel: PlaylistListViewModel?
    @State private var showCreateSheet = false
    @State private var searchText = ""
    @State private var playlistFilter: PlaylistLibraryFilter
    @AppStorage("luma.playlistSort") private var playlistSort: PlaylistSort = .title
    @Query private var downloadedPlaylists: [DownloadedPlaylist]

    init(zoomNamespace: Namespace.ID? = nil, initialFilter: PlaylistLibraryFilter = .all) {
        self.zoomNamespace = zoomNamespace
        _playlistFilter = State(initialValue: initialFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            macHeader
            #endif

            Group {
                if let vm = viewModel {
                    content(vm)
                        .transition(.opacity)
                } else {
                    LoadingStateView()
                }
            }
            .lumaContentReveal(isReady: viewModel.map { !($0.isLoading && $0.playlists.isEmpty) } ?? false)
            #if os(iOS)
            .navigationTitle(String(localized: "Playlists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            .navigationBarTitleDisplayModeLarge()
            .lumaLibrarySearch(
                text: $searchText,
                prompt: String(localized: "Search Playlists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(.primary)
                    }
                    .disabled(container?.serverState.isOnline != true)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort By", selection: $playlistSort) {
                            ForEach(PlaylistSort.allCases, id: \.self) { sort in
                                Label(sort.label, systemImage: sort.systemImage).tag(sort)
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .renderingMode(.original)
                            .foregroundStyle(.primary)
                    }
                    .tint(.primary)
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Sort playlists")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Playlists", selection: $playlistFilter) {
                            ForEach(PlaylistLibraryFilter.allCases, id: \.self) { filter in
                                Label(filter.label, systemImage: filter.systemImage).tag(filter)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .renderingMode(.original)
                            .foregroundStyle(.primary)
                    }
                    .tint(.primary)
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Filter playlists")
                }
            }
            #endif
        }
        .lumaContentWidth()
        .tint(.primary)
        .sheet(isPresented: $showCreateSheet) {
            CreatePlaylistSheet { _ in
                Task { await viewModel?.load() }
            }
        }
        .task(id: container?.serverState.isOnline) {
            guard let svc = container?.libraryService else { return }
            if viewModel == nil { viewModel = PlaylistListViewModel(libraryService: svc) }
            guard container?.serverState.isOnline == true else { return }
            await viewModel?.load()
        }
        // Deleting a playlist from a detail surface posts this — reload so the list reflects it on return,
        // without a blanket `.onAppear` reload (which would re-fetch on every navigation).
        .onReceive(NotificationCenter.default.publisher(for: .lumaPlaylistDeleted)) { _ in
            Task { await viewModel?.load() }
        }
    }

    #if os(macOS)
    private var macHeader: some View {
        MacLibraryHeader(
            title: String(localized: "Playlists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            searchText: $searchText,
            searchPrompt: String(localized: "Search Playlists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        ) {
            MacLibraryHeaderButton(
                systemImage: "plus",
                help: String(localized: "New Playlist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                action: { showCreateSheet = true }
            )
            .disabled(container?.serverState.isOnline != true)

            Menu {
                Picker("Sort By", selection: $playlistSort) {
                    ForEach(PlaylistSort.allCases, id: \.self) { sort in
                        Label(sort.label, systemImage: sort.systemImage).tag(sort)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Sort playlists"))

            Menu {
                Picker("Playlists", selection: $playlistFilter) {
                    ForEach(PlaylistLibraryFilter.allCases, id: \.self) { filter in
                        Label(filter.label, systemImage: filter.systemImage).tag(filter)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Filter playlists"))
        }
    }
    #endif

    @ViewBuilder
    private func content(_ vm: PlaylistListViewModel) -> some View {
        VStack(spacing: 0) {
            if vm.isLoading && vm.playlists.isEmpty {
                LoadingStateView()
            } else if container?.serverState.isOnline == false && vm.playlists.isEmpty {
                if let serverId = container?.serverState.activeServer?.id {
                    OfflinePlaylistContent(serverId: serverId)
                } else {
                    EmptyStateView(
                        systemImage: "wifi.slash",
                        title: "You're Offline",
                        subtitle: "Connect to your server to browse playlists."
                    )
                }
            } else if let error = vm.error, vm.playlists.isEmpty {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "Unable to Load Playlists",
                    subtitle: error.displayMessage,
                    action: .init(label: "Retry") { Task { await vm.load() } }
                )
            } else if vm.playlists.isEmpty {
                EmptyStateView(
                    systemImage: "list.bullet",
                    title: "No Playlists",
                    subtitle: "Create playlists on your server to see them here."
                )
            } else {
                #if os(macOS)
                playlistGrid(vm)
                    .transition(.opacity)
                #else
                playlistList(vm)
                    .transition(.opacity)
                #endif
            }
        }
    }

    #if os(macOS)
    @ViewBuilder
    private func playlistGrid(_ vm: PlaylistListViewModel) -> some View {
        let playlists = displayedPlaylists(vm.playlists)
        GeometryReader { geo in
            let columns = MacDesign.Grid.columns(for: geo.size.width)
            ScrollView {
                if playlists.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: MacDesign.Metrics.albumGridRowGap) {
                        ForEach(playlists) { playlist in
                            NavigationLink(value: HomeDestination.playlist(playlist)) {
                                OnlinePlaylistRow(playlist: playlist, style: .grid)
                                    .appEntityIdentifier(playlistEntityIdentifier(playlist))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, MacDesign.Metrics.libraryGridInset)
                    .padding(.top, 8)
                }
            }
            .refreshable { await vm.load() }
            .miniPlayerBottomMargin()
        }
    }

    private static func gridColumnCount(for width: CGFloat) -> Int {
        switch width {
        case ..<560:  return 2
        case ..<700:  return 3
        case ..<1300: return 4
        default:      return 5
        }
    }
    #endif

    @ViewBuilder
    private func playlistList(_ vm: PlaylistListViewModel) -> some View {
        let playlists = displayedPlaylists(vm.playlists)
        List {
            if playlists.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowSeparator(.hidden)
            }

            ForEach(playlists) { playlist in
                NavigationLink(value: HomeDestination.playlist(playlist)) {
                    OnlinePlaylistRow(
                        playlist: playlist,
                        namespace: zoomNamespace,
                        onActionCompleted: { Task { await vm.load() } }
                    )
                    .appEntityIdentifier(playlistEntityIdentifier(playlist))
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await vm.load()
        }
        .miniPlayerBottomMargin()
    }

    private func displayedPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped: [Playlist] = {
            guard playlistFilter == .downloads,
                  let serverId = container?.serverState.activeServer?.id else { return playlists }
            let ids = Set(downloadedPlaylists.lazy.filter { $0.serverId == serverId }.map(\.playlistId))
            return playlists.filter { ids.contains($0.id) }
        }()
        let filtered = query.isEmpty ? scoped : scoped.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.owner?.localizedCaseInsensitiveContains(query) == true)
        }
        return playlistSort.sorted(filtered)
    }

    private func playlistEntityIdentifier(_ playlist: Playlist) -> EntityIdentifier? {
        guard #available(iOS 27.0, macOS 27.0, *) else { return nil }
        return OnscreenEntityAnnotation.playlistIdentifier(
            id: playlist.id,
            title: playlist.name,
            trackCount: playlist.songCount,
            serverId: container?.serverState.activeServer?.id
        )
    }
}

enum PlaylistLibraryFilter: String, CaseIterable {
    case all
    case downloads

    var label: String {
        switch self {
        case .all: return "All Playlists"
        case .downloads: return "Downloaded"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "music.note.list"
        case .downloads: return "arrow.down.circle"
        }
    }
}

private enum PlaylistSort: String, CaseIterable {
    case title
    case recentlyUpdated
    case recentlyCreated

    var label: String {
        switch self {
        case .title: return "Title"
        case .recentlyUpdated: return "Recently Updated"
        case .recentlyCreated: return "Date Added"
        }
    }

    var systemImage: String {
        switch self {
        case .title: return "textformat"
        case .recentlyUpdated: return "clock.arrow.circlepath"
        case .recentlyCreated: return "calendar"
        }
    }

    func sorted(_ playlists: [Playlist]) -> [Playlist] {
        switch self {
        case .title:
            return playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .recentlyUpdated:
            return playlists.sorted { ($0.changed ?? .distantPast) > ($1.changed ?? .distantPast) }
        case .recentlyCreated:
            return playlists.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        }
    }
}

// MARK: - Online playlist row

private enum PlaylistRowStyle {
    case row
    case grid
}

private struct OnlinePlaylistRow: View {
    let playlist: Playlist
    var namespace: Namespace.ID? = nil
    var style: PlaylistRowStyle = .row
    var onActionCompleted: (() -> Void)? = nil

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var coverImage: PlatformImage?
    @State private var showDeleteConfirm = false
    /// Drives the delete dialog's "playlist only / + downloads" choice — present only when the playlist has a
    /// downloaded copy on this device.
    @Query private var downloadedMatches: [DownloadedPlaylist]

    init(playlist: Playlist, namespace: Namespace.ID? = nil, style: PlaylistRowStyle = .row, onActionCompleted: (() -> Void)? = nil) {
        self.playlist = playlist
        self.namespace = namespace
        self.style = style
        self.onActionCompleted = onActionCompleted
        let pid = playlist.id
        _downloadedMatches = Query(filter: #Predicate<DownloadedPlaylist> { $0.playlistId == pid })
    }

    var body: some View {
        Group {
            if style == .grid {
                gridBody
            } else {
                rowBody
            }
        }
        .task(id: playlist.id) {
            coverImage = await artworkImageCache.load(coverArtId: playlist.coverArt ?? playlist.id)
        }
        .collectionContextMenu(
            itemType: .playlist,
            itemId: playlist.id,
            displayName: playlist.name,
            displaySubtitle: "Playlist",
            coverArtId: playlist.coverArt,
            coverImage: coverImage,
            onDelete: { showDeleteConfirm = true }
        )
        .deletePlaylistConfirmation(
            playlistName: playlist.name,
            isPresented: $showDeleteConfirm,
            hasDownloads: !downloadedMatches.isEmpty
        ) { purgeDownloads in
            Task {
                guard let container else { return }
                do {
                    // The service deletes server-side first and rolls its own cache back on failure, so it is
                    // safe to refresh the (server-fresh) list only AFTER a confirmed success.
                    try await container.playlistService.deletePlaylist(id: playlist.id, purgeDownloads: purgeDownloads)
                    onActionCompleted?()
                    container.toastService.showConfirmation("Playlist deleted")
                } catch {
                    // Server refused / unreachable: surface it and leave the playlist in place. Do NOT refresh
                    // or remove anything locally — the deletion never happened.
                    Logger.playlist.error("[PLAYLIST] delete failed id=\(playlist.id, privacy: .public): \(error, privacy: .public)")
                    container.toastService.showError("Couldn't delete playlist. Please try again.")
                }
            }
        }
    }

    private var rowBody: some View {
        HStack(spacing: LumaSpacing.m) {
            PlaylistCoverThumbnail(playlistId: playlist.id, serverId: nil, coverArtId: playlist.coverArt ?? playlist.id, title: playlist.name, size: 56)
                .lumaMatchedTransitionSource(id: playlist.id, in: namespace)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.lumaCellTitle)
                    .lineLimit(1)
                Text(LumaCountLabel.tracks(playlist.songCount))
                    .font(.lumaCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, LumaSpacing.xs)
    }

    private var gridBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                PlaylistCoverThumbnail(
                    playlistId: playlist.id,
                    serverId: nil,
                    coverArtId: playlist.coverArt ?? playlist.id,
                    title: playlist.name,
                    size: max(1, geometry.size.width)
                )
                .lumaMatchedTransitionSource(id: playlist.id, in: namespace)
            }
            .aspectRatio(1, contentMode: .fit)

            Text(playlist.name)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(LumaCountLabel.tracks(playlist.songCount))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Offline Playlists

private struct OfflinePlaylistContent: View {
    let serverId: UUID
    @Query private var playlists: [DownloadedPlaylist]

    init(serverId: UUID) {
        self.serverId = serverId
        let sid = serverId
        _playlists = Query(
            filter: #Predicate<DownloadedPlaylist> { playlist in playlist.serverId == sid },
            sort: [SortDescriptor(\DownloadedPlaylist.name)]
        )
    }

    var body: some View {
        if playlists.isEmpty {
            EmptyStateView(
                systemImage: "wifi.slash",
                title: "You're Offline",
                subtitle: "No downloaded playlists available. Download playlists while online to listen offline."
            )
        } else {
            List {
                Section("Downloaded Playlists") {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: HomeDestination.playlistById(id: playlist.playlistId, name: playlist.name, coverArtId: playlist.coverArtId)) {
                            OfflinePlaylistRow(playlist: playlist)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

private struct OfflinePlaylistRow: View {
    let playlist: DownloadedPlaylist

    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var coverImage: PlatformImage?

    var body: some View {
        HStack(spacing: LumaSpacing.m) {
            PlaylistCoverThumbnail(playlistId: playlist.playlistId, serverId: nil, coverArtId: playlist.coverArtId ?? playlist.playlistId, title: playlist.name, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.lumaCellTitle)
                    .lineLimit(1)
                Text(LumaCountLabel.tracks(playlist.tracksCount))
                    .font(.lumaCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, LumaSpacing.xs)
        .task(id: playlist.playlistId) {
            coverImage = await artworkImageCache.load(coverArtId: playlist.coverArtId ?? playlist.playlistId)
        }
        .collectionContextMenu(
            itemType: .playlist,
            itemId: playlist.playlistId,
            displayName: playlist.name,
            displaySubtitle: "Playlist",
            coverArtId: playlist.coverArtId,
            coverImage: coverImage
        )
    }
}
