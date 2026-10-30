import CoreSpotlight
import Foundation
import Testing
@testable import Luma

#if os(iOS)
@MainActor @Suite("On-device Spotlight query", .serialized)
struct SpotlightQueryIntegrationTests {
    @Test func submittedSongAndAlbumResolveOnlyInTheirAccount() async throws {
        guard #available(iOS 27.0, *) else { return }
        let suffix = UUID().uuidString
        let writer = NativeSpotlightWriter(indexName: "Luma.Validation." + suffix)
        let scope = "validation-" + suffix
        let title = "LumaValidation" + suffix.replacingOccurrences(of: "-", with: "")
        let server = UUID()
        let records = [
            SpotlightRecord(kind: .song, serverID: server, localID: "song", title: title, artist: "Validation Artist"),
            SpotlightRecord(kind: .album, serverID: server, localID: "album", title: title, artist: "Validation Artist")
        ]
        do {
            try await writer.apply(upserts: records, deletions: [], scope: scope, checkpoint: Data())
            var result = SpotlightQueryAdapter.Result(keys: [], suggestions: [])
            for _ in 0..<30 {
                result = try await SpotlightQueryAdapter.search(title, scope: scope, limit: 10)
                if result.keys.count == records.count { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(Set(result.keys) == Set(records.map(\.key)))
            let otherAccount = try await SpotlightQueryAdapter.search(title, scope: "different-account", limit: 10)
            #expect(otherAccount.keys.isEmpty)
            try await writer.reset()
        } catch {
            try? await writer.reset()
            throw error
        }
    }
}
#endif
