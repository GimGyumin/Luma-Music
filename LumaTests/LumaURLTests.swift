import Foundation
import Testing
@testable import Luma

@Suite("Trusted help links")
struct LumaURLTests {
    @Test func onlyOfficialGitHubHostsAreAccepted() {
        #expect(LumaURLs.isTrustedGitHubURL(URL(string: "https://github.com/GimGyumin/Luma-Music")!))
        #expect(LumaURLs.isTrustedGitHubURL(URL(string: "https://raw.githubusercontent.com/GimGyumin/Luma-Music/main/docs/guides/ko/pin.md")!))
        #expect(!LumaURLs.isTrustedGitHubURL(URL(string: "https://github.com.evil.example/GimGyumin/Luma-Music")!))
        #expect(!LumaURLs.isTrustedGitHubURL(URL(string: "http://github.com/GimGyumin/Luma-Music")!))
        #expect(!LumaURLs.isTrustedGitHubURL(URL(string: "file:///etc/passwd")!))
    }

    @Test func guideURLsStayInsideTheRepositoryAndSupportBothLanguages() {
        let korean = LumaURLs.guideRaw(language: "ko", id: GuideID.losslessAudio.rawValue)
        let english = LumaURLs.guideHTML(language: "en", id: GuideID.privacy.rawValue)
        #expect(korean?.absoluteString.contains("/docs/guides/ko/lossless-audio.md") == true)
        #expect(english?.absoluteString.contains("/docs/guides/en/privacy.md") == true)
        #expect(korean.map(LumaURLs.isTrustedGitHubURL) == true)
        #expect(english.map(LumaURLs.isTrustedGitHubURL) == true)
    }

    @Test func everyGuideHasKoreanAndEnglishRepositoryDocsAndFallback() {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for id in GuideID.allCases {
            for language in ["ko", "en"] {
                let url = repositoryRoot
                    .appendingPathComponent("docs/guides/\(language)/\(id.rawValue).md")
                #expect(FileManager.default.fileExists(atPath: url.path),
                        "Missing guide \(language)/\(id.rawValue).md")
            }
            #expect(!GuideCatalog.fallback(id).isEmpty)
        }
    }

    @Test func feedbackURLEncodesTheIssueBodyWithoutSecrets() throws {
        let url = try #require(LumaURLs.newIssue(title: "Bug", body: "line 1\nline 2"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "title" }?.value == "Bug")
        #expect(items.first { $0.name == "body" }?.value == "line 1\nline 2")
        #expect(LumaURLs.isTrustedGitHubURL(url))
    }
}
