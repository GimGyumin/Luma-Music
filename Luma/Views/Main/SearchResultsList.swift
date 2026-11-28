import SwiftUI
import OSLog

struct SearchResultsList: View {
    @Namespace private var albumZoomNamespace
    let viewModel: SearchViewModel
    let category: SearchCategory
    let query: String
    let showsSuggestions: Bool
    let downloadsOnly: Bool
    let onSuggestion: (String) -> Void
    let onRetry: () async -> Void

    @Environment(\.appContainer) private var container
    @State private var songToAdd: DisplayableSong?
    @State private var completedDownloads: Set<String> = []
    @State private var pendingDownloads: Set<String> = []

    private var resultRowInsets: EdgeInsets {
        #if os(macOS)
        EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16)
        #else
        EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20)
        #endif
    }
    private var rowSeparatorLeading: CGFloat {
        #if os(macOS)
        56
        #else
        74
        #endif
    }
    private var suggestionVerticalPadding: CGFloat {
        #if os(macOS)
        8
        #else
        12
        #endif
    }
    private var moreButtonSize: CGFloat {
        #if os(macOS)
        28
        #else
        44
        #endif
    }

    private var items: [SearchResultItem] {
        let filter: SearchCategory = showsSuggestions && !downloadsOnly ? .all : category
        guard filter != .all else { return viewModel.rankedItems }
        return viewModel.rankedItems.filter {
            switch $0 {
            case .song: filter == .songs
            case .artist: filter == .artists
            case .album: filter == .albums
            case .playlist: filter == .playlists
            }
        }
    }

    var body: some View {
        let rows = items
        List {
            if showsSuggestions {
                ForEach(viewModel.suggestions, id: \.self) { suggestion in
                    Button { onSuggestion(suggestion) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "magnifyingglass")
                                #if os(macOS)
                                .font(.system(size: 14))
                                #else
                                .font(.title2)
                                #endif
                            Text(suggestion)
                                #if os(macOS)
                                .font(.system(size: 13))
                                #else
                                .font(.title3)
                                #endif
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, suggestionVerticalPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if viewModel.isLocalOnly && !downloadsOnly {
                Text(String(localized: "Searching downloads and indexed music. The server is unreachable.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(rows) { item in
                resultRow(item)
                    .listRowInsets(resultRowInsets)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in rowSeparatorLeading }
            }
            if viewModel.isSearching {
                progressRow
            } else if let error = viewModel.searchError {
                VStack(spacing: 10) {
                    Text(error.localizedDescription).font(.footnote).foregroundStyle(.secondary)
                    Button("Retry") {
                        Task {
                            if viewModel.searchResults == nil { await onRetry() }
                            else { await viewModel.loadMore(category: category) }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            } else if viewModel.isIndexing && viewModel.searchResults == nil {
                progressRow
            } else if rows.isEmpty {
                EmptyStateView(systemImage: "magnifyingglass", title: "No results", subtitle: "Try a different search term.")
                    .listRowSeparator(.hidden)
            }
            if viewModel.canLoadMore(category), viewModel.searchError == nil {
                Button {
                    Task { await viewModel.loadMore(category: category) }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isLoadingMore { ProgressView() }
                        else { Text(String(localized: "Load More", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) }
                        Spacer()
                    }
                    .padding(.vertical, 14)
                }
                .disabled(viewModel.isLoadingMore)
                .listRowSeparator(.hidden)
                .onAppear { Task { await viewModel.loadMore(category: category) } }
            }
        }
        .listStyle(.plain)
        .tint(.primary)
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $songToAdd) { AddToPlaylistSheet(song: $0) }
    }

    private var progressRow: some View {
        HStack { Spacer(); ProgressView(); Spacer() }
            .padding(.vertical, 18).listRowSeparator(.hidden)
    }

    @ViewBuilder private func resultRow(_ item: SearchResultItem) -> some View {
        switch item {
        case .song(let song):
            HStack(spacing: 0) {
                Button { play(song) } label: { SearchResultLabel(item: item) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("search.song.play.\(song.id)")
                Menu {
                    Button("Play", systemImage: "play.fill") { play(song) }
                    Button {
                        Task { await container?.playerService.playNext(song) }
                    } label: {
                        DestinationMenuLabel.playNext(after: container?.playerState.currentTrack?.title)
                    }
                    Button {
                        Task { await container?.playerService.addToQueue(song) }
                    } label: {
                        DestinationMenuLabel.addToQueue(systemImage: "text.badge.plus")
                    }
                    Button {
                        songToAdd = song
                    } label: {
                        DestinationMenuLabel.addToPlaylist()
                    }
                    Button(song.isDownloaded || completedDownloads.contains(song.id) ? "Downloaded" : "Download",
                           systemImage: "arrow.down.circle") {
                        guard let container, let serverID = container.serverState.activeServer?.id else { return }
                        pendingDownloads.insert(song.id)
                        Task {
                            defer { pendingDownloads.remove(song.id) }
                            do {
                                try await container.downloadService.download(song: song.asSong(), serverId: serverID)
                                completedDownloads.insert(song.id)
                            } catch {
                                container.toastService.showError(UserFacingError.downloadFailed.displayMessage)
                            }
                        }
                    }
                    .disabled(song.isDownloaded || completedDownloads.contains(song.id) || pendingDownloads.contains(song.id))
                    .accessibilityIdentifier("search.song.download.\(song.id)")

                    Divider()

                    Button {
                        postNavigateToAlbum(track: song)
                    } label: {
                        Label("Go to Album", systemImage: "square.stack")
                    }
                    .disabled(song.albumId == nil)
                    .accessibilityIdentifier("search.song.goToAlbum.\(song.id)")

                    Button {
                        postNavigateToArtist(track: song)
                    } label: {
                        Label("Go to Artist", systemImage: "music.mic")
                    }
                    .disabled(song.artistId == nil)
                    .accessibilityIdentifier("search.song.goToArtist.\(song.id)")
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: moreButtonSize, height: moreButtonSize).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .tint(.primary)
                .foregroundStyle(.primary)
                .accessibilityLabel(String(localized: "More Options", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .accessibilityValue(song.isDownloaded || completedDownloads.contains(song.id)
                    ? String(localized: "Downloaded", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : song.title)
                .accessibilityIdentifier("search.song.more.\(song.id)")
            }
            .songLongPressMenu(song)
        case .artist(let artist):
            NavigationLink(value: SearchHistoryNavTarget(itemId: artist.id, itemType: "artist", displayName: artist.name, coverArtId: artist.coverArtId)) {
                SearchResultLabel(item: item)
            }
        case .album(let album):
            NavigationLink(value: HomeDestination.albumById(id: album.id, name: album.name, subtitle: album.artist ?? "", coverArtId: album.coverArtId)
                .albumZoom(sourceID: album.id, namespace: albumZoomNamespace)) {
                SearchResultLabel(item: item, zoomSourceID: album.id, zoomNamespace: albumZoomNamespace)
            }
            .albumLongPressMenu(id: album.id, name: album.name, coverArtId: album.coverArtId)
        case .playlist(let playlist):
            #if os(macOS)
            NavigationLink {
                PlaylistDetailMacOS(playlistId: playlist.id, name: playlist.name, coverArtId: playlist.coverArtId)
            } label: {
                SearchResultLabel(item: item)
            }
            .playlistLongPressMenu(id: playlist.id, name: playlist.name, coverArtId: playlist.coverArtId)
            #else
            NavigationLink { PlaylistDetailView(playlistId: playlist.id, name: playlist.name) } label: {
                SearchResultLabel(item: item)
            }
            .playlistLongPressMenu(id: playlist.id, name: playlist.name, coverArtId: playlist.coverArtId)
            #endif
        }
    }

    private func play(_ song: DisplayableSong) {
        let songs = viewModel.songs
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        Task {
            do {
                try await container?.playerService.play(tracks: songs, startIndex: index)
            }
            catch { Logger.player.error("[SEARCH] play failed: \(error, privacy: .public)") }
        }
    }
}
