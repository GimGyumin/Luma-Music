// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData

struct DownloadedView: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        Group {
            if let serverId = container?.serverState.activeServer?.id {
                DownloadedContent(serverId: serverId)
            } else {
                EmptyStateView(
                    systemImage: "arrow.down.circle",
                    title: "No Server",
                    subtitle: "Connect to a server to manage downloads."
                )
            }
        }
        .lumaContentWidth()
        .navigationTitle(String(localized: "Downloaded", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .navigationBarTitleDisplayModeInline()
    }
}

// MARK: - Content

private struct DownloadedContent: View {
    @Namespace private var albumZoomNamespace
    let serverId: UUID
    @Query private var albums: [DownloadedAlbum]
    @Query private var playlists: [DownloadedPlaylist]
    @Query private var tracks: [DownloadedTrack]
    @Query private var cachedTracks: [CachedTrack]

    init(serverId: UUID) {
        self.serverId = serverId
        let sid = serverId
        _albums = Query(
            filter: #Predicate<DownloadedAlbum> { album in album.serverId == sid },
            sort: [SortDescriptor(\DownloadedAlbum.name)]
        )
        _playlists = Query(
            filter: #Predicate<DownloadedPlaylist> { playlist in playlist.serverId == sid },
            sort: [SortDescriptor(\DownloadedPlaylist.name)]
        )
        _tracks = Query(filter: #Predicate<DownloadedTrack> { track in track.serverId == sid })
        _cachedTracks = Query(filter: #Predicate<CachedTrack> { track in track.serverId == sid })
    }

    private var displayAlbums: [DownloadedAlbumDisplay] {
        DownloadedAlbumMerger.merge(records: albums, tracks: tracks)
    }

    private var recentItems: [DownloadedRecentItem] {
        let albumItems = displayAlbums.map { display in
            DownloadedRecentItem(
                id: "album-\(display.albumId)",
                title: display.name,
                subtitle: display.artist ?? String(localized: "Album", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                coverArtId: display.coverArtId ?? display.albumId,
                downloadedAt: albums.first(where: { $0.albumId == display.albumId })?.downloadedAt
                    ?? tracks.filter { $0.albumId == display.albumId }.map(\.downloadedAt).max()
                    ?? .distantPast,
                destination: .downloadedAlbum(display)
            )
        }
        let playlistItems = playlists.map { playlist in
            DownloadedRecentItem(
                id: "playlist-\(playlist.playlistId)",
                title: playlist.name,
                subtitle: String(localized: "Playlist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                coverArtId: playlist.coverArtId ?? playlist.playlistId,
                downloadedAt: playlist.downloadedAt,
                destination: .playlistById(id: playlist.playlistId, name: playlist.name, coverArtId: playlist.coverArtId)
            )
        }
        return (albumItems + playlistItems).sorted { $0.downloadedAt > $1.downloadedAt }
    }

    var body: some View {
        if displayAlbums.isEmpty && playlists.isEmpty && tracks.isEmpty && cachedTracks.isEmpty {
            EmptyStateView(
                systemImage: "arrow.down.circle",
                title: "Nothing downloaded",
                subtitle: "Albums and playlists you download will be available here, even offline."
            )
        } else {
            #if os(macOS)
            downloadedListMacOS
            #else
            downloadedListiOS
            #endif
        }
    }

    #if os(macOS)
    private var downloadedListMacOS: some View {
        ScrollViewReader { proxy in
            List {
                if !displayAlbums.isEmpty {
                    Section("Albums") {
                        ForEach(displayAlbums) { display in
                            NavigationLink(value: HomeDestination.downloadedAlbum(display)) {
                                HStack(spacing: LumaSpacing.m) {
                                    CoverArtCard(id: display.coverArtId ?? display.albumId, size: 56)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(display.name)
                                            .font(.lumaCellTitle)
                                            .lineLimit(1)
                                        if let artist = display.artist {
                                            Text(artist)
                                                .font(.lumaCellSubtitle)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Text(LumaCountLabel.tracks(display.downloadedTracksCount))
                                            .font(.lumaCaption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, LumaSpacing.xs)
                            }
                            .id(display.id)
                            .albumLongPressMenu(
                                id: display.albumId,
                                name: display.name,
                                artist: display.artist,
                                coverArtId: display.coverArtId
                            )
                        }
                    }
                }

                if !playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists) { playlist in
                            NavigationLink(value: HomeDestination.playlistById(id: playlist.playlistId, name: playlist.name, coverArtId: playlist.coverArtId)) {
                                HStack(spacing: LumaSpacing.m) {
                                    CoverArtCard(id: playlist.coverArtId ?? playlist.playlistId, size: 56)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(.lumaCellTitle)
                                            .lineLimit(1)
                                        Text(
                                            playlist.isComplete
                                                ? LumaCountLabel.tracks(playlist.tracksCount)
                                                : String(localized: "\(LumaCountLabel.tracks(playlist.tracksCount)) (incomplete)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                                        )
                                            .font(.lumaCaption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, LumaSpacing.xs)
                            }
                            .playlistLongPressMenu(
                                id: playlist.playlistId,
                                name: playlist.name,
                                coverArtId: playlist.coverArtId
                            )
                        }
                    }
                }
            }
            .listStyle(.plain)
            .miniPlayerBottomMargin()
        }
    }
    #endif

    private var downloadedListiOS: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LumaSpacing.xl) {
                VStack(spacing: 0) {
                    NavigationLink {
                        PlaylistListView(initialFilter: .downloads)
                    } label: {
                        downloadCategoryRow(title: "Playlists", systemImage: "music.note.list")
                    }
                    Divider().padding(.leading, 52)

                    NavigationLink {
                        ArtistListView(initialFilter: .downloads)
                    } label: {
                        downloadCategoryRow(title: "Artists", systemImage: "music.mic")
                    }
                    Divider().padding(.leading, 52)

                    NavigationLink {
                        AlbumsListView(initialFilter: .downloads)
                    } label: {
                        downloadCategoryRow(title: "Albums", systemImage: "square.stack")
                    }
                    Divider().padding(.leading, 52)

                    NavigationLink {
                        SongsListView(initialFilter: .downloads)
                    } label: {
                        downloadCategoryRow(title: "Songs", systemImage: "music.note")
                    }
                }
                .buttonStyle(.plain)

                if !recentItems.isEmpty {
                    VStack(alignment: .leading, spacing: LumaSpacing.m) {
                        Text("Recently Downloaded Items")
                            .font(.title2.bold())

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: LumaSpacing.m)], alignment: .leading, spacing: LumaSpacing.m) {
                            ForEach(recentItems) { item in
                                NavigationLink(value: item.destination.albumZoom(sourceID: item.id, namespace: albumZoomNamespace)) {
                                    VStack(alignment: .leading, spacing: LumaSpacing.xs) {
                                        GeometryReader { geometry in
                                            CoverArtCard(id: item.coverArtId, size: geometry.size.width)
                                        }
                                        .aspectRatio(1, contentMode: .fit)
                                        .lumaMatchedTransitionSource(id: item.id, in: albumZoomNamespace)
                                        Text(item.title).font(.lumaCellTitle).foregroundStyle(.primary).lineLimit(1)
                                        Text(item.subtitle).font(.lumaCellSubtitle).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, LumaSpacing.m)
            .padding(.top, LumaSpacing.s)
        }
        .miniPlayerBottomMargin()
    }

    private func downloadCategoryRow(title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: LumaSpacing.m) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.primary)
                .frame(width: 36)
            Text(title)
                .font(.title2)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

private struct DownloadedRecentItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let coverArtId: String
    let downloadedAt: Date
    let destination: HomeDestination
}
