import Testing
@testable import Luma

@Suite("Queue rows and selection keep the rendered queue")
struct QueueListSnapshotTests {
    private func track(_ id: String) -> DisplayableSong {
        DisplayableSong(id: id, title: id, duration: 180)
    }

    @Test func oldRowsRemainSafeAfterTheLiveQueueIsReplaced() {
        var queue = [track("history"), track("current"), track("next"), track("autoplay")]
        let snapshot = QueueListSnapshot(tracks: queue, currentIndex: 1, intentionalEnd: 3)
        queue = [track("replacement")]
        #expect(snapshot.history.map(\.song.id) == ["history"])
        #expect(snapshot.continuing.map(\.song.id) == ["next"])
        #expect(snapshot.autoplay.map(\.song.id) == ["autoplay"])
        #expect(snapshot.selection(at: 2, currentQueue: queue) == nil)
    }

    @Test func playKeepsTheFullQueueAndTheSelectedDuplicateOccurrence() throws {
        let queue = [track("same"), track("other"), track("same"), track("last")]
        let snapshot = QueueListSnapshot(tracks: queue, currentIndex: 0)
        let selection = try #require(snapshot.selection(at: 2, currentQueue: queue))
        #expect(selection.tracks == queue)
        #expect(selection.index == 2)
        #expect(snapshot.continuing.map(\.id) == [1, 2, 3])
        #expect(selection.tracks[selection.index].id == "same")
    }

    @Test func reorderOrRemovalInvalidatesAnOlderMenuSelection() {
        let queue = [track("a"), track("b"), track("c")]
        let snapshot = QueueListSnapshot(tracks: queue, currentIndex: 0)
        #expect(snapshot.selection(at: 1, currentQueue: [queue[1], queue[0], queue[2]]) == nil)
        #expect(snapshot.selection(at: 1, currentQueue: [queue[0], queue[2]]) == nil)
        #expect(snapshot.selection(at: -1, currentQueue: queue) == nil)
        #expect(snapshot.selection(at: queue.count, currentQueue: queue) == nil)
    }

    @Test func positionsFromALongerQueueAreClampedBeforeBuildingRows() {
        let snapshot = QueueListSnapshot(tracks: [track("only")], currentIndex: 99, intentionalEnd: 99)
        #expect(snapshot.history.count == 1)
        #expect(snapshot.continuing.isEmpty)
        #expect(snapshot.autoplay.isEmpty)
        let empty = QueueListSnapshot(tracks: [], currentIndex: 99, intentionalEnd: -1)
        #expect(empty.history.isEmpty && empty.continuing.isEmpty && empty.autoplay.isEmpty)
    }
}
