import AppIntents
import CoreSpotlight
import Foundation
import OSLog

@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class LumaNativeSearch: NSObject, CSSearchableIndexDelegate {
    static let shared = LumaNativeSearch()
    static let enabledKey = "luma.search.spotlight.enabled"
    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
    private let writer: NativeSpotlightWriter
    let coordinator: SpotlightIndexCoordinator
    private var snapshot: LibraryIndexService.Snapshot?
    private var serverID: UUID?
    private(set) var scope: String?
    private var schedule: Task<Void, Never>?
    private var revision: UInt64 = 0
    var accountScope: (@MainActor () -> (UUID, String)?)?
    var persistedSnapshotProvider: (@MainActor (UUID, String) async -> LibraryIndexService.Snapshot?)?
    var localState: (@MainActor (UUID) async throws -> SpotlightLocalState)?
    var isPlaying: (@MainActor () -> Bool)?
    private var retryCount = 0
    private var needsReconciliation = false
    private var isSuspended = false
    private var artworkCoverIDs = Set<String>()
    private var repairIDs = Set<String>()
    private var repairAll = false
    private var repairAcknowledgements: [() -> Void] = []

    override init() {
        let writer = NativeSpotlightWriter()
        self.writer = writer
        self.coordinator = SpotlightIndexCoordinator(writer: writer,
            directory: LibraryIndexService.defaultDirectory.deletingLastPathComponent().appendingPathComponent("spotlight-v3"),
            usesPersistedClientState: false)
        super.init()
        writer.index.indexDelegate = self
    }

    func accept(_ value: LibraryIndexService.Snapshot, serverID: UUID) {
        guard let account = accountScope?(), account.0 == serverID else { return }
        if self.serverID == serverID, scope == account.1, snapshot?.date == value.date { return }
        snapshot = value
        self.serverID = serverID
        scope = account.1
        revision &+= 1
        retryCount = 0
        needsReconciliation = true
        scheduleReconciliation()
    }

    func configureArtwork(_ store: SpotlightArtworkStore) { writer.artwork = store }

    func artworkChanged(coverID: String) {
        guard snapshot != nil else { return }
        artworkCoverIDs.insert(coverID)
        refreshLocalState()
    }

    func suspend() { isSuspended = true; schedule?.cancel() }
    func resume() { isSuspended = false; if needsReconciliation { scheduleReconciliation() } }

    func refreshLocalState() {
        guard snapshot != nil else { return }
        revision &+= 1
        retryCount = 0
        needsReconciliation = true
        scheduleReconciliation(delay: .seconds(2))
    }

    private func scheduleReconciliation(delay: Duration = .milliseconds(400)) {
        schedule?.cancel()
        guard !isSuspended else { return }
        schedule = Task(priority: .utility) { [weak self] in
            do {
                // Coalesce a cached install followed immediately by fresh sync.
                try await Task.sleep(for: delay)
                try await self?.reindex()
            } catch is CancellationError {
            } catch is SpotlightWorkDeferred {
                guard let self, !Task.isCancelled, !self.isSuspended else { return }
                self.scheduleReconciliation(delay: .seconds(15))
            } catch {
                Logger.siri.error("Spotlight submission failed; checkpoint retained")
                guard let self, !Task.isCancelled, self.retryCount < 2 else { return }
                self.retryCount += 1
                try? await Task.sleep(for: .seconds(self.retryCount * 5))
                guard !Task.isCancelled else { return }
                self.scheduleReconciliation()
            }
        }
    }

    func reindex(kind: SpotlightRecord.Kind? = nil, identifiers: [String]? = nil, all: Bool = false) async throws {
        guard isEnabled else { return }
        _ = try workBudget()
        if snapshot == nil, let account = accountScope?(),
           let persisted = await persistedSnapshotProvider?(account.0, account.1) {
            snapshot = persisted
            serverID = account.0
            scope = account.1
            Logger.siri.info("[SPOTLIGHT] restored persisted SQLite snapshot for cold-start")
        }
        guard let snapshot, let serverID, let scope, accountScope?()?.1 == scope else {
            Logger.siri.error("[SPOTLIGHT] reindex unavailable: no memory or persisted snapshot")
            throw CocoaError(.fileReadNoSuchFile)
        }
        let token = revision
        let flags = try await localState?(serverID)
        try Task.checkCancellation()
        let sourceRevision = try SpotlightRecord.digest(JSONEncoder().encode([
            ["mapping-v4", String(snapshot.date.timeIntervalSinceReferenceDate)],
            flags?.favoriteKeys.sorted() ?? [],
            flags?.downloadedSongs.sorted() ?? []
        ]))
        if !all, identifiers == nil, artworkCoverIDs.isEmpty, repairIDs.isEmpty, !repairAll,
           try await coordinator.isCurrent(sourceRevision: sourceRevision, scope: scope) {
            guard token == revision, accountScope?()?.1 == scope else { throw CancellationError() }
            needsReconciliation = false
            Logger.siri.info("[SPOTLIGHT] unchanged persisted snapshot; record conversion and hashing skipped")
            return
        }
        let changedCovers = artworkCoverIDs
        let worker = Task.detached(priority: .utility) {
            var records = try SpotlightRecord.records(from: snapshot, serverID: serverID)
            if let flags {
                for index in records.indices {
                    try Task.checkCancellation()
                    records[index].isFavorite = flags.favoriteKeys.contains(records[index].key)
                    if records[index].kind == .song {
                        records[index].isDownloaded = flags.downloadedSongs.contains(records[index].localID)
                    }
                }
            }
            let artworkKeys = Set(records.filter { record in
                record.coverID.map(changedCovers.contains) ?? false
            }.map(\.key))
            return (records, artworkKeys)
        }
        let (records, artworkKeys) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard token == revision, accountScope?()?.1 == scope else { throw CancellationError() }
        let force: Set<String>
        if let kind, let identifiers { force = Set(identifiers.map { kind.rawValue + ":" + $0 }) }
        else if let identifiers { force = Set(identifiers) }
        else if all, let kind { force = Set(records.filter { $0.kind == kind }.map(\.key)) }
        else { force = [] }
        try await coordinator.reconcile(records: records, scope: scope, force: force.union(artworkKeys).union(repairIDs),
            forceAll: (all && kind == nil) || repairAll, sourceRevision: sourceRevision,
            budget: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.workBudget()
            })
        if token == revision { needsReconciliation = false; artworkCoverIDs = []; acknowledgeRepairs() }
    }

    func clear() async throws {
        revision &+= 1
        schedule?.cancel()
        schedule = nil
        snapshot = nil; serverID = nil; scope = nil
        artworkCoverIDs = []; needsReconciliation = false
        try await coordinator.clear()
        acknowledgeRepairs()
    }

    private func workBudget() throws -> SpotlightWorkBudget {
        try SpotlightWorkBudget.make(active: !isSuspended, playing: isPlaying?() == true,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: ThermalPressure(ProcessInfo.processInfo.thermalState))
    }

    private func acknowledgeRepairs() {
        let callbacks = repairAcknowledgements
        repairAcknowledgements = []; repairIDs = []; repairAll = false
        callbacks.forEach { $0() }
    }

    private func requestRepair(identifiers: [String]?, acknowledgement: @escaping () -> Void) {
        if let identifiers { repairIDs.formUnion(identifiers) } else { repairAll = true }
        repairAcknowledgements.append(acknowledgement)
        revision &+= 1
        needsReconciliation = true
        if snapshot != nil { scheduleReconciliation() }
        // No snapshot yet: retain the request until the normal catalog restore
        // calls accept(). Acknowledge only after its durable submission succeeds.
        if !isEnabled {
            Task {
                do { try await coordinator.clear(); acknowledgeRepairs() }
                catch { Logger.siri.error("Disabled Spotlight index cleanup failed") }
            }
        }
    }

    func setEnabled(_ enabled: Bool) async throws {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { needsReconciliation = true; scheduleReconciliation() }
        else {
            revision &+= 1
            schedule?.cancel()
            try await coordinator.clear()
            acknowledgeRepairs()
        }
    }

    /// Account changes cancel old work before the next snapshot can be installed.
    func accountDidChange() async {
        let key = "luma.search.lastAccountScope"
        let current = accountScope?()?.1
        let previous = UserDefaults.standard.string(forKey: key)
        if let previous, previous != current {
            do {
                try await clear()
                try await SiriDonations.clear()
                try await RelevantEntities.shared.removeAllEntities()
            } catch { Logger.siri.error("Spotlight account cleanup failed"); return }
        }
        UserDefaults.standard.set(current, forKey: key)
    }

    func resolveSongKeys(_ keys: [String], scope expectedScope: String) -> [DisplayableSong] {
        guard expectedScope == scope, accountScope?()?.1 == expectedScope,
              let snapshot, let serverID else { return [] }
        let order = Dictionary(keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return snapshot.songs.compactMap { song -> (Int, DisplayableSong)? in
            let key = "song:" + LumaEntityID(serverId: serverID, localId: song.id).rawValue
            return order[key].map { ($0, song) }
        }.sorted { $0.0 < $1.0 }.prefix(40).map(\.1)
    }

    func search(_ text: String, limit: Int) async -> LibraryIndexService.LocalHits? {
        guard isEnabled, let scope, accountScope?()?.1 == scope, let snapshot, let serverID,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let token = revision
        guard !needsReconciliation else { return nil }
        let trace = DiagnosticsCenter.shared.begin(.spotlightQuery)
        var traceResult = DiagnosticsResult.cancelled
        defer { trace.finish(Task.isCancelled ? .cancelled : traceResult) }
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try await SpotlightQueryAdapter.search(text, scope: scope, limit: limit)
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            let keys = Set(result.keys)
            guard token == revision, accountScope?()?.1 == scope, !Task.isCancelled else { return nil }
            // Spotlight is a candidate source, never authoritative metadata. Resolve
            // only IDs in the current account's synchronized catalog (offline too).
            let mapping = Task.detached(priority: .utility) {
                func contains(_ kind: String, _ id: String) -> Bool {
                    !Task.isCancelled && keys.contains(kind + ":" + LumaEntityID(serverId: serverID, localId: id).rawValue)
                }
                var hits = LibraryIndexService.LocalHits(
                    artists: snapshot.artists.filter { contains("artist", $0.id) },
                    albums: snapshot.albums.filter { contains("album", $0.id) },
                    playlists: snapshot.playlists.filter { contains("playlist", $0.id) },
                    songs: snapshot.songs.filter { contains("song", $0.id) })
                hits.rankedIDs = result.keys.compactMap { key in
                    guard let colon = key.firstIndex(of: ":"),
                          let id = LumaEntityID(rawValue: String(key[key.index(after: colon)...])),
                          id.serverId == serverID else { return nil }
                    return String(key[...colon]) + id.localId
                }
                hits.suggestions = result.suggestions
                return hits
            }
            let hits = await withTaskCancellationHandler { await mapping.value } onCancel: { mapping.cancel() }
            guard token == revision, accountScope?()?.1 == scope, !Task.isCancelled else { return nil }
            Logger.siri.info(
                "[SPOTLIGHT] query returned total=\(keys.count, privacy: .public) songs=\(hits.songs.count, privacy: .public) albums=\(hits.albums.count, privacy: .public) artists=\(hits.artists.count, privacy: .public) playlists=\(hits.playlists.count, privacy: .public)"
            )
            traceResult = .success
            return hits
        } catch {
            traceResult = DiagnosticsResult.classify(error)
            Logger.siri.error("[SPOTLIGHT] query failed error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        Logger.siri.info("[SPOTLIGHT] system requested full reindex")
        Task { @MainActor in self.requestRepair(identifiers: nil, acknowledgement: acknowledgementHandler) }
    }
    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String], acknowledgementHandler: @escaping () -> Void) {
        Logger.siri.info("[SPOTLIGHT] system requested repair count=\(identifiers.count, privacy: .public)")
        Task { @MainActor in self.requestRepair(identifiers: identifiers, acknowledgement: acknowledgementHandler) }
    }
}
