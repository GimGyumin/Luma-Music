import Testing
@testable import Luma

@Suite("First launch and update introduction")
struct AppIntroductionVersionTests {
    @Test func firstLaunchAndUpdatesRequireAcknowledgement() {
        let first = AppIntroductionVersion.identifier(version: "1.0", build: "100")
        #expect(AppIntroductionVersion.needsPresentation(seen: "", current: first))
        #expect(!AppIntroductionVersion.needsPresentation(seen: first, current: first))
        #expect(AppIntroductionVersion.needsPresentation(seen: first,
            current: AppIntroductionVersion.identifier(version: "1.0", build: "101")))
        #expect(AppIntroductionVersion.needsPresentation(seen: first,
            current: AppIntroductionVersion.identifier(version: "1.1", build: "100")))
    }
}
