// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import WidgetKit

/// Small Now Playing: compact cover, monochrome note, title/artist and a play pill.
struct NowPlayingSmallView: View {
    let entry: NowPlayingEntry

    var body: some View {
        Group {
            if let track = entry.track {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        WidgetCoverArtView(image: entry.coverImage, cornerRadius: 7)
                            .frame(width: 60, height: 60)
                        Spacer(minLength: 8)
                        WidgetMusicNote(size: 22)
                    }

                    Spacer(minLength: 4)

                    Text(track.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(track.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.62))
                        .lineLimit(1)

                    WidgetPlayPillButton(isPlaying: entry.isPlaying, height: 27)
                        .padding(.top, 7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                NowPlayingEmptyState()
            }
        }
        .containerBackground(for: .widget) {
            WidgetCardBackground(tint: entry.track == nil ? nil : entry.dominantColor)
        }
    }
}
