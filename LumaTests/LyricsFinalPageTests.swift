import Foundation
import Testing
@testable import Luma

struct LyricsFinalPageTests {
    @Test(arguments: [CGFloat(320), 500, 740])
    func finalLineCanReachSameAnchorAsEarlierVerses(_ viewport: CGFloat) {
        for row: CGFloat in [48, 96, 230, 800] {
            let inset: CGFloat = 20
            let anchor = LyricScrollGeometry.anchor(viewportHeight: viewport, bottomInset: inset, rowHeight: row)
            let tail = LyricScrollGeometry.trailingSpace(viewportHeight: viewport, bottomInset: inset, rowHeight: row, anchor: anchor)
            #expect(tail >= 0)
            if row < viewport - inset {
                let lastTopAtMaximumOffset = viewport - row - inset - tail
                let requestedTop = anchor * (viewport - row)
                #expect(abs(lastTopAtMaximumOffset - requestedTop) < 0.001)
            }
        }
    }
    @Test(arguments: [-100.0, 200, 700, 1100, 5000])
    func nonEmphasizedRunHasIdenticalPerGlyphTransforms(_ time: Double) {
        for motion in [false, true] {
            for secondary in [false, true] {
                let first = AMLLGlyphStyle.sample(timeMs: time, startMs: 0, endMs: 900, fontSize: 36,
                    character: 0, count: 20, emphasized: false, lastWord: false, background: secondary, motion: motion)
                for index in 1..<20 {
                    let next = AMLLGlyphStyle.sample(timeMs: time, startMs: 0, endMs: 900, fontSize: 36,
                        character: index, count: 20, emphasized: false, lastWord: false, background: secondary, motion: motion)
                    #expect(next == first)
                    #expect(next.scale == 1 && next.shiftX == 0 && next.glow == 0)
                }
            }
        }
    }
}
