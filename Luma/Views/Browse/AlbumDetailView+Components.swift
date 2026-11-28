// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import SwiftData
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// Keep the shelf's origin attached to scrolling content while its color extends
/// through the viewport's reserved player/tab-bar area. No per-scroll page state.
struct AlbumRelatedShelfBoundsKey: PreferenceKey {
    nonisolated static var defaultValue: Anchor<CGRect>? { nil }
    nonisolated static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct AlbumRelatedShelfFill: View {
    let baseColor: Color
    var isLight: Bool = false

    var body: some View {
        // Apple Music keeps the “More by” panel within a few percent of the page
        // tone. A fixed 25% black wash turns a white sleeve into mid-grey, so the
        // separation is now weighted by the page's actual lightness.
        baseColor.overlay(Color.black.opacity(isLight ? 0.045 : 0.20))
    }
}

struct AlbumRelatedShelfContinuation: View {
    let anchor: Anchor<CGRect>?
    let baseColor: Color
    var isLight: Bool = false

    var body: some View {
        GeometryReader { geometry in
            if let anchor {
                let bounds = geometry[anchor]
                let top = min(geometry.size.height, max(0, bounds.minY))
                AlbumRelatedShelfFill(baseColor: baseColor, isLight: isLight)
                    .frame(width: bounds.width, height: max(0, geometry.size.height - top))
                    .offset(x: bounds.minX, y: top)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}


struct AlbumTopBleedModifier: ViewModifier {
    let bleed: Bool
    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: bleed ? .top : [])
    }
}

/// Shared mini-player scroll margin; disabled when “More by” already reserves that space.
struct AlbumMiniPlayerMargin: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        #if os(macOS)
        // RootViewMacOS owns the player reserve; albums shown as sheets do not
        // have a floating bar to clear.
        content.contentMargins(.bottom, 0, for: .scrollContent)
        #else
        // The system accessory already reserves the margin. Keep the same content
        // identity when the asynchronously loaded More By shelf appears.
        content
        #endif
    }
}

// MARK: - Download state

nonisolated enum AlbumDownloadState {
    case notDownloaded
    case partiallyDownloaded
    case fullyDownloaded
}

// MARK: - Live download indicator rows

/// Sub-view that observes DownloadedTrack changes live via @Query,
/// overriding the isDownloaded flag per row without requiring a VM reload.
struct AlbumSongRows: View {
    let songs: [DisplayableSong]
    let downloadingIds: Set<String>
    let visibleSongIDs: Set<String>?
    let titleColor: Color
    let secondaryColor: Color
    let onTap: (Int) -> Void
    let onDownload: ((String) -> Void)?
    let onRemoveDownload: ((String) -> Void)?
    let onAddToPlaylist: ((DisplayableSong) -> Void)?

    @Query private var downloadedTracks: [DownloadedTrack]
    @Query private var allFavorites: [FavoriteRecord]

    let albumArtist: String?

    init(songs: [DisplayableSong], albumId: String, serverId: UUID, albumArtist: String? = nil, downloadingIds: Set<String> = [], titleColor: Color = .primary, secondaryColor: Color = .secondary, visibleSongIDs: Set<String>? = nil, onTap: @escaping (Int) -> Void, onDownload: ((String) -> Void)? = nil, onRemoveDownload: ((String) -> Void)? = nil, onAddToPlaylist: ((DisplayableSong) -> Void)? = nil) {
        self.albumArtist = albumArtist
        self.songs = songs
        self.downloadingIds = downloadingIds
        self.visibleSongIDs = visibleSongIDs
        self.titleColor = titleColor
        self.secondaryColor = secondaryColor
        self.onTap = onTap
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
        self.onAddToPlaylist = onAddToPlaylist
        let aid = albumId
        let sid = serverId
        let type = FavoriteType.song.rawValue
        // Scope favorite observation to this album's songs. The previous predicate
        // fetched every song favorite for the server on every album entry and then
        // built a Set from all of them; large libraries paid that cost per page.
        let songIDs = songs.map(\.id)
        _downloadedTracks = Query(
            filter: #Predicate<DownloadedTrack> { track in
                track.albumId == aid && track.serverId == sid
            }
        )
        // Scope the observation to this album's server, song type, and song ids
        // instead of fetching every favorite of every media type for each row.
        _allFavorites = Query(
            filter: #Predicate<FavoriteRecord> { favorite in
                favorite.serverId == sid && favorite.itemType == type && songIDs.contains(favorite.itemId)
            }
        )
    }

    private var showsDiscHeaders: Bool {
        let discs = Set(songs.compactMap(\.discNumber))
        if discs.count > 1 { return true }
        // Single disc > 1 still deserves a label when tagged.
        if let only = discs.first, only > 1 { return true }
        return false
    }

    var body: some View {
        // Build these indexes once per list render. The previous implementation
        // rebuilt them for every row (O(rows × records)) and compared favorite
        // rows against the obsolete "song:<id>" key, so the star never matched.
        let downloadedSongIDs = Set(downloadedTracks.map(\.songId))
        let favoriteSongIDs = FavoriteRecord.songIDSet(from: allFavorites)
        let discHeadersVisible = showsDiscHeaders

        let visibleIndices = visibleSongIDs.map { ids in songs.indices.filter { ids.contains(songs[$0].id) } }
            ?? Array(songs.indices)
        ForEach(Array(visibleIndices.enumerated()), id: \.element) { offset, index in
            let song = songs[index]
            let liveDownloaded = downloadedSongIDs.contains(song.id)
            let liveSong = song.withDownloaded(liveDownloaded)
            let isDownloading = downloadingIds.contains(song.id)
            let downloadAction: (() -> Void)? = (liveDownloaded || isDownloading) ? nil : onDownload.map { action in { action(song.id) } }
            let removeAction: (() -> Void)? = liveDownloaded ? onRemoveDownload.map { action in { action(song.id) } } : nil
            let disc = song.discNumber ?? 1
            let showDiscHeader = discHeadersVisible && (offset == 0 || (songs[visibleIndices[offset - 1]].discNumber ?? 1) != disc)

            #if os(macOS)
            if showDiscHeader {
                Text(String(localized: "Disc \(disc)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(titleColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.trailing, 44)
                    .padding(.top, index == 0 ? LumaSpacing.s : LumaSpacing.l)
                    .padding(.bottom, LumaSpacing.xs)
            }
            Group {
                SongRow(song: liveSong, index: song.trackNumber ?? (index + 1), showCoverArt: false, showArtist: liveSong.showsArtist(inAlbumBy: albumArtist), isFavorite: favoriteSongIDs.contains(song.id), titleColor: titleColor, secondaryColor: secondaryColor, onDownload: downloadAction, onRemoveDownload: removeAction, isDownloading: isDownloading, onAddToPlaylist: onAddToPlaylist, onPlay: { onTap(index) })
                    .withDesktopAlbumControls()
                    .padding(.leading, 46)
                    .padding(.trailing, 44)
                    .contentShape(Rectangle())
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .overlay(alignment: .bottom) {
                AlbumTrackDivider(color: titleColor.opacity(0.10))
                    .padding(.leading, 82)
                    .padding(.trailing, 44)
                    .allowsHitTesting(false)
            }
            #else
            VStack(spacing: 0) {
                if showDiscHeader {
                    Text(String(localized: "Disc \(disc)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(titleColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, LumaSpacing.l)
                        .padding(.top, index == 0 ? LumaSpacing.s : LumaSpacing.l)
                        .padding(.bottom, LumaSpacing.xs)
                }
                Group {
                    SongRow(song: liveSong, index: song.trackNumber ?? (index + 1), showCoverArt: false, showArtist: liveSong.showsArtist(inAlbumBy: albumArtist), isFavorite: favoriteSongIDs.contains(song.id), titleColor: titleColor, secondaryColor: secondaryColor, onDownload: downloadAction, onRemoveDownload: removeAction, isDownloading: isDownloading, onAddToPlaylist: onAddToPlaylist, onPlay: { onTap(index) })
                        .reservingArtistSpace()
                        .padding(.horizontal, LumaSpacing.xl)
                        .contentShape(Rectangle())
                }
                AlbumTrackDivider(color: titleColor.opacity(0.22))
                    .padding(.leading, LumaSpacing.xl + 28 + LumaSpacing.s)
                    .padding(.trailing, LumaSpacing.xl)
            }
            #endif
        }
    }
}

/// Keep separators visible on artwork backgrounds and independent of subtitle styling.
struct AlbumTrackDivider: View {
    var color: Color = LumaColors.border

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(maxWidth: .infinity)
            #if os(iOS)
            .frame(height: 0.5)
            #else
            .frame(height: 1)
            #endif
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }
}

// MARK: - Scroll chrome

struct AlbumScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
