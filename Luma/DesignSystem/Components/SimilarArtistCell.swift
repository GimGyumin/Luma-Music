// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct SimilarArtistCell: View {
    let recommendation: SimilarArtistRecommendation
    let externalImageURL: URL?
    let onOutOfLibraryTap: () -> Void
    let sectionVisible: Bool
    let loadImage: () async -> Void

    @Environment(\.appContainer) private var container
    @State private var visibleInShelf = false

    private var artworkEnabled: Bool { sectionVisible && visibleInShelf }

    var body: some View {
        Group {
            if recommendation.inLibrary {
                cellContent
            } else {
                Button(action: onOutOfLibraryTap) {
                    cellContent
                }
                .buttonStyle(.plain)
            }
        }
        .onScrollVisibilityChange(threshold: 0.15) { visibleInShelf = $0 }
        .task(id: "\(artworkEnabled):\(container?.serverState.artworkNetworkRevision ?? 0)") {
            guard artworkEnabled, externalImageURL == nil,
                  container?.serverState.isOnline == true else { return }
            await loadImage()
        }
    }

    private var cellContent: some View {
        VStack(spacing: LumaSpacing.xs) {
            if recommendation.inLibrary, let coverArt = recommendation.coverArt {
                CoverArtView(id: coverArt, size: 128, placeholderSystemImage: "person.fill", loadingEnabled: artworkEnabled)
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
            } else {
                ExternalCoverView(url: externalImageURL) {
                    ArtistPlaceholderView(name: recommendation.name, size: 64)
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())
            }

            Text(recommendation.name)
                .font(.lumaCaption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }
}
