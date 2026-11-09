// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import WidgetKit

/// Apple Music Pins large: up to six covers in a 3-column grid.
struct PinnedLargeView: View {
    let entry: PinnedEntry

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        Group {
            if entry.items.isEmpty {
                PinnedEmptyState()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    WidgetSectionHeader(
                        title: WidgetChrome.text(korean: "고정", english: "Pinned"),
                        noteSize: 19
                    )

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(entry.items.prefix(6), id: \.id) { item in
                            PinnedTileView(
                                item: item,
                                image: entry.coverImages[item.coverArtFilename ?? ""],
                                coverSize: 88,
                                titleSize: 13
                            )
                        }
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .containerBackground(for: .widget) {
            WidgetCardBackground()
        }
    }
}

struct PinnedEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            WidgetMusicNote(size: 22)
            Spacer(minLength: 0)
            Text(WidgetChrome.text(korean: "고정한 항목이 없어요", english: "Nothing pinned yet"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(WidgetChrome.text(
                korean: "Luma에서 앨범이나 재생목록을 고정해 보세요.",
                english: "Pin albums or playlists in Luma."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
