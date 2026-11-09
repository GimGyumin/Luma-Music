import SwiftUI

/// Stable priority for the playlist tab. Existing recommendation policy still decides
/// which mixes exist; this only controls the section order and surfaces every kind that
/// PersonalMixService can build.
nonisolated enum PlaylistRecommendationPolicy {
    static let priority: [PersonalMixKind] = [
        .getUp, .heavyRotation, .essentials, .newMusic, .chill, .focus
    ]

    static func ordered(_ mixes: [PersonalMix]) -> [PersonalMix] {
        var byKind: [PersonalMixKind: PersonalMix] = [:]
        for mix in mixes where !mix.tracks.isEmpty {
            byKind[mix.kind] = mix
        }
        return priority.compactMap { byKind[$0] }
    }
}

/// Horizontal, compact recommendation strip for the top of the Playlists tab.
/// It reserves its height while loading so the playlist list below does not jump.
struct PlaylistRecommendationsShelf: View {
    let mixes: [PersonalMix]
    let isLoading: Bool

    private var displayed: [PersonalMix] { PlaylistRecommendationPolicy.ordered(mixes) }
    private var title: String { GuideCatalog.languageCode == "ko" ? "취향 추천" : "For You" }

    var body: some View {
        if isLoading && displayed.isEmpty {
            placeholder
        } else if !displayed.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.title2.bold())
                    Spacer()
                    NavigationLink {
                        GuideView(guide: .playlistRecommendations)
                    } label: {
                        Text(GuideCatalog.languageCode == "ko" ? "추천 기준" : "How this works")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Text(GuideCatalog.languageCode == "ko" ? "나를 위한 믹스" : "Made for you")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(displayed) { mix in
                            NavigationLink(value: HomeDestination.personalMix(mix.kind)) {
                                compactCard(mix)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(
                                localized: String.LocalizationValue(mix.kind.localizationKey),
                                bundle: AppUILanguage.localizationBundle,
                                locale: AppUILanguage.locale
                            ))
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    private func compactCard(_ mix: PersonalMix) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            PersonalMixArtwork(kind: mix.kind, showsTitle: false, showsSymbol: true)
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(String(
                localized: String.LocalizationValue(mix.kind.localizationKey),
                bundle: AppUILanguage.localizationBundle,
                locale: AppUILanguage.locale
            ))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            Text(LumaCountLabel.tracks(mix.tracks.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 132, alignment: .leading)
    }

    private var placeholder: some View {
        // The Playlists tab intentionally has no skeleton strip; the shelf
        // appears when the first recommendation is ready.
        EmptyView()
    }
}
