import Foundation
import Testing
@testable import SwiftSonic

struct NavidromeCopyrightTests {
    @Test(arguments: [
        #"{"tags":{"copyright":["℗ 1991 MJJ Productions Inc."]}}"#,
        #"{"tags":{"copyright":[{"value":"℗ 1991 MJJ Productions Inc."}]}}"#,
        #"{"rawTags":{"cprt":["℗ 1991 MJJ Productions Inc."],"©cmt":[""]}}"#
    ])
    func readsOriginalCopyrightWithoutComment(_ json: String) throws {
        #expect(try JSONDecoder().decode(NavidromeCopyrightMetadata.self, from: Data(json.utf8)).copyright == "℗ 1991 MJJ Productions Inc.")
    }

    @Test func missingAndMalformedUnrelatedTagsAreHarmless() throws {
        let json = #"{"tags":{"copyright":[],"artist":{"unexpected":true}},"rawTags":{"CPRT":[" ℗ One ","© Two","℗ One"]}}"#
        #expect(try JSONDecoder().decode(NavidromeCopyrightMetadata.self, from: Data(json.utf8)).copyright == "℗ One\n© Two")
        #expect(try JSONDecoder().decode(NavidromeCopyrightMetadata.self, from: Data(#"{"tags":{"comment":["Notes"]}}"#.utf8)).copyright == nil)
    }

    @Test func requestUsesNativeAuthenticationAndEscapesID() async throws {
        let mock = MockHTTPTransport()
        mock.enqueue(Data(#"{"tags":{"copyright":["℗ Credit"]}}"#.utf8), statusCode: 200)
        let api = NavidromeNativeAPI(transport: mock)
        #expect(try await api.songCopyright(baseURL: URL(string: "https://example.invalid/music")!, token: "secret", songID: "a/b?c") == "℗ Credit")
        let request = try #require(mock.lastRequest)
        #expect(request.value(forHTTPHeaderField: "x-nd-authorization") == "Bearer secret")
        #expect(request.url?.absoluteString == "https://example.invalid/music/api/song/a%2Fb%3Fc")
        #expect(request.httpBody == nil)
    }

    @Test func inspectionIsReadOnlyAndHonorsPermissionDenial() async throws {
        let mock = MockHTTPTransport()
        mock.enqueue(Data("private server response".utf8), statusCode: 403)
        let api = NavidromeNativeAPI(transport: mock)
        do {
            _ = try await api.songCopyright(baseURL: URL(string: "https://example.invalid")!, token: "secret", songID: "1", inspect: true)
            Issue.record("Expected permission denial")
        } catch NavidromeNativeAPIError.metadataRequestFailed(let status) {
            #expect(status == 403)
        }
        #expect(mock.lastRequest?.url?.path == "/api/inspect")
        #expect(mock.lastRequest?.httpMethod == "GET")
    }
}
