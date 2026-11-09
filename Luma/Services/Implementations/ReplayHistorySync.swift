import Foundation
import SwiftSonic

/// Isolate the non-standard API, network lifetime and SQLite writes from playback and the UI.
actor ReplayHistorySync {
    nonisolated static let enabledKey = "luma.replay.serverHistory"
    nonisolated static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    let server: any ServerServiceProtocol
    private let backup: @Sendable (ServerSnapshot, URL) async throws -> Void
    private let directory: URL
    private var running: Set<String> = []
    private var draining: Set<String> = []
    private var lastAttempt: [String: Date] = [:]
    private var tokenCache: [String: NavidromeLogin] = [:]
    private var unsupportedUntil: [String: Date] = [:]
    private var lastStatus: [String: String] = [:]

    init(server: any ServerServiceProtocol, directory: URL?, backup: @escaping @Sendable (ServerSnapshot, URL) async throws -> Void = { _, _ in }) {
        self.backup = backup
        self.server = server
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "Luma/Replay")
    }

    private func store(_ account: ServerSnapshot) throws -> ReplayHistoryStore {
        try ReplayHistoryStore(url: directory.appendingPathComponent(account.replayProfile + ".sqlite"))
    }

    func sync(force: Bool = false, rescan: Bool = false, minimumInterval: TimeInterval = 60, retryExpired: Bool = true) async -> String {
        guard let account = await server.state.activeServer else { return "No active account" }
        let profile = account.replayProfile
        guard await server.state.isOnline, await server.state.isServerReachable else { return "Offline" }
        guard Self.enabled else { return "Local listening history" }
        guard running.insert(profile).inserted else { return "Syncing" }
        defer { running.remove(profile) }
        if !force, let last = lastAttempt[profile], Date().timeIntervalSince(last) < minimumInterval {
            return lastStatus[profile] ?? "Syncing"
        }
        if !force, let until = unsupportedUntil[profile], until > Date() { return lastStatus[profile] ?? "Server history unavailable" }
        lastAttempt[profile] = Date()
        let syncTrace = DiagnosticsCenter.shared.begin(.replaySync)
        var syncResult = DiagnosticsResult.failure
        defer { syncTrace.finish(Task.isCancelled ? .cancelled : syncResult) }
        let status: String
        do {
            let context = try await server.requestContext(serverID: account.id)
            guard await server.state.activeServer == account else { throw CancellationError() }
            guard let url = URL(string: account.baseURL),
                  url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? "")) else {
                return "HTTPS required for Replay sync"
            }
            let caps = try await context.client.loadCapabilities()
            guard caps.serverType?.lowercased() == "navidrome" else { return "Server history unavailable" }
            guard !context.credentials.password.isEmpty else { return "Navidrome password required for Replay sync" }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            let transport = URLSessionTransport(configuration: config, sameOriginOnly: true)
            let headers = context.credentials.customHeaders.filter { $0.key.caseInsensitiveCompare("x-nd-authorization") != .orderedSame }
            let api = NavidromeNativeAPI(transport: CustomHeadersTransport(base: transport, headers: headers))
            let login: NavidromeLogin
            let tokenKey = profile + ":" + String(context.identity.revision)
            if let saved = tokenCache[tokenKey] { login = saved }
            else {
                login = try await api.login(baseURL: url, username: account.username, password: context.credentials.password)
                tokenCache = [tokenKey: login]
            }
            guard let uid = login.id, !uid.isEmpty, login.username?.caseInsensitiveCompare(account.username) == .orderedSame else {
                throw NavidromeNativeAPIError.invalidResponse
            }
            guard await server.state.requestIsCurrent(context.identity) else { throw CancellationError() }
            let priorUID = UserDefaults.standard.string(forKey: account.replayUIDKey)
            UserDefaults.standard.set(uid, forKey: account.replayUIDKey)
            if let priorUID, priorUID != uid { UserDefaults.standard.set(uid, forKey: account.replayUIDKey + ".replacement") }
            let db = try store(account)
            let scan = "scan:" + uid
            let scanDateKey = account.replayUIDKey + ".full." + uid
            let lastFull = UserDefaults.standard.double(forKey: scanDateKey)
            let saved = try db.cursor(uid)
            let partial = try db.cursor(scan)
            var full = rescan || saved.completed == nil || partial.count > 0 || Date().timeIntervalSince1970 - lastFull > 7 * 86400
            var cursor = full ? partial : saved
            if cursor.count > 0 {
                let anchor = try await api.scrobbles(baseURL: url, token: login.token, offset: cursor.count - 1, limit: 1)
                if anchor.first?.id != cursor.last {
                    try db.reset(scan)
                    full = true
                    cursor = (0, 0, nil)
                }
            }
            var offset = cursor.count
            var previous = cursor.last
            while true {
                try Task.checkCancellation()
                let page = try await api.scrobbles(baseURL: url, token: login.token, offset: offset, limit: 500)
                try Task.checkCancellation()
                guard Self.enabled, await server.state.requestIsCurrent(context.identity) else { throw CancellationError() }
                let complete = page.count < 500
                try db.save(page, uid: full ? scan : uid, offset: offset, previous: previous, complete: complete)
                if complete { break }
                offset += page.count
                previous = page.last!.id
            }
            if full {
                let backupURL = directory.appendingPathComponent(account.replayProfile + "-" + uid.utf8.map { String(format: "%02x", $0) }.joined() + ".jsonl")
                try await backup(account, backupURL)
                try Task.checkCancellation()
                guard Self.enabled, await server.state.requestIsCurrent(context.identity) else { throw CancellationError() }
                try db.publish(scan: scan, uid: uid)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: scanDateKey)
            }
            if !draining.contains(profile) { try db.reconcileSubmissions(uid: uid, owner: account.outboxOwner) }
            try await flush(account: account, context: context)
            unsupportedUntil[profile] = nil
            status = "Synced"
            syncResult = .success
        } catch is CancellationError {
            lastAttempt[profile] = nil
            syncResult = .cancelled
            return "Sync paused"
        } catch NavidromeNativeAPIError.metadataRequestFailed(statusCode: 401) {
            tokenCache.removeAll()
            if retryExpired {
                running.remove(profile)
                return await sync(force: true, rescan: rescan, minimumInterval: minimumInterval, retryExpired: false)
            }
            status = "Sign in to sync Replay"
        } catch NavidromeNativeAPIError.metadataRequestFailed(statusCode: 404) {
            unsupportedUntil[profile] = Date().addingTimeInterval(12 * 3600)
            status = "Server history unavailable · Navidrome 0.64.2 supports Replay"
        } catch {
            status = "Couldn’t sync · saved history available"
        }
        lastStatus[profile] = status
        return status
    }

    func mirror(account: ServerSnapshot) throws -> (url: URL, uid: String, lastSync: Date)? {
        guard Self.enabled, let uid = UserDefaults.standard.string(forKey: account.replayUIDKey),
              let completed = try store(account).cursor(uid).completed else { return nil }
        return (directory.appendingPathComponent(account.replayProfile + ".sqlite"), uid, completed)
    }

    func revision(for account: ServerSnapshot) throws -> String? {
        guard let mirror = try mirror(account: account) else { return nil }
        let cursor = try store(account).cursor(mirror.uid)
        let full = UserDefaults.standard.double(forKey: account.replayUIDKey + ".full." + mirror.uid)
        return "\(account.replayProfile):\(mirror.uid):\(cursor.last):\(full)"
    }

    func submit(session: UUID, track: String, date: Date, account: ServerSnapshot) async throws {
        // Store the immutable request before looking up a client. Offline plays survive termination.
        let db = try store(account)
        try db.enqueue(session: session, track: track, date: date, owner: account.outboxOwner)
        try await flushIfOnline(account)
    }

    func flushIfOnline(_ account: ServerSnapshot) async throws {
        guard await server.state.isOnline, await server.state.isServerReachable, await server.state.activeServer == account else { return }
        let context = try await server.requestContext(serverID: account.id)
        guard await server.state.activeServer == account else { return }
        try await flush(account: account, context: context)
    }

    private func flush(account: ServerSnapshot, context: ServerRequestContext) async throws {
        let profile = account.replayProfile
        guard draining.insert(profile).inserted else { return }
        defer { draining.remove(profile) }
        let db = try store(account)
        while true {
            let rows = try db.pending(owner: account.outboxOwner)
            guard !rows.isEmpty else { break }
            for row in rows {
                try Task.checkCancellation()
                guard await server.state.requestIsCurrent(context.identity) else { throw CancellationError() }
                try db.mark(row.session, state: 1)
                do {
                    try await context.client.scrobble(id: row.track, time: Date(timeIntervalSince1970: Double(row.stamp)), submission: true)
                    try db.mark(row.session, state: 2)
                } catch SwiftSonicError.network(let error) where [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code) {
                    try db.mark(row.session, state: 0)
                    throw error
                }
                // A lost acknowledgement is ambiguous. Keep the receipt for reconciliation
                // and never blindly send it a second time.
            }
        }
    }
}

extension ServerSnapshot {
    nonisolated var replayUIDKey: String { "replay.uid." + replayProfile }
    nonisolated var outboxOwner: String { UserDefaults.standard.string(forKey: replayUIDKey + ".replacement") ?? "" }
    nonisolated var localReplayID: String {
        let key = "replay.legacyOwner." + id.uuidString
        let defaults = UserDefaults.standard
        if defaults.string(forKey: key) == nil { defaults.set(replayProfile, forKey: key) }
        if !outboxOwner.isEmpty { return replayProfile + ":" + outboxOwner }
        return defaults.string(forKey: key) == replayProfile ? id.uuidString : replayProfile
    }
}
