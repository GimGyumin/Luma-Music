import Testing
@testable import Luma

@Suite("Artwork scene")
struct ArtworkSceneTests {
    @Test("Decoration time freezes while paused or hidden and resumes without a jump")
    func clockFreezes() {
        var clock = ArtworkSceneClock()
        clock.setRunning(true, now: 10)
        #expect(clock.sample(now: 12) == 2)
        clock.setRunning(false, now: 13)
        #expect(clock.sample(now: 200) == 3)
        clock.setRunning(true, now: 250)
        #expect(clock.sample(now: 251) == 4)
    }
}
