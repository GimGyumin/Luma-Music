import Testing
@testable import Luma

@Suite("Tab bar chrome presentation")
@MainActor
struct TabBarChromeStateTests {
    @Test func albumPresentationPinsUntilThePageActuallyEnds() {
        let chrome = TabBarChromeState()
        #expect(!chrome.isAlbumPresented)
        chrome.beginAlbum(pageID: "album-a#1")
        #expect(chrome.isAlbumPresented)
        // Repeated appearance callbacks during an interactive swipe must not flicker.
        chrome.beginAlbum(pageID: "album-a#1")
        #expect(chrome.isAlbumPresented)
        chrome.endAlbum(pageID: "album-a#1")
        #expect(!chrome.isAlbumPresented)
    }

    @Test func stackedAlbumPagesKeepTheChromeStableUntilTheLastOneEnds() {
        let chrome = TabBarChromeState()
        chrome.beginAlbum(pageID: "a")
        chrome.beginAlbum(pageID: "b")
        chrome.endAlbum(pageID: "a")
        #expect(chrome.isAlbumPresented)
        chrome.endAlbum(pageID: "b")
        #expect(!chrome.isAlbumPresented)
    }

    @Test func thirtyAlbumZoomCyclesReleaseChromeEveryTime() {
        let chrome = TabBarChromeState()
        for cycle in 0..<30 {
            chrome.beginAlbum(pageID: "stress-\(cycle)")
            #expect(chrome.isAlbumPresented)
            chrome.endAlbum(pageID: "stress-\(cycle)")
            #expect(!chrome.isAlbumPresented)
        }
    }

    @Test func unknownOrEmptyPagesCannotPinTheTabBar() {
        let chrome = TabBarChromeState()
        chrome.beginAlbum(pageID: "")
        chrome.endAlbum(pageID: "missing")
        #expect(!chrome.isAlbumPresented)
    }
}
