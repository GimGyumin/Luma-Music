// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Limits for the automatic streaming cache. Permanent downloads are represented
/// by `isPinned`/`DownloadedTrack` and are never candidates for this policy.
nonisolated struct CacheMaintenancePolicy: Sendable, Equatable {
    /// Entries not used for this long may be removed even when capacity is fine.
    var maximumAge: TimeInterval
    /// Capacity eviction leaves this fraction of the configured limit free so a
    /// burst of playback does not immediately trigger another cleanup.
    var targetFraction: Double
    /// Recently used entries are protected from age-based removal.
    var recentProtection: TimeInterval
    /// When free space is below this, use a more aggressive target and TTL.
    var lowStorageReserve: Int64
    var lowStorageMaximumAge: TimeInterval

    static let automatic = CacheMaintenancePolicy(
        maximumAge: 30 * 24 * 60 * 60,
        targetFraction: 0.85,
        recentProtection: 24 * 60 * 60,
        lowStorageReserve: 1_500 * 1_024 * 1_024,
        lowStorageMaximumAge: 7 * 24 * 60 * 60
    )

    static let manual = CacheMaintenancePolicy(
        maximumAge: 30 * 24 * 60 * 60,
        targetFraction: 0.75,
        recentProtection: 6 * 60 * 60,
        lowStorageReserve: 1_500 * 1_024 * 1_024,
        lowStorageMaximumAge: 7 * 24 * 60 * 60
    )

    func targetBytes(for configuredLimit: Int64, freeBytes: Int64?) -> Int64 {
        let aggressive = freeBytes.map { $0 < lowStorageReserve } ?? false
        let fraction = aggressive ? min(targetFraction, 0.5) : targetFraction
        return max(0, Int64(Double(configuredLimit) * fraction))
    }

    func effectiveMaximumAge(freeBytes: Int64?) -> TimeInterval {
        guard let freeBytes, freeBytes < lowStorageReserve else { return maximumAge }
        return min(maximumAge, lowStorageMaximumAge)
    }
}

nonisolated enum CacheMaintenanceReason: String, Sendable, Equatable {
    case launch
    case appActive
    case lowStorage
    case background
    case manual
}

nonisolated struct CacheMaintenanceResult: Sendable, Equatable {
    let reason: CacheMaintenanceReason
    let scannedCount: Int
    let removedCount: Int
    let freedBytes: Int64
    let protectedCount: Int
    let finishedAt: Date
    let availableBytes: Int64?

    static func empty(_ reason: CacheMaintenanceReason, now: Date = Date()) -> Self {
        Self(reason: reason, scannedCount: 0, removedCount: 0, freedBytes: 0,
             protectedCount: 0, finishedAt: now, availableBytes: nil)
    }
}
