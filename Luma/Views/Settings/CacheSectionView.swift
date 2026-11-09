// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Combine
import OSLog
import SwiftUI

struct CacheSectionView: View {
    @Environment(\.appContainer) private var container
    @State private var usedBytes: Int64 = 0
    @State private var trackCount: Int = 0
    @State private var isClearing: Bool = false
    @State private var isMaintaining = false
    @State private var lastCleanupDate: Date?

    private var cacheSettings: CacheSettings? { container?.cacheSettings }

    var body: some View {
        let maxBytes = cacheSettings?.maxCacheBytes ?? Int64(2 * 1_024 * 1_024 * 1_024)

        return Section {
            LabeledContent {
                Text(usageDescription(maxBytes: maxBytes))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } label: {
                Label {
                    Text("Used")
                } icon: {
                    SettingsIcon(systemImage: "externaldrive.fill", color: .green)
                }
            }

            if let cacheSettings {
                Picker(selection: Binding(
                    get: { cacheSettings.maxCacheMegabytes },
                    set: { cacheSettings.maxCacheMegabytes = $0 }
                )) {
                    ForEach(CacheSettings.storageOptionsMB, id: \.self) { megabytes in
                        Text(capacityLabel(megabytes)).tag(megabytes)
                    }
                } label: {
                    HStack {
                        Label {
                            Text("Storage Limit")
                        } icon: {
                            SettingsIcon(systemImage: "tray.full.fill", color: Color.lumaAccent)
                        }
                        Spacer()
                        Text(capacityLabel(cacheSettings.maxCacheMegabytes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .font(.body.weight(.medium))
                    }
                }
                .pickerStyle(.menu)
            }

            if let cacheSettings {
                Picker(selection: Binding<CacheFormat>(
                    get: { cacheSettings.cacheFormat },
                    set: { newValue in cacheSettings.cacheFormat = newValue }
                )) {
                    ForEach(CacheFormat.selectableCases) { format in
                        Text(format.title).tag(format)
                    }
                } label: {
                    Label {
                        Text("Format")
                    } icon: {
                        SettingsIcon(systemImage: "waveform", color: LumaColors.accent)
                    }
                }
                .pickerStyle(.menu)
            }

            if let cacheSettings {
                Toggle(isOn: Binding(
                    get: { cacheSettings.cacheOverCellular },
                    set: { cacheSettings.cacheOverCellular = $0 }
                )) {
                    Label {
                        Text("Use cellular data")
                    } icon: {
                        SettingsIcon(systemImage: "antenna.radiowaves.left.and.right", color: .blue)
                    }
                }

                Toggle(isOn: Binding(
                    get: { cacheSettings.autoCleanupEnabled },
                    set: { cacheSettings.autoCleanupEnabled = $0 }
                )) {
                    Label {
                        Text("Clean up old streaming cache")
                    } icon: {
                        SettingsIcon(systemImage: "clock.arrow.circlepath", color: .orange)
                    }
                }

                LabeledContent {
                    Text(lastCleanupLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } label: {
                    Label {
                        Text("Last cleanup")
                    } icon: {
                        SettingsIcon(systemImage: "checkmark.circle", color: .green)
                    }
                }
            }

            Button {
                Task { await cleanUpNow() }
            } label: {
                if isMaintaining {
                    HStack(spacing: LumaSpacing.s) {
                        ProgressView().scaleEffect(0.8)
                        Text("Cleaning…")
                    }
                } else {
                    SettingsRowLabel(title: "Clean up now", systemImage: "sparkles", color: .orange)
                }
            }
            .disabled(isMaintaining || (usedBytes == 0 && trackCount == 0))

            Button(role: .destructive) {
                Task { await clearCache() }
            } label: {
                if isClearing {
                    HStack(spacing: LumaSpacing.s) {
                        ProgressView().scaleEffect(0.8)
                        Text("Clearing…")
                    }
                } else {
                    SettingsRowLabel(title: "Clear automatic music storage", systemImage: "trash.fill", color: .red)
                }
            }
            .disabled(isClearing || (usedBytes == 0 && trackCount == 0))

        } header: {
            SettingsSectionHeader("Automatic music storage")
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "Automatic storage reuses recently played music while Automatic Downloads is on. The oldest unprotected tracks are removed when this limit is reached. Saved music shares the same storage and is protected from automatic cleanup. Smart cleanup only removes old, re-downloadable streaming files and never removes offline downloads or the current playback buffer.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                ContextualGuideNote(
                    guide: .streamingCache,
                    message: String(localized: "The cache can be cleared at any time. Offline downloads and playlists are kept separately.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                )
            }
        }
        .task {
            await refreshUsage()
            lastCleanupDate = await container?.cacheService.lastMaintenanceDate
        }
        .onChange(of: cacheSettings?.maxCacheMegabytes) { _, newValue in
            guard let newValue else { return }
            Task {
                await container?.cacheService.setMaxBytes(Int64(newValue) * 1_024 * 1_024)
                await refreshUsage()
            }
        }
    }

    private func usageDescription(maxBytes: Int64) -> String {
        let bytesString = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
        let limit = ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)
        return "\(bytesString) / \(limit)"
    }

    private func capacityLabel(_ megabytes: Int) -> String {
        if megabytes < 1_024 {
            return "\(megabytes) MB"
        }
        return "\(megabytes / 1_024) GB"
    }

    private func refreshUsage() async {
        guard let container else { return }
        let bytes = await container.cacheService.reclaimableBytes
        let count = await container.cacheService.trackCount
        usedBytes = bytes
        trackCount = count
    }

    private var lastCleanupLabel: String {
        guard let date = lastCleanupDate else {
            return String(localized: "Never", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func cleanUpNow() async {
        guard let container else { return }
        isMaintaining = true
        defer { isMaintaining = false }
        let result = await container.cacheService.performMaintenance(
            policy: .manual,
            reason: .manual
        )
        lastCleanupDate = result.finishedAt
        let size = ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file)
        await refreshUsage()
        if result.removedCount > 0 {
            container.toastService.showConfirmation(
                String(localized: "Cleaned up \(size) of streaming cache.",
                       bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            )
        }
    }

    private func clearCache() async {
        guard let container else { return }
        isClearing = true
        defer { isClearing = false }
        await container.cacheService.clearAudioTracksOnly()
        await refreshUsage()
    }
}
