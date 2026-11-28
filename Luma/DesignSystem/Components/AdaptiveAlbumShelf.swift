// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

/// Album shelf: always a single horizontal scrolling row (iPhone, iPad, macOS).
struct AdaptiveAlbumShelf: View {
    let title: String
    let albums: [AlbumID3]
    var showArtist: Bool = true
    var prominent = false
    var showsSeeAll = false
    var destination: (AlbumID3) -> HomeDestination = { .album($0) }
    @Namespace private var albumNamespace

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var prominentTextHeight: CGFloat = 56
    @State private var availableWidth: CGFloat = 0

    private var usesIPadShelfLayout: Bool {
        LumaDashboardLayout.usesIPadLayout(for: horizontalSizeClass)
    }

    private var itemSize: CGFloat {
        #if os(macOS)
        // Music's macOS shelves step from 160 at the narrow window to 184 at
        // wide window widths; the cards do not stretch to fill the row.
        switch availableWidth {
        case ..<850:  return 160
        case ..<1100: return 164
        default:      return 184
        }
        #else
        if usesIPadShelfLayout {
            return LumaDashboardLayout.regularItemSize
        }
        return horizontalSizeClass == .regular ? 180 : (prominent ? 160 : 150)
        #endif
    }

    private var cardSpacing: CGFloat {
        #if os(macOS)
        20
        #else
        usesIPadShelfLayout ? LumaDashboardLayout.regularItemSpacing : LumaSpacing.m
        #endif
    }

    /// Cover + title (+ optional artist) — keep ScrollView height stable across size-class changes.
    private var rowHeight: CGFloat {
        itemSize + LumaSpacing.xs + (prominent ? prominentTextHeight : 44)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LumaSpacing.s) {
            if showsSeeAll {
                NavigationLink(value: HomeDestination.albumCollection(AlbumShelfCollection(
                    title: title, items: albums.map { .init(album: $0, destination: destination($0)) }
                ))) {
                    HomeShelfHeading(title: title, showsChevron: true)
                }
                .buttonStyle(.plain)
            } else {
                Text(title).font(prominent ? .title2.bold() : .lumaSectionTitle)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: cardSpacing) {
                    ForEach(albums) { album in
                        AlbumNavigationLink(album: album, namespace: albumNamespace, destination: destination(album)) { sourceID, namespace in
                            albumCard(album, sourceID: sourceID, namespace: namespace)
                        }
                        .buttonStyle(.plain)
                        .albumLongPressMenu(album)
                    }
                }
                .frame(height: rowHeight)
                .padding(.vertical, 1)
            }
            .frame(height: rowHeight + 2)
            // Keep the row from scrolling under the iPad sidebarAdaptable chrome.
            .clipped()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private func albumCard(_ album: AlbumID3, sourceID: String, namespace: Namespace.ID) -> some View {
        VStack(alignment: .leading, spacing: LumaSpacing.xs) {
            CoverArtView(id: album.coverArt ?? album.id, size: Int(itemSize + 30))
                .frame(width: itemSize, height: itemSize)
                .lumaCoverStyle(cornerRadius: LumaCornerRadius.large)
                .lumaMatchedTransitionSource(id: sourceID, in: namespace)
            Text(album.name)
                .foregroundStyle(.primary)
                .font(titleFont)
                .lineLimit(1)
            if showArtist, let artist = album.artist {
                Text(artist)
                    .font(artistFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: itemSize, alignment: .leading)
    }

    private var titleFont: Font {
        usesIPadShelfLayout
            ? .subheadline.weight(.semibold)
            : (prominent ? .body.weight(.semibold) : .lumaCellTitle)
    }

    private var artistFont: Font {
        usesIPadShelfLayout
            ? .subheadline
            : (prominent ? .subheadline : .lumaCaption)
    }
}

struct AlbumShelfCollectionView: View {
    @Namespace private var albumNamespace
    let collection: AlbumShelfCollection
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)], spacing: 20) {
                ForEach(collection.items) { item in
                    let album = item.album
                    AlbumNavigationLink(album: album, namespace: albumNamespace, destination: item.destination) { sourceID, namespace in
                        VStack(alignment: .leading, spacing: 8) {
                            CoverArtView(id: album.coverArt ?? album.id, size: 360)
                                .aspectRatio(1, contentMode: .fit).lumaCoverStyle(cornerRadius: LumaCornerRadius.large)
                                .lumaMatchedTransitionSource(id: sourceID, in: namespace)
                            Text(album.name).font(.body.weight(.semibold)).lineLimit(1)
                            if let artist = album.artist { Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                        }.foregroundStyle(.primary)
                    }.buttonStyle(.plain).albumLongPressMenu(album)
                }
            }.padding(16)
        }
        .navigationTitle(collection.title)
        .miniPlayerBottomMargin()
        .lumaContentWidth(.fill)
    }
}
