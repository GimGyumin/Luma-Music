// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import AppIntents

/// Shared copy and chrome used by every widget family so the extension keeps one
/// visual language even though it does not link the app's string catalog.
enum WidgetChrome {
    static var isKorean: Bool {
        Locale.preferredLanguages.first?.hasPrefix("ko") == true
    }

    static func text(korean: String, english: String) -> String {
        isKorean ? korean : english
    }

    static var nowPlaying: String { text(korean: "지금 재생 중", english: "Now Playing") }
    static var recentlyPlayed: String { text(korean: "최근 재생된 항목", english: "Recently Played") }
    static var play: String { text(korean: "재생", english: "Play") }
    static var pause: String { text(korean: "일시 정지", english: "Pause") }
}

/// Translucent card surface matching the monochrome Apple Music widget chrome.
/// A material keeps the wallpaper tint on the Home Screen while the gradient
/// keeps text legible on dark and light backgrounds.
struct WidgetCardBackground: View {
    /// Currently playing cover color. Recommendations/Pins leave this nil and
    /// keep the neutral glass card.
    var tint: Color? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if tint == nil {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }

            // Tinted cards are opaque: the Home Screen wallpaper must not dominate
            // the cover-derived album tone. The black/white base keeps the primary
            // label readable in both appearances.
            Rectangle()
                .fill(colorScheme == .dark ? Color.black : Color.white)
                .opacity(tint == nil ? 0.18 : 0.66)

            if let tint {
                Rectangle()
                    .fill(tint)
                    .opacity(colorScheme == .dark ? 0.34 : 0.24)

                LinearGradient(
                    colors: [
                        tint.opacity(colorScheme == .dark ? 0.46 : 0.30),
                        tint.opacity(colorScheme == .dark ? 0.20 : 0.12),
                        Color.black.opacity(colorScheme == .dark ? 0.28 : 0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            Rectangle()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.10 : 0.01))

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.10 : 0.32),
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.16 : 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// Apple Music–style square cover (continuous corners, subtle lift).
struct WidgetCoverArtView: View {
    let image: PlatformImage?
    var cornerRadius: CGFloat = 12

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.primary.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: max(12, cornerRadius * 1.2), weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// The small monochrome music note that anchors every card's top-right corner.
struct WidgetMusicNote: View {
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: "music.note")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.primary.opacity(0.92))
    }
}

/// Capsule "Play" label used by the featured area of the Recently Played cards.
struct WidgetPlayPillLabel: View {
    let title: String
    var systemImage: String = "play.fill"
    var height: CGFloat = 30

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: height * 0.42, weight: .bold))
            Text(title)
                .font(.system(size: height * 0.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, height * 0.46)
        .frame(height: height)
        .background(.primary.opacity(0.12), in: Capsule())
    }
}

/// Capsule play/pause control backed by the shared audio-playback intent.
struct WidgetPlayPillButton: View {
    let isPlaying: Bool
    var height: CGFloat = 30

    var body: some View {
        Button(intent: PlayPauseIntent()) {
            WidgetPlayPillLabel(
                title: isPlaying ? WidgetChrome.pause : WidgetChrome.play,
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                height: height
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? Text(WidgetChrome.pause) : Text(WidgetChrome.play))
    }
}

/// Circular play affordance used at the trailing edge of compact list rows.
struct WidgetCircularPlayIndicator: View {
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.primary.opacity(0.88))
            .frame(width: size, height: size)
            .background(.primary.opacity(0.12), in: Circle())
    }
}

/// Compact header used by Recommendations and Pins.
struct WidgetSectionHeader: View {
    let title: String
    var noteSize: CGFloat = 18

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            WidgetMusicNote(size: noteSize)
        }
    }
}

/// A single recently played row: cover, title/artist, and a trailing play circle.
/// The circle is a sibling of the link rather than its child so WidgetKit routes
/// its tap to `WidgetPlayTrackIntent` instead of opening the app.
struct WidgetTrackRow: View {
    let item: SharedTrackInfo
    let image: PlatformImage?
    var destination: URL? = nil
    var coverSize: CGFloat = 34
    var titleSize: CGFloat = 14
    var artistSize: CGFloat = 12
    var playSize: CGFloat = 24
    var playIntent: WidgetPlayTrackIntent? = nil

    var body: some View {
        HStack(spacing: 9) {
            if let destination {
                Link(destination: destination) { content }
            } else {
                content
            }

            if let playIntent {
                Button(intent: playIntent) {
                    WidgetCircularPlayIndicator(size: playSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(WidgetChrome.play))
            } else {
                WidgetCircularPlayIndicator(size: playSize)
            }
        }
    }

    private var content: some View {
        HStack(spacing: 9) {
            WidgetCoverArtView(image: image, cornerRadius: max(5, coverSize * 0.18))
                .frame(width: coverSize, height: coverSize)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: titleSize, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(item.artist)
                    .font(.system(size: artistSize))
                    .foregroundStyle(.primary.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
        }
    }
}
