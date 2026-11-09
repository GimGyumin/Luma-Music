// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Apple Music Pins–style tile: square art for albums/songs/playlists, circle for artists.
struct PinnedTileView: View {
    let item: SharedPinnedItem
    let image: PlatformImage?
    var coverSize: CGFloat = 60
    var titleSize: CGFloat = 11

    var body: some View {
        VStack(spacing: 5) {
            artwork
                .frame(width: coverSize, height: coverSize)

            Text(item.title)
                .font(.system(size: titleSize, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var artwork: some View {
        let content = Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.primary.opacity(0.08)
                    Image(systemName: placeholderIcon)
                        .font(.system(size: coverSize * 0.3, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        if item.kind == .artist {
            content.clipShape(Circle())
        } else {
            content.clipShape(RoundedRectangle(cornerRadius: max(8, coverSize * 0.12), style: .continuous))
        }
    }

    private var placeholderIcon: String {
        switch item.kind {
        case .playlist: "music.note.list"
        case .artist: "person.fill"
        case .song: "music.note"
        case .album: "square.stack"
        }
    }
}
