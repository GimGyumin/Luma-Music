import CoreFoundation
import Testing
@testable import Luma

@Suite("Root header scroll policy")
@MainActor
struct RootHeaderScrollPolicyTests {
    @Test func keepsTheHeaderWhileInsideTheTopBand() {
        #expect(RootHeaderScrollPolicy.nextState(isScrolled: false, offset: 4) == nil)
        #expect(RootHeaderScrollPolicy.nextState(isScrolled: true, offset: 4) == nil)
    }

    @Test func hidesAfterLeavingTheBand() {
        #expect(RootHeaderScrollPolicy.nextState(isScrolled: false, offset: 9) == true)
    }

    @Test func restoresOnlyAtTheScrollEdge() {
        #expect(RootHeaderScrollPolicy.nextState(isScrolled: true, offset: 0) == false)
        #expect(RootHeaderScrollPolicy.nextState(isScrolled: true, offset: -12) == false)
        #expect(RootHeaderScrollPolicy.nextState(isScrolled: false, offset: -12) == nil)
    }

    @Test func theBandPreventsBounceChatter() {
        // A pull-to-refresh bounce can move the offset above and below the hide
        // threshold while the header is already hidden. The policy must keep the
        // hidden state until the content actually reaches the scroll edge.
        var isScrolled = false
        for offset: CGFloat in [4, 7, 6] {
            if let next = RootHeaderScrollPolicy.nextState(isScrolled: isScrolled, offset: offset) {
                isScrolled = next
            }
        }
        #expect(!isScrolled)
        #expect(RootHeaderScrollPolicy.nextState(isScrolled: isScrolled, offset: 9) == true)
        isScrolled = true
        for offset: CGFloat in [8, 4, 6] {
            if let next = RootHeaderScrollPolicy.nextState(isScrolled: isScrolled, offset: offset) {
                isScrolled = next
            }
            #expect(isScrolled == true)
        }
        #expect(RootHeaderScrollPolicy.nextState(isScrolled: isScrolled, offset: 0) == false)
    }
}
