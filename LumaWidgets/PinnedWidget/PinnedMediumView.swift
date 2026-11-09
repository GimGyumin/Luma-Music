// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import WidgetKit

/// Apple Music Pins medium: four cover tiles in one row on the shared card.
struct PinnedMediumView: View {
    let entry: PinnedEntry

    var body: some View {
        Group {
            if entry.items.isEmpty {
                PinnedEmptyState()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetSectionHeader(
                        title: WidgetChrome.text(korean: "고정", english: "Pinned"),
                        noteSize: 18
                    )

                    HStack(alignment: .top, spacing: 8) {
                        ForEach(entry.items.prefix(4), id: \.id) { item in
                            PinnedTileView(
                                item: item,
                                image: entry.coverImages[item.coverArtFilename ?? ""],
                                coverSize: 64,
                                titleSize: 13
                            )
                            .frame(maxWidth: .infinity)
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
