// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog

/// One bounded throughput sample. Returns bytes per second, or `nil` when nothing arrived.
nonisolated protocol SpeedSampling: Sendable {
    func sample(url: URL, headers: [String: String], maxBytes: Int, budget: TimeInterval) async -> Double?
}

/// Reads a small ranged slice of a stream and reports the sustained rate.
///
/// The request comes from `SwiftSonic` (`streamURL`) and only asks for `maxBytes`, so a slow link
/// spends a fraction of a second of data instead of a whole track. A partial read (timeout before
/// `maxBytes`) still yields a usable rate — that is exactly the case worth measuring.
nonisolated struct URLSessionSpeedSampler: SpeedSampling {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.networkServiceType = .responsiveData
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = 3
        config.allowsConstrainedNetworkAccess = false
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    func sample(url: URL, headers: [String: String], maxBytes: Int, budget: TimeInterval) async -> Double? {
        var request = URLRequest(url: url)
        request.timeoutInterval = budget
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=0-\(max(maxBytes, 1) - 1)", forHTTPHeaderField: "Range")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        var received = 0
        var chunk = [UInt8]()
        chunk.reserveCapacity(8 * 1024)
        var bodyStarted: Date?

        do {
            let (bytes, response) = try await Self.session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Logger.network.debug("Speed probe rejected with status \(http.statusCode)")
                return nil
            }
            // The clock starts when the *response* arrives, not when the request was sent. A server
            // starting a transcode (or a high-latency link) can spend most of `budget` before the first
            // body byte, and counting that wait as transfer time is what reported a healthy Wi-Fi link
            // as "96 KB/s" — which then capped Automatic playback to a lossy 397 kbps transcode.
            let started = Date()
            bodyStarted = started
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= 8 * 1024 {
                    received += chunk.count
                    chunk.removeAll(keepingCapacity: true)
                    if received >= maxBytes { break }
                    if Date().timeIntervalSince(started) >= budget { break }
                }
            }
            received += chunk.count
        } catch {
            // A timeout after some bytes still measures the link; only a total failure is unusable.
            received += chunk.count
            if received == 0 {
                Logger.network.debug("Speed probe failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        guard !Task.isCancelled, let bodyStarted else { return nil }
        let elapsed = Date().timeIntervalSince(bodyStarted)
        // Too little data (or no measurable window) cannot separate a slow link from a stalled
        // request. Report "unknown" so the caller keeps Automatic as configured instead of capping it;
        // a link that really cannot keep up still lowers quality through the underrun path.
        guard received >= Self.minimumSampleBytes, elapsed > 0.05 || received >= maxBytes else {
            Logger.network.debug(
                "Speed probe inconclusive — \(received, privacy: .public) bytes in \(Int(elapsed * 1000), privacy: .public)ms"
            )
            return nil
        }
        let rate = Double(received) / max(elapsed, 0.05)
        Logger.network.debug(
            "Speed probe sample — \(received, privacy: .public) bytes in \(Int(elapsed * 1000), privacy: .public)ms (warm-up excluded) → \(Int(rate / 1_024), privacy: .public) KB/s"
        )
        return rate
    }

    /// Below this a sample cannot separate a slow link from a stalled request, and a rate derived from
    /// it would cap Automatic quality on a link that may be perfectly fine.
    private static let minimumSampleBytes = 24 * 1024
}

/// Reuses throughput samples for the same server, account and network path.
actor NetworkSpeedProbe {
    private let sampler: any SpeedSampling
    private let ttl: TimeInterval
    private let maxBytes: Int
    private let budget: TimeInterval

    nonisolated struct Scope: Equatable, Sendable {
        let accountRevision: UInt64
        let networkRevision: UInt64
    }

    private var cached: [UUID: (scope: Scope?, bytesPerSecond: Double, sampledAt: Date)] = [:]
    private var inFlight: [UUID: (scope: Scope?, token: UUID, task: Task<Double?, Never>)] = [:]

    init(
        sampler: any SpeedSampling = URLSessionSpeedSampler(),
        ttl: TimeInterval = 120,
        maxBytes: Int = 96 * 1_024,
        budget: TimeInterval = 1.5
    ) {
        self.sampler = sampler
        self.ttl = ttl
        self.maxBytes = maxBytes
        self.budget = budget
    }

    /// A still-fresh measurement, without starting a new one.
    func freshRate(serverId: UUID, scope: Scope? = nil) -> Double? {
        guard let entry = cached[serverId], entry.scope == scope,
              Date().timeIntervalSince(entry.sampledAt) < ttl else { return nil }
        return entry.bytesPerSecond
    }

    /// Returns the measured rate, reusing a fresh cache entry and de-duplicating concurrent callers.
    func measurement(serverId: UUID, url: URL, headers: [String: String], scope: Scope? = nil) async -> Double? {
        if let rate = freshRate(serverId: serverId, scope: scope) { return rate }
        if let existing = inFlight[serverId] {
            if existing.scope == scope { return await existing.task.value }
            existing.task.cancel()
        }

        let sampler = self.sampler
        let maxBytes = self.maxBytes
        let budget = self.budget
        let task = Task.detached(priority: .utility) { () -> Double? in
            await sampler.sample(url: url, headers: headers, maxBytes: maxBytes, budget: budget)
        }
        let token = UUID()
        inFlight[serverId] = (scope, token, task)
        let rate = await task.value
        guard inFlight[serverId]?.token == token else { return nil }
        inFlight[serverId] = nil
        if let rate {
            cached[serverId] = (scope, rate, Date())
            Logger.network.info(
                "Measured \(Int(rate / 1_024), privacy: .public) KB/s for automatic-quality adaptation"
            )
        }
        return rate
    }

    /// Test/inspection hook.
    func reset() {
        cached.removeAll()
        for pending in inFlight.values { pending.task.cancel() }
        inFlight.removeAll()
    }
}
