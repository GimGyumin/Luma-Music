import SwiftUI
import WidgetKit

nonisolated struct RecommendationsEntry: TimelineEntry {
    let date: Date
    let mixes: [SharedMixInfo]

    static var placeholder: RecommendationsEntry {
        RecommendationsEntry(date: Date(), mixes: [
            SharedMixInfo(kind: "getUp", trackCount: 30),
            SharedMixInfo(kind: "heavyRotation", trackCount: 35),
            SharedMixInfo(kind: "newMusic", trackCount: 28),
            SharedMixInfo(kind: "essentials", trackCount: 24),
            SharedMixInfo(kind: "chill", trackCount: 18),
            SharedMixInfo(kind: "focus", trackCount: 21)
        ])
    }

    static var empty: RecommendationsEntry {
        RecommendationsEntry(date: Date(), mixes: [])
    }
}

struct RecommendationsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecommendationsEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (RecommendationsEntry) -> Void) {
        completion(context.isPreview ? .placeholder : makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecommendationsEntry>) -> Void) {
        completion(Timeline(entries: [makeEntry()], policy: .after(Date().addingTimeInterval(30 * 60))))
    }

    private func makeEntry() -> RecommendationsEntry {
        let mixes: [SharedMixInfo]? = SharedStorage.read { defaults in
            guard let data = defaults.data(forKey: SharedStorageKey.personalMixes.rawValue) else { return nil }
            return try? JSONDecoder().decode([SharedMixInfo].self, from: data)
        }
        guard let mixes, !mixes.isEmpty else { return .empty }
        return RecommendationsEntry(date: Date(), mixes: Array(mixes.prefix(6)))
    }
}

struct RecommendationsWidget: Widget {
    let kind = WidgetKind.recommendations

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecommendationsProvider()) { entry in
            RecommendationsWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(WidgetChrome.text(korean: "추천", english: "Recommendations")))
        .description(Text(WidgetChrome.text(
            korean: "Luma의 인기 추천곡, 최신 발매 및 기타 제안 항목을 재생합니다.",
            english: "Play Luma's top picks, new releases and other suggestions."
        )))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RecommendationsWidgetView: View {
    let entry: RecommendationsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if entry.mixes.isEmpty {
                emptyState
            } else {
                switch family {
                case .systemSmall:
                    small
                case .systemLarge:
                    large
                default:
                    medium
                }
            }
        }
        .containerBackground(for: .widget) {
            WidgetCardBackground()
        }
    }

    private var small: some View {
        let mix = entry.mixes[0]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                MixArtworkView(mix: mix, size: 52, cornerRadius: 10)
                Spacer(minLength: 8)
                WidgetMusicNote(size: 22)
            }
            Spacer(minLength: 4)
            Text(MixStyle(kind: mix.kind).title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(trackCountText(mix))
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.62))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entry.mixes.prefix(2)) { mix in
                    row(mix, coverSize: 42, titleSize: 15, subtitleSize: 11.5, playSize: 26)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(alignment: .leading, spacing: 18) {
                ForEach(entry.mixes.prefix(4)) { mix in
                    row(mix, coverSize: 52, titleSize: 15, subtitleSize: 12.5, playSize: 30)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        WidgetSectionHeader(
            title: WidgetChrome.text(korean: "추천 믹스", english: "Your Mixes"),
            noteSize: 18
        )
    }

    private func row(
        _ mix: SharedMixInfo,
        coverSize: CGFloat,
        titleSize: CGFloat,
        subtitleSize: CGFloat,
        playSize: CGFloat
    ) -> some View {
        let style = MixStyle(kind: mix.kind)
        return HStack(spacing: 9) {
            MixArtworkView(mix: mix, size: coverSize, cornerRadius: max(6, coverSize * 0.18))

            VStack(alignment: .leading, spacing: 1) {
                Text(WidgetChrome.text(korean: "LUMA 추천", english: "LUMA PICK"))
                    .font(.system(size: max(9, subtitleSize - 1), weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(.primary.opacity(0.56))
                    .lineLimit(1)

                Text(style.title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(trackCountText(mix))
                    .font(.system(size: subtitleSize))
                    .foregroundStyle(.primary.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            WidgetCircularPlayIndicator(size: playSize)
        }
    }

    private func trackCountText(_ mix: SharedMixInfo) -> String {
        WidgetChrome.isKorean ? "\(mix.trackCount)곡" : "\(mix.trackCount) songs"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            WidgetMusicNote(size: 22)
            Spacer(minLength: 0)
            Text(WidgetChrome.text(korean: "추천을 불러오는 중", english: "Waiting for mixes"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(WidgetChrome.text(
                korean: "Luma에서 음악을 재생하면 추천이 채워집니다.",
                english: "Play music in Luma to build your mixes."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Locally rendered mix cover so the Recommendations widget keeps the same
/// artwork language as the app's Made for You shelves.
private struct MixArtworkView: View {
    let mix: SharedMixInfo
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let style = MixStyle(kind: mix.kind)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(style.gradient)
            .overlay {
                Image(systemName: style.symbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}

private struct MixStyle {
    let kind: String

    var title: String {
        let korean = WidgetChrome.isKorean
        switch kind {
        case "getUp": return "Get Up!"
        case "heavyRotation": return korean ? "자주 듣는 음악" : "Heavy Rotation"
        case "newMusic": return korean ? "신규 음악" : "New Music"
        case "essentials": return korean ? "나의 필수곡" : "Your Essentials"
        case "chill": return "Chill"
        case "focus": return "Focus"
        default: return kind
        }
    }

    var symbol: String {
        switch kind {
        case "getUp": return "figure.run"
        case "heavyRotation": return "repeat"
        case "newMusic": return "music.note"
        case "essentials": return "star.fill"
        case "chill": return "moon.stars.fill"
        case "focus": return "sparkles"
        default: return "music.note"
        }
    }

    var gradient: LinearGradient {
        let pair: (String, String)
        switch kind {
        case "getUp": pair = ("#F0A202", "#8B3A00")
        case "heavyRotation": pair = ("#E85D4C", "#6B1A14")
        case "newMusic": pair = ("#377EEC", "#1B3A6B")
        case "essentials": pair = ("#C44B9F", "#4A1638")
        case "chill": pair = ("#3DB8A0", "#0F3D36")
        case "focus": pair = ("#62D6D1", "#302478")
        default: pair = ("#377EEC", "#1B3A6B")
        }
        return LinearGradient(colors: [Color(hex: pair.0), Color(hex: pair.1)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
