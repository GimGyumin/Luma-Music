// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import WidgetKit

/// Medium Now Playing: lifted square cover on the left, now-playing label, type and pill.
struct NowPlayingMediumView: View {
    let entry: NowPlayingEntry

    var body: some View {
        Group {
            if let track = entry.track {
                HStack(spacing: 14) {
                    WidgetCoverArtView(image: entry.coverImage, cornerRadius: 11)
                        .frame(width: 112, height: 112)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(WidgetChrome.nowPlaying)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.58))
                            .lineLimit(1)

                        Text(track.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Text(track.artist)
                            .font(.system(size: 14))
                            .foregroundStyle(.primary.opacity(0.62))
                            .lineLimit(1)

                        WidgetPlayPillButton(isPlaying: entry.isPlaying, height: 28)
                            .padding(.top, 5)
                    }
                    .padding(.trailing, 22)

                    Spacer(minLength: 0)
                }
                .overlay(alignment: .topTrailing) {
                    WidgetMusicNote(size: 20)
                }
            } else {
                NowPlayingEmptyState()
            }
        }
        .containerBackground(for: .widget) {
            WidgetCardBackground(tint: entry.track == nil ? nil : entry.dominantColor)
        }
    }
}
