// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Low-priority entry point for automatic cache maintenance. It deliberately
/// does not own a timer: app activation and the existing background window are
/// the only scheduling opportunities, so playback never pays for a wakeup.
@MainActor
final class StreamingCacheMaintenance {
    nonisolated static let minimumInterval: TimeInterval = 6 * 60 * 60

    private let cacheService: any CacheServiceProtocol
    private let playerState: PlayerState
    private let settings: CacheSettings
    private var isRunning = false

    init(cacheService: any CacheServiceProtocol, playerState: PlayerState, settings: CacheSettings) {
        self.cacheService = cacheService
        self.playerState = playerState
        self.settings = settings
    }

    /// Starts a low-priority pass only when due. The caller never waits for disk
    /// work; a final playback-intent check happens after the initial yield.
    func scheduleIfNeeded(force: Bool = false) {
        guard force || settings.autoCleanupEnabled, !isRunning else { return }
        Task(priority: .utility) { [weak self] in
            _ = await self?.runIfNeeded(force: force)
        }
    }

    @discardableResult
    func runIfNeeded(force: Bool = false) async -> CacheMaintenanceResult? {
        guard force || settings.autoCleanupEnabled else { return nil }
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        guard !playerState.playbackState.hasPlaybackIntent else { return nil }
        if !force {
            guard ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue,
                  !ProcessInfo.processInfo.isLowPowerModeEnabled else { return nil }
            let free = await cacheService.availableStorageBytes
            let lowStorage = free.map { $0 < CacheMaintenancePolicy.automatic.lowStorageReserve } ?? false
            if !lowStorage {
                if let last = await cacheService.lastMaintenanceDate,
                   Date().timeIntervalSince(last) < Self.minimumInterval { return nil }
            }
            // Let the first playback / UI work settle before touching disk.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !playerState.playbackState.hasPlaybackIntent else { return nil }
        }

        let reason: CacheMaintenanceReason
        if force {
            reason = .manual
        } else if let free = await cacheService.availableStorageBytes,
                  free < CacheMaintenancePolicy.automatic.lowStorageReserve {
            reason = .lowStorage
        } else {
            reason = .appActive
        }
        return await cacheService.performMaintenance(
            policy: force ? .manual : .automatic,
            reason: reason
        )
    }
}
