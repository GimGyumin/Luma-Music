import Foundation
import OSLog

nonisolated protocol SpotlightIndexWriting: Sendable {
    func apply(upserts: [SpotlightRecord], deletions: [String], scope: String, checkpoint: Data) async throws
    func reset() async throws
    func clientState() async throws -> Data?
}

/// A single worker owns all index mutations. The predecessor is awaited even
/// after cancellation, so an in-flight XPC write can never race a logout/delete.
actor SpotlightIndexCoordinator {
    enum Status: Sendable, Equatable {
        case idle, indexing, submitted(upserts: Int, deletions: Int), cancelled, failed
    }
    private let writer: any SpotlightIndexWriting
    private let directory: URL
    private var worker: Task<Void, Error>?
    private var generation: UInt64 = 0
    private(set) var status: Status = .idle
    private let usesPersistedClientState: Bool

    func isCurrent(sourceRevision: String, scope: String) async throws -> Bool {
        let token = generation
        _ = try? await worker?.value
        guard token == generation else { return false }
        let directory = directory
        let ledger = try await Task.detached(priority: .utility) { try Ledger.load(directory: directory) }.value
        return token == generation && ledger.scope == scope && ledger.sourceRevision == sourceRevision
    }

    init(writer: any SpotlightIndexWriting, directory: URL, usesPersistedClientState: Bool = true) {
        self.writer = writer
        self.directory = directory
        self.usesPersistedClientState = usesPersistedClientState
    }

    func reconcile(records: [SpotlightRecord], scope: String, force: Set<String> = [], forceAll: Bool = false,
                   sourceRevision: String? = nil,
                   budget: @escaping @Sendable () async throws -> SpotlightWorkBudget = { .unrestricted }) async throws {
        generation &+= 1
        let token = generation
        let predecessor = worker
        predecessor?.cancel()
        let writer = writer, directory = directory
        let shouldCheckClientState = usesPersistedClientState
        let requestedCounts = Dictionary(grouping: records, by: \.kind)
            .mapValues(\.count)
        Logger.siri.info(
            "[SPOTLIGHT] reconcile requested total=\(records.count, privacy: .public) songs=\(requestedCounts[.song, default: 0], privacy: .public) albums=\(requestedCounts[.album, default: 0], privacy: .public) artists=\(requestedCounts[.artist, default: 0], privacy: .public) playlists=\(requestedCounts[.playlist, default: 0], privacy: .public) scope=\(scope, privacy: .private(mask: .hash))"
        )
        let task = Task.detached(priority: .utility) {
            _ = try? await predecessor?.value
            try Task.checkCancellation()
            var ledger = try Ledger.load(directory: directory)
            // Old indexAppEntities-only installations have no manifest. Clear that
            // named index once before introducing canonical, typed identifiers.
            let state = try await writer.clientState()
            // Writers using Core Spotlight's non-batch API do not have a
            // persisted client state. System repair callbacks force the
            // affected records back through this same ledger.
            let scopeChanged = ledger.scope != scope
            var checkpointMismatch = false
            if shouldCheckClientState {
                if let persisted = state {
                    checkpointMismatch = ledger.checkpoint.map { checkpoint in
                        Data(checkpoint.utf8) != persisted
                    } ?? true
                } else {
                    checkpointMismatch = ledger.checkpoint != nil
                }
            }
            if scopeChanged || checkpointMismatch {
                try await writer.reset()
                ledger = Ledger(scope: scope)
                try ledger.compact(directory: directory)
            }
            if let sourceRevision, sourceRevision == ledger.sourceRevision, force.isEmpty, !forceAll {
                return (0, 0)
            }
            _ = try await budget()
            var wanted: [String: (SpotlightRecord, String)] = [:]
            let fingerprintMeasurement = SpotlightWorkMeasurement("fingerprint")
            for record in records {
                try Task.checkCancellation()
                wanted[record.key] = (record, try record.fingerprint())
            }
            fingerprintMeasurement.end(count: records.count)
            let removed = ledger.fingerprints.keys.filter { wanted[$0] == nil }.sorted()
            let changed = wanted.keys.filter { forceAll || force.contains($0) || wanted[$0]!.1 != ledger.fingerprints[$0] }.sorted()
            // Even missing requested IDs must be explicitly removed during repair.
            let missing = force.filter { wanted[$0] == nil && !removed.contains($0) }
            let deletions = removed + missing.sorted()
            // Invalidate the persisted shortcut before XPC: a partial write must not
            // leave an older snapshot looking completely installed.
            if (!changed.isEmpty || !deletions.isEmpty), ledger.sourceRevision != nil {
                ledger.sourceRevision = nil
                try ledger.compact(directory: directory)
            }
            var upsertCount = 0, deletionCount = 0
            var u = 0, d = 0
            while u < changed.count || d < deletions.count {
                try Task.checkCancellation()
                let policy = try await budget()
                let size = policy.batchSize
                let keys = Array(changed.dropFirst(u).prefix(size))
                let deleted = Array(deletions.dropFirst(d).prefix(size - keys.count))
                let hashes = Dictionary(uniqueKeysWithValues: keys.map { ($0, wanted[$0]!.1) })
                let checkpoint = UUID().uuidString
                try await writer.apply(upserts: keys.map { wanted[$0]!.0 }, deletions: deleted,
                    scope: scope, checkpoint: Data(checkpoint.utf8))
                // Journal only acknowledged batches, even if cancelled while XPC
                // was running. A crash before this append simply replays one batch.
                let delta = Ledger.Delta(upserts: hashes, deletions: deleted, checkpoint: checkpoint)
                try ledger.append(delta, directory: directory)
                ledger.apply(delta)
                u += keys.count; d += deleted.count
                upsertCount += keys.count; deletionCount += deleted.count
                if policy.pause > .zero { try await Task.sleep(for: policy.pause) }
                await Task.yield()
            }
            if upsertCount > 0 || deletionCount > 0 || ledger.sourceRevision != sourceRevision {
                ledger.sourceRevision = sourceRevision
                try ledger.compact(directory: directory)
            }
            return (upsertCount, deletionCount)
        }
        let start = ContinuousClock.now
        status = .indexing
        let completion = Task {
            try await withTaskCancellationHandler { _ = try await task.value } onCancel: { task.cancel() }
        }
        worker = completion
        do {
            let counts = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if token == generation {
                status = .submitted(upserts: counts.0, deletions: counts.1)
                Logger.siri.info("Spotlight submitted upserts=\(counts.0) deletions=\(counts.1) elapsed=\(String(describing: start.duration(to: .now)), privacy: .public)")
            }
        } catch {
            if token == generation { status = error is CancellationError ? .cancelled : .failed }
            if !(error is CancellationError) { DiagnosticsCenter.shared.report(.spotlight) }
            Logger.siri.error("[SPOTLIGHT] reconcile failed error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func clear() async throws {
        generation &+= 1
        let token = generation
        let predecessor = worker
        predecessor?.cancel()
        let writer = writer, directory = directory
        let task = Task.detached(priority: .utility) {
            _ = try? await predecessor?.value
            try await writer.reset()
            try Ledger(scope: nil).compact(directory: directory)
        }
        worker = task
        do {
            try await task.value
            Logger.siri.info("[SPOTLIGHT] reset succeeded")
        } catch {
            Logger.siri.error("[SPOTLIGHT] reset failed error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
        if token == generation { status = .idle }
    }

    /// Fingerprints only, not another copy of the catalog. An append-only journal
    /// avoids rewriting a 50k-item manifest for every 160-item batch.
    private nonisolated struct Ledger: Codable {
        var scope: String?
        var fingerprints: [String: String] = [:]
        var checkpoint: String? = nil
        var sourceRevision: String? = nil
        struct Delta: Codable { var upserts: [String: String]; var deletions: [String]; var checkpoint: String }
        static func load(directory: URL) throws -> Self {
            let file = directory.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return Self(scope: nil) }
            guard var result = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: file)) else { return Self(scope: nil) }
            let journal = directory.appendingPathComponent("journal.jsonl")
            if let data = try? Data(contentsOf: journal) {
                for line in data.split(separator: 10) {
                    // A torn final append is replayed from the last valid batch.
                    guard let delta = try? JSONDecoder().decode(Delta.self, from: Data(line)) else {
                        try result.compact(directory: directory)
                        break
                    }
                    result.apply(delta)
                }
            }
            return result
        }
        mutating func apply(_ delta: Delta) {
            sourceRevision = nil
            fingerprints.merge(delta.upserts, uniquingKeysWith: { _, new in new })
            for key in delta.deletions { fingerprints.removeValue(forKey: key) }
            checkpoint = delta.checkpoint
        }
        func append(_ delta: Delta, directory: URL) throws {
            let measurement = SpotlightWorkMeasurement("journal")
            defer { measurement.end(count: delta.upserts.count + delta.deletions.count) }
            let file = directory.appendingPathComponent("journal.jsonl")
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONEncoder().encode(delta) + Data([10]))
            try handle.synchronize()
        }
        func compact(directory: URL) throws {
            let measurement = SpotlightWorkMeasurement("manifest")
            defer { measurement.end(count: fingerprints.count) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest = directory.appendingPathComponent("manifest.json")
            try JSONEncoder().encode(self).write(to: manifest, options: .atomic)
            // Do not discard the acknowledged journal until its replacement is durable.
            let handle = try FileHandle(forWritingTo: manifest)
            defer { try? handle.close() }
            try handle.synchronize()
            try Data().write(to: directory.appendingPathComponent("journal.jsonl"), options: .atomic)
        }
    }
}
