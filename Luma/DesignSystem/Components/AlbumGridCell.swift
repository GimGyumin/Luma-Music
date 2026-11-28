// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

/// Adaptive library card shared by Albums, Recently Added, and other grids.
/// On macOS Music reveals only a star on hover; it never puts a play button over the art.
struct AlbumGridCell: View {
    let album: AlbumID3
    var zoomSourceId: String? = nil
    var zoomNamespace: Namespace.ID? = nil

    @Environment(\.appContainer) private var container
    @State private var isHovered = false
    @State private var isFavorite = false

    private var cardTitleFont: Font {
        #if os(macOS)
        MacDesign.Typography.cardTitle
        #else
        .lumaCellTitle
        #endif
    }
    private var cardSubtitleFont: Font {
        #if os(macOS)
        MacDesign.Typography.cardSubtitle
        #else
        .lumaCaption
        #endif
    }
    private var cardSpacing: CGFloat {
        #if os(macOS)
        MacDesign.Metrics.albumGridGap
        #else
        LumaSpacing.s
        #endif
    }
    private var cardRadius: CGFloat {
        #if os(macOS)
        MacDesign.Radius.card
        #else
        LumaCornerRadius.standard
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                CoverArtView(id: album.coverArt ?? album.id, size: Int(width * 2))
                    .frame(width: width, height: width)
                    .lumaCoverStyle(cornerRadius: cardRadius)
            }
            .aspectRatio(1, contentMode: .fit)
            .lumaMatchedTransitionSource(id: zoomSourceId, in: zoomNamespace)

            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .foregroundStyle(.primary)
                        .font(cardTitleFont)
                        #if os(macOS)
                        .lineLimit(2)
                        #else
                        .lineLimit(1)
                        #endif
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let artist = album.artist {
                        Text(artist)
                            .font(cardSubtitleFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                #if os(macOS)
                .frame(minHeight: 34, alignment: .topLeading)
                #endif

                #if os(macOS)
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(isFavorite ? Color.lumaAccent : .secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isFavorite ? 1 : 0)
                .allowsHitTesting(isHovered || isFavorite)
                .accessibilityHidden(!(isHovered || isFavorite))
                .disabled(container?.serverState.isOnline != true)
                .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                .accessibilityLabel(Text(isFavorite ? "Remove from Favorites" : "Add to Favorites"))
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { isHovered = $0 }
        .albumLongPressMenu(album)
        .task(id: album.id) {
            isFavorite = container?.favoritesService.isFavorite(itemType: .album, itemId: album.id) ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumaFavoritesChanged)) { _ in
            isFavorite = container?.favoritesService.isFavorite(itemType: .album, itemId: album.id) ?? false
        }
        #else
        .albumLongPressMenu(album)
        #endif
    }

    #if os(macOS)
    private func toggleFavorite() async {
        guard let container else { return }
        do {
            if isFavorite {
                try await container.favoritesService.unstar(itemType: .album, itemId: album.id)
            } else {
                try await container.favoritesService.star(itemType: .album, itemId: album.id)
            }
            isFavorite.toggle()
        } catch {
            container.toastService.showError(error.localizedDescription)
        }
    }
    #endif
}
