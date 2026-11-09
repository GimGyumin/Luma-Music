import SwiftUI
import WidgetKit

/// Large Now Playing: the cover stays the hero, framed by the same monochrome card
/// language as the Recently Played widget.
struct NowPlayingLargeView: View {
    let entry: NowPlayingEntry

    var body: some View {
        Group {
            if let track = entry.track {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(WidgetChrome.nowPlaying)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.6))
                        Spacer(minLength: 6)
                        WidgetMusicNote(size: 19)
                    }

                    Spacer(minLength: 8)

                    WidgetCoverArtView(image: entry.coverImage, cornerRadius: 15)
                        .frame(width: 190, height: 190)
                        .shadow(color: .black.opacity(0.32), radius: 16, y: 8)
                        .frame(maxWidth: .infinity)

                    Spacer(minLength: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(track.artist)
                            .font(.system(size: 14.5))
                            .foregroundStyle(.primary.opacity(0.62))
                            .lineLimit(1)
                    }

                    WidgetPlayPillButton(isPlaying: entry.isPlaying, height: 30)
                        .padding(.top, 8)
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

struct NowPlayingEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            WidgetMusicNote(size: 22)
            Spacer(minLength: 0)
            Text(WidgetChrome.text(korean: "재생 중인 음악 없음", english: "Not Playing"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(WidgetChrome.text(korean: "Luma에서 재생을 시작하세요", english: "Start playback in Luma"))
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
