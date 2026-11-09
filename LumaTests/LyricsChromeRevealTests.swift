import CoreGraphics
import Testing
@testable import Luma

@Suite("Lyrics chrome scroll reveal")
struct LyricsChromeRevealTests {
    @Test func gentleBrowseDoesNotRevealPlayerChrome() {
        // A small drag at 60 fps is roughly 240 pt/s, below the deliberate-scroll
        // threshold. Slowly reading the lyrics must leave the chrome hidden.
        #expect(!LyricsView.shouldRevealChrome(offsetDelta: 4, elapsed: 1.0 / 60.0))
        #expect(!LyricsView.shouldRevealChrome(offsetDelta: -4, elapsed: 1.0 / 60.0))
    }

    @Test func moderateScrollStillDoesNotRevealChrome() {
        // ~480 pt/s: a normal reading drag, below the deliberate threshold.
        #expect(!LyricsView.shouldRevealChrome(offsetDelta: 8, elapsed: 1.0 / 60.0))
    }

    @Test func deliberateScrollRevealsPlayerChrome() {
        #expect(LyricsView.shouldRevealChrome(offsetDelta: 20, elapsed: 1.0 / 60.0))
        #expect(LyricsView.shouldRevealChrome(offsetDelta: -20, elapsed: 1.0 / 60.0))
    }

    @Test func zeroElapsedDoesNotDivideByZero() {
        #expect(!LyricsView.shouldRevealChrome(offsetDelta: 0, elapsed: 0))
        #expect(LyricsView.shouldRevealChrome(offsetDelta: 40, elapsed: 0))
    }

    @Test @MainActor func trackerMatchesThePureThresholdAndResets() {
        let tracker = LyricsScrollRevealTracker()
        let frame = 1.0 / 60.0

        #expect(!tracker.observe(offset: 0, now: 10))
        #expect(tracker.observe(offset: 20, now: 10 + frame))

        tracker.reset()
        #expect(!tracker.observe(offset: 100, now: 20))
        #expect(!tracker.observe(offset: 108, now: 20 + frame))
        #expect(tracker.observe(offset: 128, now: 20 + frame * 2))
    }
}
