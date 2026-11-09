import SwiftUI
import WidgetKit

/// Small Pins: the first pinned item, rendered with the same tile language as larger families.
struct PinnedSmallView: View {
    let entry: PinnedEntry

    var body: some View {
        Group {
            if let item = entry.items.first {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetSectionHeader(
                        title: WidgetChrome.text(korean: "고정", english: "Pinned"),
                        noteSize: 18
                    )

                    Spacer(minLength: 0)

                    PinnedTileView(
                        item: item,
                        image: entry.coverImages[item.coverArtFilename ?? ""],
                        coverSize: 72,
                        titleSize: 12
                    )

                    Spacer(minLength: 0)
                }
            } else {
                PinnedEmptyState()
            }
        }
        .containerBackground(for: .widget) {
            WidgetCardBackground()
        }
    }
}
