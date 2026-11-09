import Foundation
import Testing
@testable import Luma

@Suite("Fast lyric emphasis timing")
struct LyricLineMotionPolicyTests {
    @Test func fastLinesFinishInsideTheirInterval() {
        let fast = LyricLineMotionPolicy.duration(
            lineStartMs: 10_000, nextStartMs: 10_300, isCurrent: true, reduceMotion: false
        )
        #expect(fast != nil)
        #expect(fast! < 0.30)
        #expect(fast! >= LyricLineMotionPolicy.minimum)
        #expect(fast! <= 0.135 + 0.0001)
    }

    @Test func slowLinesKeepTheExistingCalmCadence() {
        #expect(LyricLineMotionPolicy.duration(
            lineStartMs: 0, nextStartMs: 4_000, isCurrent: true, reduceMotion: false
        ) == LyricLineMotionPolicy.currentCap)
        #expect(LyricLineMotionPolicy.duration(
            lineStartMs: 0, nextStartMs: 4_000, isCurrent: false, reduceMotion: false
        ) == LyricLineMotionPolicy.inactiveCap)
    }

    @Test func lastLineAndReduceMotionHaveStablePolicies() {
        #expect(LyricLineMotionPolicy.duration(
            lineStartMs: 0, nextStartMs: nil, isCurrent: true, reduceMotion: false
        ) == LyricLineMotionPolicy.currentCap)
        #expect(LyricLineMotionPolicy.duration(
            lineStartMs: 0, nextStartMs: 250, isCurrent: true, reduceMotion: true
        ) == nil)
    }
}
