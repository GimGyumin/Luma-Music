// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct WrappedTopAlbumsSection: View {
    @Namespace private var albumZoomNamespace
    let albums: [TopAlbumEntry]

    #if os(macOS)
    private let columns = [
        GridItem(.flexible(), spacing: LumaSpacing.m),
        GridItem(.flexible(), spacing: LumaSpacing.m),
        GridItem(.flexible(), spacing: LumaSpacing.m)
    ]
    #else
    private let columns = [
        GridItem(.flexible(), spacing: LumaSpacing.m),
        GridItem(.flexible(), spacing: LumaSpacing.m)
    ]
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: LumaSpacing.s) {
            Text("Top Albums")
                .font(.lumaSectionTitle)
            if albums.isEmpty {
                emptyLabel("No album data for this period.")
            } else {
                LazyVGrid(columns: columns, spacing: LumaSpacing.m) {
                    ForEach(albums.prefix(6)) { album in
                        NavigationLink(
                            value: HomeDestination.albumById(
                                id: album.albumId,
                                name: album.title,
                                subtitle: album.artistName,
                                coverArtId: album.albumId
                            ).albumZoom(sourceID: album.albumId, namespace: albumZoomNamespace)
                        ) {
                            albumCard(album)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func albumCard(_ album: TopAlbumEntry) -> some View {
        VStack(alignment: .leading, spacing: LumaSpacing.xs) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        CoverArtView(id: album.albumId, size: 220, tier: .hero)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: LumaCornerRadius.standard, style: .continuous))
                    .lumaCoverStyle(cornerRadius: LumaCornerRadius.standard)
                    .lumaMatchedTransitionSource(id: album.albumId, in: albumZoomNamespace)
                rankBadge(album.rank)
                    .padding(LumaSpacing.xs)
            }
            Text(album.title)
                .font(.lumaCellTitle)
                .lineLimit(1)
            Text(album.artistName)
                .font(.lumaCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func medalColor(for rank: Int) -> Color {
        switch rank {
        case 1: return WrappedYearPalette.medalGold
        case 2: return WrappedYearPalette.medalSilver
        case 3: return WrappedYearPalette.medalBronze
        default: return LumaColors.accent
        }
    }

    private func rankBadge(_ rank: Int) -> some View {
        let isMedal = rank <= 3
        return Text("#\(rank)")
            .font(.lumaCaption2)
            .fontWeight(.bold)
            .foregroundStyle(isMedal ? Color.black : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                if isMedal {
                    Capsule().fill(medalColor(for: rank))
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.lumaCaption)
            .foregroundStyle(.secondary)
    }
}
