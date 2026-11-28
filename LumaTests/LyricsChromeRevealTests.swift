import CoreGraphics
import Testing
@testable import Luma

@Suite("Lyrics chrome scrolling")
@MainActor
struct LyricsChromeRevealTests {
    @Test func fastDownwardDragHidesChromeOnce() {
        let tracker = LyricsChromeScrollTracker()
        tracker.beginDrag()
        #expect(tracker.observe(delta: 15, now: 1, isHidden: false) == nil)
        #expect(tracker.observe(delta: 15, now: 1.016, isHidden: false) == .hide)
        #expect(tracker.observe(delta: -25, now: 1.032, isHidden: true) == nil)
    }

    @Test func onlyFastUpwardDragRevealsHiddenChrome() {
        let tracker = LyricsChromeScrollTracker()
        tracker.beginDrag()
        #expect(tracker.observe(delta: 20, now: 1, isHidden: true) == nil)
        #expect(tracker.observe(delta: 20, now: 1.016, isHidden: true) == nil)
        #expect(tracker.observe(delta: -7, now: 1.032, isHidden: true) == nil)
        #expect(tracker.observe(delta: -7, now: 1.048, isHidden: true) == .reveal)
    }

    @Test func gentleDragAndDecelerationLeaveChromeAlone() {
        let tracker = LyricsChromeScrollTracker()
        tracker.beginDrag()
        #expect(tracker.observe(delta: 4, now: 1, isHidden: false) == nil)
        #expect(tracker.observe(delta: 4, now: 1.016, isHidden: false) == nil)
        #expect(tracker.observe(delta: 40, now: 1.016, isHidden: false) == nil)
        tracker.endDrag()
        #expect(tracker.observe(delta: 40, now: 1.032, isHidden: false) == nil)
        tracker.beginDrag()
        #expect(tracker.observe(delta: 30, now: 2, isHidden: false) == nil)
        #expect(tracker.observe(delta: 30, now: 2.016, isHidden: false) == .hide)
    }
}
