import Testing
import SwiftUI
@testable import Luma

@Suite("Lyric line cascade")
struct LyricLineCascadeTests {
    @Test func usesMeasuredWrappedHeightAndRejectsUnknownOrDistantMoves() {
        let heights: [Int: CGFloat] = [0: 88, 1: 184]
        #expect(LyricLineCascade.measuredTravel(previous: 0, target: 1, heights: heights,
            spacing: 32, viewportHeight: 600) == 120)
        #expect(LyricLineCascade.measuredTravel(previous: 1, target: 2, heights: heights,
            spacing: 32, viewportHeight: 600) == 216)
        for (previous, target) in [(nil, 0), (0, 4), (4, 5), (1, 0)] as [(Int?, Int)] {
            #expect(LyricLineCascade.measuredTravel(previous: previous, target: target,
                heights: heights, spacing: 32, viewportHeight: 600) == nil)
        }
        #expect(LyricLineCascade.measuredTravel(previous: 1, target: 2, heights: heights,
            spacing: 32, viewportHeight: 200) == nil)
    }

    @Test func activeLineNeverLagsAndFollowingLinesSettleWithoutResidualOffset() {
        let motion = LyricLineCascade(target: 5, travel: 120)
        for time in stride(from: 0.0, through: 1.5, by: 0.01) {
            #expect(motion.offset(row: 5, elapsed: time) == 0)
            #expect(motion.offset(row: 4, elapsed: time) == 0)
            #expect(motion.offset(row: 12, elapsed: time) == 0)
            for row in 6...11 {
                let offset = motion.offset(row: row, elapsed: time)
                #expect(offset.isFinite && offset >= 0 && offset < 120)
            }
        }
        #expect(motion.offset(row: 7, elapsed: 0.15) > motion.offset(row: 6, elapsed: 0.15))
        #expect(motion.offset(row: 7, elapsed: 0) == 0)
        #expect(motion.offset(row: 7, elapsed: LyricLineCascade.duration) == 0)
        #expect(motion.offset(row: 7, elapsed: 1.39) < 0.01)
        #expect(LyricLineCascade().offset(row: 1, elapsed: 0.15) == 0)
    }
}
