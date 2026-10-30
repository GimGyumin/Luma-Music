import Foundation
import CoreSpotlight
import Testing
@testable import Luma

private actor RecordingSpotlightWriter: SpotlightIndexWriting {
    var items: [String: SpotlightRecord] = [:]
    var batches = 0
    var resets = 0
    var totalUpserts = 0
    var deleted: [String] = []
    var state: Data?
    var failAt: Int?
    var delay: Duration = .zero
    var active = 0
    var maxActive = 0
    func configure(failAt: Int? = nil, delay: Duration = .zero) { self.failAt = failAt; self.delay = delay }
    func clientState() -> Data? { state }
    func loseIndex() { items = [:]; state = nil }
    func reset() { resets += 1; items = [:]; state = nil }
    func apply(upserts: [SpotlightRecord], deletions: [String], scope: String, checkpoint: Data) async throws {
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        // Simulate an XPC write that completes despite caller cancellation.
        if delay != .zero { try? await Task.sleep(for: delay) }
        batches += 1
        if batches == failAt { throw CocoaError(.fileWriteUnknown) }
        #expect(checkpoint.count < 250)
        for item in upserts { items[item.key] = item }
        for key in deletions { items.removeValue(forKey: key) }
        totalUpserts += upserts.count; deleted += deletions; state = checkpoint
    }
}

@Suite("Spotlight incremental index", .serialized)
struct SpotlightIndexCoordinatorTests {
    @Test func persistedRevisionSkipsConversionButRepairStillRuns() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter(), values = records(12)
        let index = SpotlightIndexCoordinator(writer: writer, directory: dir)
        try await index.reconcile(records: values, scope: "one", sourceRevision: "v1")
        let relaunched = SpotlightIndexCoordinator(writer: writer, directory: dir)
        #expect(try await relaunched.isCurrent(sourceRevision: "v1", scope: "one"))
        #expect(try await !relaunched.isCurrent(sourceRevision: "v1", scope: "two"))
        try await relaunched.reconcile(records: values, scope: "one", force: [values[0].key], sourceRevision: "v1")
        #expect(await writer.totalUpserts == 13)
        await writer.configure(failAt: 3)
        var changed = values; changed[0].title = "Changed"
        await #expect(throws: (any Error).self) {
            try await relaunched.reconcile(records: changed, scope: "one", sourceRevision: "v2")
        }
        #expect(try await !relaunched.isCurrent(sourceRevision: "v1", scope: "one"))
        #expect(try await !relaunched.isCurrent(sourceRevision: "v2", scope: "one"))
    }

    @Test func budgetsDeferHeatAndBackgroundWithoutDeletingAnything() throws {
        #expect(throws: SpotlightWorkDeferred.self) {
            try SpotlightWorkBudget.make(active: false, playing: true, lowPower: false, thermal: .nominal)
        }
        #expect(throws: SpotlightWorkDeferred.self) {
            try SpotlightWorkBudget.make(active: true, playing: true, lowPower: false, thermal: .serious)
        }
        #expect(try SpotlightWorkBudget.make(active: true, playing: true, lowPower: false, thermal: .nominal).batchSize == 24)
        #expect(try SpotlightWorkBudget.make(active: true, playing: false, lowPower: true, thermal: .nominal).batchSize == 40)
    }
    private let server = UUID(uuidString: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB")!
    private func records(_ count: Int) -> [SpotlightRecord] {
        (0..<count).map { SpotlightRecord(kind: .song, serverID: server, localID: "\($0)", title: "Track \($0)") }
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("spotlight-test-\(UUID())") }

    @Test func unchangedSnapshotSubmitsNothing() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter(), records = records(200)
        let index = SpotlightIndexCoordinator(writer: writer, directory: dir)
        try await index.reconcile(records: records, scope: "one")
        let before = await writer.batches
        try await index.reconcile(records: records, scope: "one")
        #expect(await writer.batches == before)
        #expect(await index.status == .submitted(upserts: 0, deletions: 0))
    }
    @Test func changesAndDeletionAreIncremental() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter()
        let coordinator = SpotlightIndexCoordinator(writer: writer, directory: dir)
        var values = records(3)
        try await coordinator.reconcile(records: values, scope: "one")
        let deleted = values.removeLast().key
        values[0].title = "Renamed"
        try await coordinator.reconcile(records: values, scope: "one")
        #expect(await writer.totalUpserts == 4)
        #expect(await writer.deleted == [deleted])
        #expect(await writer.items.count == 2)
    }
    @Test func checkpointSurvivesRelaunch() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter()
        try await SpotlightIndexCoordinator(writer: writer, directory: dir).reconcile(records: records(180), scope: "one")
        let before = await writer.batches
        try await SpotlightIndexCoordinator(writer: writer, directory: dir).reconcile(records: records(180), scope: "one")
        #expect(await writer.batches == before)
    }
    @Test func failedBatchResumesAfterLastAcknowledgement() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter()
        await writer.configure(failAt: 2)
        let index = SpotlightIndexCoordinator(writer: writer, directory: dir)
        await #expect(throws: (any Error).self) { try await index.reconcile(records: records(400), scope: "one") }
        let committed = await writer.items.count
        #expect(committed > 0 && committed < 400)
        await writer.configure()
        try await SpotlightIndexCoordinator(writer: writer, directory: dir).reconcile(records: records(400), scope: "one")
        #expect(await writer.totalUpserts == 400)
        #expect(await writer.items.count == 400)
    }
    @Test func recoveryRebuildsLostSystemIndex() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter()
        let coordinator = SpotlightIndexCoordinator(writer: writer, directory: dir)
        try await coordinator.reconcile(records: records(12), scope: "one")
        await writer.loseIndex()
        try await coordinator.reconcile(records: records(12), scope: "one")
        #expect(await writer.items.count == 12)
        #expect(await writer.totalUpserts == 24)
    }
    @Test func selectiveRepairAlsoDeletesUnknownIDs() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter(), values = records(4)
        let index = SpotlightIndexCoordinator(writer: writer, directory: dir)
        try await index.reconcile(records: values, scope: "one")
        try await index.reconcile(records: values, scope: "one", force: [values[0].key, "song:missing"])
        #expect(await writer.totalUpserts == 5)
        #expect(await writer.deleted.contains("song:missing"))
    }
    @Test func fullRepairResubmitsUnchangedMetadata() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter()
        let index = SpotlightIndexCoordinator(writer: writer, directory: dir)
        try await index.reconcile(records: records(5), scope: "one")
        try await index.reconcile(records: records(5), scope: "one", forceAll: true)
        #expect(await writer.totalUpserts == 10)
    }
    @Test func accountChangeClearsOldEntities() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter()
        let index = SpotlightIndexCoordinator(writer: writer, directory: dir)
        try await index.reconcile(records: records(5), scope: "one")
        try await index.reconcile(records: [], scope: "two")
        #expect(await writer.items.isEmpty)
        #expect(await writer.resets == 2)
    }
    @Test func logoutWaitsForInflightWrite() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter()
        await writer.configure(delay: .milliseconds(100))
        let index = SpotlightIndexCoordinator(writer: writer, directory: dir)
        let job = Task { try await index.reconcile(records: records(500), scope: "one") }
        while await writer.active == 0 { await Task.yield() }
        try await index.clear()
        _ = try? await job.value
        #expect(await writer.items.isEmpty)
        #expect(await writer.maxActive == 1)
    }
    @Test func latestSyncWinsWithoutOverlappingBatches() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter()
        await writer.configure(delay: .milliseconds(50))
        let index = SpotlightIndexCoordinator(writer: writer, directory: dir)
        let old = Task { try await index.reconcile(records: records(500), scope: "one") }
        while await writer.active == 0 { await Task.yield() }
        try await index.reconcile(records: records(2), scope: "one")
        _ = try? await old.value
        #expect(await writer.items.count == 2)
        #expect(await writer.maxActive == 1)
    }
    @Test func duplicateIdentityProducesOneItem() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter()
        let index = SpotlightIndexCoordinator(writer: writer, directory: dir)
        try await index.reconcile(records: records(1) + records(1), scope: "one")
        #expect(await writer.totalUpserts == 1)
    }
    @Test func systemCommitBeforeJournalCrashCannotLeaveOrphan() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter()
        let index = SpotlightIndexCoordinator(writer: writer, directory: dir)
        try await index.reconcile(records: records(1), scope: "one")
        // Simulate a system commit followed by a process death before journaling.
        try await writer.apply(upserts: records(2), deletions: [], scope: "one", checkpoint: Data("unacknowledged".utf8))
        try await SpotlightIndexCoordinator(writer: writer, directory: dir).reconcile(records: records(1), scope: "one")
        #expect(await writer.items.count == 1)
        #expect(await writer.resets == 2)
    }
    @Test func tornJournalRecoversAndRemainsWritable() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter()
        try await SpotlightIndexCoordinator(writer: writer, directory: dir).reconcile(records: records(1), scope: "one")
        try Data("{broken".utf8).write(to: dir.appendingPathComponent("journal.jsonl"))
        try await SpotlightIndexCoordinator(writer: writer, directory: dir).reconcile(records: records(2), scope: "one")
        let count = await writer.totalUpserts
        try await SpotlightIndexCoordinator(writer: writer, directory: dir).reconcile(records: records(2), scope: "one")
        #expect(await writer.totalUpserts == count)
    }
    @Test func corruptManifestTriggersSafeRebuild() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: dir.appendingPathComponent("manifest.json"))
        let writer = RecordingSpotlightWriter()
        try await SpotlightIndexCoordinator(writer: writer, directory: dir).reconcile(records: records(2), scope: "one")
        #expect(await writer.resets == 1)
        #expect(await writer.items.count == 2)
    }
    @Test func fingerprintIncludesChangedSearchableFields() throws {
        let first = records(1)[0]
        var second = first; second.genre = "Jazz"
        #expect(try first.fingerprint() != second.fingerprint())
        second = first; second.coverID = "new-art"
        #expect(try first.fingerprint() != second.fingerprint())
        #expect(try first.fingerprint() == first.fingerprint())
    }
    @Test func typesAndAccountsHaveDistinctKeys() {
        let first = records(1)[0]
        var other = first; other.kind = .album
        #expect(first.key != other.key)
        other = first; other.serverID = UUID()
        #expect(first.key != other.key)
    }
    @Test func scopeChangesWithAccountOrServer() {
        let a = SpotlightRecord.scope(serverID: server, address: "https://server", username: "a")
        #expect(a != SpotlightRecord.scope(serverID: server, address: "https://server", username: "b"))
        #expect(a != SpotlightRecord.scope(serverID: server, address: "https://other", username: "a"))
        #expect(!a.contains("https"))
    }
    @Test(arguments: ["normal", "part/one?two#three%", "한글 & café:1", "a%2Fb"])
    func deepLinkPreservesOpaqueID(_ local: String) throws {
        let id = LumaEntityID(serverId: server, localId: local)
        let link = try #require(LumaDeepLink.url(kind: .song, id: id))
        #expect(LumaDeepLink.parse(link)?.id == id)
    }
    @Test func deepLinkRejectsInvalidInput() {
        #expect(LumaDeepLink.parse(URL(string: "https://song/\(server)/one")!) == nil)
        #expect(LumaDeepLink.parse(URL(string: "luma://song/\(server)/one?token=secret")!) == nil)
        #expect(LumaDeepLink.parse(URL(string: "luma://song/\(server)/")!) == nil)
    }
    @Test(arguments: [100, 2_000, 2_739, 10_000, 50_000])
    func syntheticScale(_ count: Int) async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingSpotlightWriter(), values = records(count)
        let index = SpotlightIndexCoordinator(writer: writer, directory: dir)
        let clock = ContinuousClock(), start = clock.now
        try await index.reconcile(records: values, scope: "scale", sourceRevision: "fixture-v1")
        let initial = start.duration(to: clock.now)
        let unchangedStart = clock.now
        let measurement = SpotlightWorkMeasurement("unchanged_revision")
        let cold = SpotlightIndexCoordinator(writer: writer, directory: dir)
        #expect(try await cold.isCurrent(sourceRevision: "fixture-v1", scope: "scale"))
        measurement.end(count: count)
        let unchanged = unchangedStart.duration(to: clock.now)
        print("SPOTLIGHT_SYNTHETIC count=\(count) initial=\(initial) unchanged=\(unchanged) upserts=\(await writer.totalUpserts)")
        #expect(await writer.totalUpserts == count)
        #expect(await writer.items.count == count)
    }
}

@MainActor
@Suite("Native index metadata safety")
struct SpotlightMetadataSafetyTests {
    @Test func searchableMetadataExcludesCommentsAndAudioSettings() throws {
        let song = DisplayableSong(id: "song", title: "Title", artist: "Artist", genre: "Jazz",
            bitRate: 9216, comment: "https://server/rest?password=secret", replayGainTrackGain: -6)
        let snapshot = LibraryIndexService.Snapshot(artists: [], albums: [], playlists: [], songs: [song], date: Date())
        let records = try SpotlightRecord.records(from: snapshot, serverID: UUID())
        let text = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        #expect(!text.contains("secret"))
        #expect(!text.contains("replayGain"))
        #expect(!text.contains("bitRate"))
        #expect(text.contains("Jazz"))
    }
    @Test func attributesAndEntityUseOneCanonicalItem() throws {
        if #available(iOS 27.0, macOS 27.0, *) {
            let record = SpotlightRecord(kind: .song, serverID: UUID(), localID: "a/b", title: "Song",
                artist: "Singer", album: "Record", albumID: "album", genre: "Pop", isFavorite: true, isDownloaded: false)
            let item = NativeSpotlightWriter().item(for: record, scope: "scope")
            #expect(item.uniqueIdentifier == record.key)
            #expect(item.domainIdentifier == "scope")
            #expect(LumaDeepLink.parse(try #require(item.attributeSet.contentURL))?.id.localId == "a/b")
            #expect(item.attributeSet.keywords?.contains("Favorite") == true)
            #expect(item.attributeSet.keywords?.contains("Downloaded Offline") == false)
        }
    }
    @Test func spotlightActivityPreservesTypedIdentity() throws {
        let server = UUID()
        for kind in SpotlightRecord.Kind.allCases {
            let record = SpotlightRecord(kind: kind, serverID: server, localID: "a:b/c", title: "Title")
            let url = try #require(NativeSearchLifecycle.url(for: record.key))
            #expect(LumaDeepLink.parse(url)?.id.localId == record.localID)
            #expect(url.host == kind.rawValue)
        }
    }
}
