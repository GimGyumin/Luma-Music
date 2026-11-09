// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import WidgetKit
import SwiftUI

struct NowPlayingWidget: Widget {
    let kind = WidgetKind.nowPlaying

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(WidgetChrome.nowPlaying))
        .description(Text(WidgetChrome.text(
            korean: "지금 재생 중인 음악을 확인하고 재생을 제어합니다.",
            english: "See what's playing in Luma and control playback."
        )))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemLarge:
            NowPlayingLargeView(entry: entry)
        case .systemMedium:
            NowPlayingMediumView(entry: entry)
        default:
            NowPlayingSmallView(entry: entry)
        }
    }
}
