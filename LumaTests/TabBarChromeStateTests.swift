import Testing
@testable import Luma

@Suite("Tab bar chrome transitions")
@MainActor
struct TabBarChromeStateTests {
    @Test func albumPresentationPinsOnlyUntilTheTransitionSettles() {
        let chrome = TabBarChromeState()
        #expect(!chrome.isTransitioning)
        chrome.beginTransition(pageID: "album-a#1")
        #expect(chrome.isTransitioning)
        // Repeated appearance callbacks during an interactive swipe must not flicker.
        chrome.beginTransition(pageID: "album-a#1")
        #expect(chrome.isTransitioning)
        chrome.endTransition(pageID: "album-a#1")
        #expect(!chrome.isTransitioning)
    }

    @Test func stackedAlbumPagesKeepTheChromeStableUntilTheLastTransitionEnds() {
        let chrome = TabBarChromeState()
        chrome.beginTransition(pageID: "a")
        chrome.beginTransition(pageID: "b")
        chrome.endTransition(pageID: "a")
        #expect(chrome.isTransitioning)
        chrome.endTransition(pageID: "b")
        #expect(!chrome.isTransitioning)
    }

    @Test func thirtyTransitionCyclesReleaseChromeEveryTime() {
        let chrome = TabBarChromeState()
        for cycle in 0..<30 {
            chrome.beginTransition(pageID: "stress-\(cycle)")
            #expect(chrome.isTransitioning)
            chrome.endTransition(pageID: "stress-\(cycle)")
            #expect(!chrome.isTransitioning)
        }
    }

    @Test func unknownOrEmptyPagesCannotPinTheTabBar() {
        let chrome = TabBarChromeState()
        chrome.beginTransition(pageID: "")
        chrome.endTransition(pageID: "missing")
        #expect(!chrome.isTransitioning)
    }
}
