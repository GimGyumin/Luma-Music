import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Luma

@Suite struct ReplayHistoryTests {
    @Test func pageCommitIsAtomicAndReplayIDsAreAccountScoped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mirror.sqlite")
        let db = try ReplayHistoryStore(url: url)
        let rows = try JSONDecoder().decode([NavidromeScrobble].self, from: Data("""
            [{"id":1,"mediaFileId":"song","submissionTime":100},{"id":2,"mediaFileId":"song","submissionTime":100}]
            """.utf8))
        for _ in 0..<2 { try db.save(rows, uid: "alice", offset: 0, previous: 0, complete: true) }
        #expect(throws: ReplayHistoryStore.Failure.self) { try db.save(rows.reversed(), uid: "alice", offset: 0, previous: 0, complete: false) }
        let reopened = try ReplayHistoryStore(url: url)
        #expect(try reopened.cursor("alice").count == 2)
        #expect(try reopened.cursor("bob").count == 0)
        let start = Date(timeIntervalSince1970: 0), end = Date(timeIntervalSince1970: 101)
        let sid = UUID()
        try db.enqueue(session: sid, track: "song", date: end.addingTimeInterval(-1), owner: "")
        try db.mark(sid.uuidString, state: 2)
        #expect(try db.linkedSessions(uid: "alice", owner: "", start: start, end: end).isEmpty)
        try db.save([rows[0]], uid: "scan:alice", offset: 0, previous: 0, complete: true)
        try db.publish(scan: "scan:alice", uid: "alice")
        #expect(try db.linkedSessions(uid: "alice", owner: "", start: start, end: end) == [sid])
    }

    @Test func localBackupPreservesMeasuredHistoryAndOriginalUUID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("legacy.jsonl")
        let container = try ModelContainer.listening(inMemory: true)
        let stats = StatsService(modelContainer: container)
        let local = PlaybackEventDTO(trackId: "song", trackTitle: "Title", albumId: nil, albumTitle: nil,
            artistId: nil, artistName: "", genre: nil, timestamp: Date(), durationListened: 34,
            trackDuration: 200, wasCompleted: false, serverId: "first")
        await stats.recordPlayback(local)
        try await StatsService.backupLocalHistory(container: container, serverID: "first", to: url)
        let copy = try JSONDecoder().decode(PlaybackEventDTO.self, from: Data(contentsOf: url))
        #expect(copy.id == local.id && copy.durationListened == 34 && copy.serverId == "first")
        try await StatsService.backupLocalHistory(container: container, serverID: "first", to: url)
        #expect(await stats.eventCount(forServer: "first") == 1)
    }

    @Test func oneHundredThousandRowsResumeFromCommittedPages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.sqlite")
        let db = try ReplayHistoryStore(url: url)
        for offset in stride(from: 0, to: 100_000, by: 500) {
            let json = (1...500).map { index in
                #"{"id":\#(offset + index),"mediaFileId":"song","submissionTime":\#(100000 - offset - index + 1)}"#
            }.joined(separator: ",")
            let page = try JSONDecoder().decode([NavidromeScrobble].self, from: Data(("[" + json + "]").utf8))
            try db.save(page, uid: "listener", offset: offset, previous: Int64(offset), complete: offset == 99500)
        }
        let reopened = try ReplayHistoryStore(url: url)
        #expect(try reopened.cursor("listener").last == 100_000)
        var observed = 0
        try reopened.enumerate(uid: "listener", start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 51)) { _,_,_ in observed += 1 }
        #expect(observed == 50)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_REPLAY_FIXTURE"] != nil))
    func nativeServerFeedsTwoIndependentReplayStoresAndRecoversOfflineSubmission() async throws {
        struct Fixture: Decodable { let base: URL; let password: String; let track: String; let now: Int; let initialCount: Int }
        let input = try #require(ProcessInfo.processInfo.environment["LUMA_REPLAY_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(input.utf8))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MockServerService()
        func signIn(_ user: String) async throws -> ServerSnapshot {
            try await server.addServer(displayName: "Fixture", baseURL: fixture.base.absoluteString,
                username: user, password: fixture.password, customHeaders: [:])
            server.musicClient = SwiftSonicClient(serverURL: fixture.base, username: user, password: fixture.password)
            server.credentials = ServerCredentials(password: fixture.password, customHeaders: [:])
            return try #require(server.state.activeServer)
        }
        let account = try await signIn("listener")
        let first = ReplayHistorySync(server: server, directory: root.appendingPathComponent("one"))
        let second = ReplayHistorySync(server: server, directory: root.appendingPathComponent("two"))
        let period = WrappedPeriod.currentYear()
        let local = try ModelContainer.listening(inMemory: true)
        let stats = StatsService(modelContainer: local, replay: second, account: { server.state.activeServer })
        let sid = account.id.uuidString
        #expect(await first.sync(force: true) == "Synced")
        #expect(await second.sync(force: true) == "Synced")
        #expect(await stats.wrappedData(for: period, serverId: sid, calendar: .current).totalTracksPlayed == fixture.initialCount)
        #expect(await stats.wrappedData(for: period, serverId: sid, calendar: .current).totalSecondsListened == 0)
        let session = UUID(), date = Date(timeIntervalSince1970: Double(fixture.now - 30))
        server.state.isOnline = false
        try await first.submit(session: session, track: fixture.track, date: date, account: account)
        await stats.recordPlayback(PlaybackEventDTO(id: session, trackId: fixture.track, trackTitle: "Fixture",
            albumId: nil, albumTitle: nil, artistId: nil, artistName: "", genre: nil, timestamp: date,
            durationListened: 34, trackDuration: 200, wasCompleted: false, serverId: account.localReplayID))
        server.state.isOnline = true
        try await first.flushIfOnline(account)
        try await first.flushIfOnline(account)
        for _ in 0..<2 { #expect(await second.sync(force: true) == "Synced") }
        let result = await stats.wrappedData(for: period, serverId: sid, calendar: .current)
        #expect(result.totalTracksPlayed == fixture.initialCount + 1 && result.totalSecondsListened == 34)
        let other = try await signIn("other")
        #expect(await second.sync(force: true) == "Synced")
        #expect(await stats.wrappedData(for: period, serverId: other.id.uuidString, calendar: .current).totalTracksPlayed == 0)
    }
}
