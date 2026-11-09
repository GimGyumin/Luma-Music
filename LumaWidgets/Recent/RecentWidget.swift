import SwiftUI
import WidgetKit

struct RecentWidget: Widget {
    let kind = WidgetKind.recent

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentProvider()) { entry in
            RecentWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(WidgetChrome.recentlyPlayed))
        .description(Text(WidgetChrome.text(
            korean: "최근 재생한 음악을 모두 찾고 현재 재생 중인 음악을 봅니다.",
            english: "Find everything you played recently and see what is playing now."
        )))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RecentWidgetView: View {
    let entry: RecentEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            RecentSmallView(entry: entry)
        case .systemLarge:
            RecentLargeView(entry: entry)
        default:
            RecentMediumView(entry: entry)
        }
    }
}

// MARK: - Small

struct RecentSmallView: View {
    let entry: RecentEntry

    var body: some View {
        Group {
            if let featured = entry.featured {
                RecentSmallContent(entry: entry, item: featured)
            } else {
                RecentEmptyState()
            }
        }
        .containerBackground(for: .widget) {
            WidgetCardBackground(tint: entry.featured == nil ? nil : entry.featuredDominantColor)
        }
    }
}

private struct RecentSmallContent: View {
    let entry: RecentEntry
    let item: SharedTrackInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = RecentDeepLink.url(for: item) {
                Link(destination: url) { upperContent }
            } else {
                upperContent
            }

            // Keep the intent button outside every Link so WidgetKit routes the
            // tap to PlayPauseIntent instead of the app deep link.
            WidgetPlayPillButton(isPlaying: entry.isPlaying, height: 27)
                .padding(.top, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var upperContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                WidgetCoverArtView(image: entry.image(for: item), cornerRadius: 7)
                    .frame(width: 60, height: 60)
                Spacer(minLength: 8)
                WidgetMusicNote(size: 22)
            }

            Spacer(minLength: 4)

            Text(item.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(item.artist)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.62))
                .lineLimit(1)
        }
    }
}

// MARK: - Medium

struct RecentMediumView: View {
    let entry: RecentEntry

    var body: some View {
        Group {
            if let featured = entry.featured {
                RecentMediumContent(entry: entry, item: featured)
            } else {
                RecentEmptyState()
            }
        }
        .containerBackground(for: .widget) {
            WidgetCardBackground(tint: entry.featured == nil ? nil : entry.featuredDominantColor)
        }
    }
}

private struct RecentMediumContent: View {
    let entry: RecentEntry
    let item: SharedTrackInfo

    var body: some View {
        HStack(spacing: 14) {
            if let url = RecentDeepLink.url(for: item) {
                Link(destination: url) { cover }
            } else {
                cover
            }

            VStack(alignment: .leading, spacing: 2) {
                if let url = RecentDeepLink.url(for: item) {
                    Link(destination: url) { textBlock }
                } else {
                    textBlock
                }

                // Intent button must not be nested in the Link above.
                WidgetPlayPillButton(isPlaying: entry.isPlaying, height: 28)
                    .padding(.top, 5)
            }
            .padding(.trailing, 22)

            Spacer(minLength: 0)
        }
        .overlay(alignment: .topTrailing) {
            WidgetMusicNote(size: 20)
        }
    }

    private var cover: some View {
        WidgetCoverArtView(image: entry.image(for: item), cornerRadius: 11)
            .frame(width: 112, height: 112)
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.featuredLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.58))
                .lineLimit(1)

            Text(item.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(item.artist)
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.62))
                .lineLimit(1)
        }
    }
}

// MARK: - Large

struct RecentLargeView: View {
    let entry: RecentEntry

    var body: some View {
        Group {
            if let featured = entry.featured {
                RecentLargeContent(entry: entry, featured: featured)
            } else {
                RecentEmptyState()
            }
        }
        .containerBackground(for: .widget) {
            WidgetCardBackground(tint: entry.featured == nil ? nil : entry.featuredDominantColor)
        }
    }
}

private struct RecentLargeContent: View {
    let entry: RecentEntry
    let featured: SharedTrackInfo

    private var rows: [SharedTrackInfo] {
        entry.recentItems(limit: 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero

            Rectangle()
                .fill(.primary.opacity(0.10))
                .frame(height: 1)
                .padding(.vertical, 7)

            Text(WidgetChrome.recentlyPlayed)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.58))
                .padding(.bottom, 5)

            if rows.isEmpty {
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows, id: \.id) { item in
                        row(for: item)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 13) {
            if let url = RecentDeepLink.url(for: featured) {
                Link(destination: url) { heroCover }
            } else {
                heroCover
            }

            VStack(alignment: .leading, spacing: 2) {
                if let url = RecentDeepLink.url(for: featured) {
                    Link(destination: url) { heroText }
                } else {
                    heroText
                }

                // Keep the interactive play/pause pill outside the Link.
                WidgetPlayPillButton(isPlaying: entry.isPlaying, height: 27)
                    .padding(.top, 3)
            }
            .padding(.trailing, 24)

            Spacer(minLength: 0)
        }
        .overlay(alignment: .topTrailing) {
            WidgetMusicNote(size: 19)
        }
    }

    private var heroCover: some View {
        WidgetCoverArtView(image: entry.featuredImage, cornerRadius: 11)
            .frame(width: 100, height: 100)
    }

    private var heroText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.featuredLabel)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.6))
                .lineLimit(1)

            Text(featured.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(featured.artist)
                .font(.system(size: 13.5))
                .foregroundStyle(.primary.opacity(0.62))
                .lineLimit(1)
        }
    }

    private func row(for item: SharedTrackInfo) -> some View {
        WidgetTrackRow(
            item: item,
            image: entry.image(for: item),
            destination: RecentDeepLink.url(for: item),
            coverSize: 48,
            titleSize: 15.5,
            artistSize: 12.5,
            playSize: 28,
            playIntent: WidgetPlayTrackIntent(trackID: item.id, serverID: item.serverID)
        )
    }
}

// MARK: - Shared

struct RecentEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            WidgetMusicNote(size: 22)
            Spacer(minLength: 0)
            Text(WidgetChrome.text(korean: "아직 재생한 음악이 없어요", english: "Nothing played yet"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(WidgetChrome.text(korean: "Luma에서 음악을 재생해 보세요.", english: "Play something in Luma."))
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

enum RecentDeepLink {
    static func url(for item: SharedTrackInfo) -> URL? {
        guard let serverID = item.serverID, UUID(uuidString: serverID) != nil else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let local = item.id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "luma://song/\(serverID)/\(local)")
    }
}
