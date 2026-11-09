import Testing
@testable import Luma

@Suite("Widget kind registration")
struct WidgetKindTests {
    @Test func fourDistinctKindsAreRegistered() {
        let kinds = [WidgetKind.nowPlaying, WidgetKind.pinned,
                     WidgetKind.recent, WidgetKind.recommendations]
        #expect(Set(kinds).count == 4)
        #expect(kinds == ["NowPlayingWidget", "PinnedWidget", "RecentWidget", "RecommendationsWidget"])
    }
}
