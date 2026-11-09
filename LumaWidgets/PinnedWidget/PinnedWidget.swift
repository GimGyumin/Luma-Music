// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import WidgetKit
import SwiftUI

struct PinnedWidget: Widget {
    let kind = WidgetKind.pinned

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PinnedProvider()) { entry in
            PinnedWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(WidgetChrome.text(korean: "고정", english: "Pinned")))
        .description(Text(WidgetChrome.text(
            korean: "고정한 항목에 빠르게 접근합니다.",
            english: "Quick access to the albums, playlists and artists you've pinned."
        )))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PinnedWidgetView: View {
    let entry: PinnedEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemLarge:
            PinnedLargeView(entry: entry)
        case .systemSmall:
            PinnedSmallView(entry: entry)
        default:
            PinnedMediumView(entry: entry)
        }
    }
}
