// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import SwiftData
import OSLog
#if os(iOS)
import UniformTypeIdentifiers
#endif


// MARK: - Download state

nonisolated enum PlaylistDownloadState {
    case notDownloaded
    case partiallyDownloaded(downloaded: Int, total: Int)
    case fullyDownloaded
}

// MARK: - Download progress sub-view

struct PlaylistDownloadProgressView: View {
    let songs: [DisplayableSong]
    let total: Int
    let secondaryColor: Color

    @Query private var downloadedTracks: [DownloadedTrack]

    init(songs: [DisplayableSong], total: Int, serverId: UUID, secondaryColor: Color) {
        self.songs = songs
        self.total = total
        self.secondaryColor = secondaryColor
        let sid = serverId
        _downloadedTracks = Query(filter: #Predicate<DownloadedTrack> { $0.serverId == sid })
    }

    var downloaded: Int {
        let downloadedIds = Set(downloadedTracks.map(\.songId))
        return songs.filter { downloadedIds.contains($0.id) }.count
    }

    var body: some View {
        VStack(spacing: LumaSpacing.xs) {
            if downloaded == 0 {
                HStack(spacing: LumaSpacing.s) {
                    ProgressView().scaleEffect(0.8)
                    Text("Starting download…")
                        .font(.lumaCaption)
                        .foregroundStyle(secondaryColor)
                }
            } else {
                ProgressView(value: Double(downloaded), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .tint(Color.lumaAccent)
                    .frame(maxWidth: 280)
                Text("Downloading \(downloaded)/\(total) tracks")
                    .font(.lumaCaption)
                    .foregroundStyle(secondaryColor)
            }
        }
        .frame(minHeight: 44)
    }
}

// MARK: - Live download indicator rows

/// Sub-view that observes DownloadedTrack changes live via @Query,
/// overriding the isDownloaded flag per row without requiring a VM reload.
struct PlaylistSongRows: View {
    let songs: [DisplayableSong]
    let downloadingIds: Set<String>
    let titleColor: Color
    let secondaryColor: Color
    let showsAlbum: Bool
    let onTap: (Int) -> Void
    let onDownload: ((String) -> Void)?
    let onRemoveDownload: ((String) -> Void)?
    let onRemove: ((Int) -> Void)?
    let onReorder: ((IndexSet, Int) -> Void)?
    let onContextRemove: ((Int) -> Void)?
    let onAddToPlaylist: ((DisplayableSong) -> Void)?
    /// Solid backing applied to EACH row so the rows occlude a fixed full-bleed cover behind the List on
    /// scroll. `nil` = default List row background (the macOS detail has no fixed cover, so it passes nil).
    let rowBackground: Color?

    @Environment(\.appContainer) private var container
    @Query private var downloadedTracks: [DownloadedTrack]
    @Query private var allFavorites: [FavoriteRecord]

    init(songs: [DisplayableSong], serverId: UUID, downloadingIds: Set<String> = [], titleColor: Color = .primary, secondaryColor: Color = .secondary, showsAlbum: Bool = true, onTap: @escaping (Int) -> Void, onDownload: ((String) -> Void)? = nil, onRemoveDownload: ((String) -> Void)? = nil, onRemove: ((Int) -> Void)? = nil, onReorder: ((IndexSet, Int) -> Void)? = nil, onContextRemove: ((Int) -> Void)? = nil, onAddToPlaylist: ((DisplayableSong) -> Void)? = nil, rowBackground: Color? = nil) {
        self.songs = songs
        self.downloadingIds = downloadingIds
        self.titleColor = titleColor
        self.secondaryColor = secondaryColor
        self.showsAlbum = showsAlbum
        self.onTap = onTap
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
        self.onRemove = onRemove
        self.onReorder = onReorder
        self.onContextRemove = onContextRemove
        self.onAddToPlaylist = onAddToPlaylist
        self.rowBackground = rowBackground
        let sid = serverId
        let type = FavoriteType.song.rawValue
        _downloadedTracks = Query(
            filter: #Predicate<DownloadedTrack> { track in
                track.serverId == sid
            }
        )
        // Only song favorites for this server can affect the star in this list.
        // Previously every favorite of every type/server was observed and each
        // row rebuilt a Set from all of them.
        _allFavorites = Query(
            filter: #Predicate<FavoriteRecord> { favorite in
                favorite.serverId == sid && favorite.itemType == type
            }
        )
    }

    var body: some View {
        let downloadedSongIDs = Set(downloadedTracks.map(\.songId))
        let favoriteSongIDs = FavoriteRecord.songIDSet(from: allFavorites)
        if let removeAction = onRemove {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                makeRow(index: index, song: song, downloadedSongIDs: downloadedSongIDs,
                        favoriteSongIDs: favoriteSongIDs)
                    .listRowBackground(rowBackground)
            }
            .onDelete { indexSet in
                for index in indexSet.sorted(by: >) { removeAction(index) }
            }
            .onMove { source, destination in
                onReorder?(source, destination)
            }
        } else {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                makeRow(index: index, song: song, downloadedSongIDs: downloadedSongIDs,
                        favoriteSongIDs: favoriteSongIDs)
                    .listRowBackground(rowBackground)
            }
        }
    }

    @ViewBuilder
    private func makeRow(
        index: Int,
        song: DisplayableSong,
        downloadedSongIDs: Set<String>,
        favoriteSongIDs: Set<String>
    ) -> some View {
        let liveDownloaded = downloadedSongIDs.contains(song.id)
        let liveSong = song.withDownloaded(liveDownloaded)
        let isDownloading = downloadingIds.contains(song.id)
        let downloadAction: (() -> Void)? = (liveDownloaded || isDownloading) ? nil : onDownload.map { action in { action(song.id) } }
        let removeAction: (() -> Void)? = liveDownloaded ? onRemoveDownload.map { action in { action(song.id) } } : nil
        #if os(macOS)
        macRow(
            index: index,
            song: liveSong,
            isFavorite: favoriteSongIDs.contains(song.id),
            isDownloading: isDownloading,
            downloadAction: downloadAction,
            removeAction: removeAction
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.visible)
        #else
        SongRow(song: liveSong, index: index + 1, showCoverArt: true, isFavorite: favoriteSongIDs.contains(song.id), titleColor: titleColor, secondaryColor: secondaryColor, onDownload: downloadAction, onRemoveDownload: removeAction, isDownloading: isDownloading, onRemoveFromPlaylist: onContextRemove.map { remove in { remove(index) } }, onAddToPlaylist: onAddToPlaylist, onPlay: { onTap(index) })
            .contentShape(Rectangle())
            .listRowBackground(Color.clear)
        #endif
    }

    #if os(macOS)
    private func macRow(
        index: Int,
        song: DisplayableSong,
        isFavorite: Bool,
        isDownloading: Bool,
        downloadAction: (() -> Void)?,
        removeAction: (() -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                toggleFavorite(song, isFavorite: isFavorite)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(isFavorite ? Color.lumaAccent : .secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(Text(isFavorite ? "Remove from Favorites" : "Add to Favorites"))

            CoverArtView(id: song.effectiveCoverArtId, size: 80, cornerRadius: 4)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)

            if showsAlbum {
                Text(song.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .frame(width: 440, alignment: .leading)
            } else {
                Text(song.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(song.artist ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 260, alignment: .leading)

            if showsAlbum {
                Text(song.albumName ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(durationLabel(song.duration))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)

            Menu {
                Button {
                    onTap(index)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                Button {
                    Task { await container?.playerService.playNext([song]) }
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    Task { await container?.playerService.addToQueue([song]) }
                } label: {
                    Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                Button {
                    onAddToPlaylist?(song)
                } label: {
                    Label("Add to Playlist…", systemImage: "text.badge.plus")
                }
                Divider()
                Button {
                    toggleFavorite(song, isFavorite: isFavorite)
                } label: {
                    Label(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: isFavorite ? "star.slash" : "star")
                }
                if let downloadAction {
                    Button(action: downloadAction) {
                        Label(isDownloading ? "Downloading…" : "Download", systemImage: "arrow.down.circle")
                    }
                    .disabled(isDownloading)
                } else if let removeAction {
                    Button(action: removeAction) {
                        Label("Remove Download", systemImage: "arrow.down.circle.fill")
                    }
                }
                if let onContextRemove {
                    Divider()
                    Button(role: .destructive) {
                        onContextRemove(index)
                    } label: {
                        Label("Remove from Playlist", systemImage: "minus.circle")
                    }
                }
                Divider()
                Button {
                    postNavigateToAlbum(track: song)
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
                .disabled(song.albumId == nil)
                Button {
                    postNavigateToArtist(track: song)
                } label: {
                    Label("Go to Artist", systemImage: "music.mic")
                }
                .disabled(song.artistId == nil)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More options"))
        }
        .padding(.horizontal, 24)
        .frame(height: 50)
        .contentShape(Rectangle())
        .onTapGesture { onTap(index) }
        .contextMenu {
            Button {
                onTap(index)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button {
                onAddToPlaylist?(song)
            } label: {
                Label("Add to Playlist…", systemImage: "text.badge.plus")
            }
            if let onContextRemove {
                Button(role: .destructive) {
                    onContextRemove(index)
                } label: {
                    Label("Remove from Playlist", systemImage: "minus.circle")
                }
            }
        }
    }

    private func toggleFavorite(_ song: DisplayableSong, isFavorite: Bool) {
        guard let c = container else { return }
        Task {
            do {
                if isFavorite {
                    try await c.favoritesService.unstar(itemType: .song, itemId: song.id)
                } else {
                    try await c.favoritesService.star(itemType: .song, itemId: song.id)
                }
            } catch {
                c.toastService.showError(error.localizedDescription)
            }
        }
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    #endif
}
