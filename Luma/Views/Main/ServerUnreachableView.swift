// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

#if os(iOS)
import UIKit
#endif

/// A device-wide loss of connectivity. The navigation bar and mini player belong to the tab.
struct DeviceOfflineView: View {
    private var message: String {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            return String(localized: "Your iPhone is not connected to the internet. To connect, turn off Airplane Mode or join a Wi-Fi network.",
                          bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        #endif
        return String(localized: "This device is not connected to the internet. To connect, join a Wi-Fi network.",
                      bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(String(localized: "No Internet Connection", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 325)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { PlatformColors.systemBackground.ignoresSafeArea() }
        .contentShape(Rectangle())
    }
}

/// Keeps navigation and the root scroll state mounted while covering the unavailable feed.
private struct ServerReachabilityOverlay: ViewModifier {
    @Environment(\.appContainer) private var container
    let showsDeviceOffline: Bool

    func body(content: Content) -> some View {
        let isOffline = container?.serverState.isOnline == false
        let showOffline = isOffline && showsDeviceOffline
        let serverUnreachable = !isOffline && container?.serverState.isServerReachable == false
        let blocksContent = showOffline || serverUnreachable
        content
            .allowsHitTesting(!blocksContent)
            .accessibilityHidden(blocksContent)
            .overlay {
                if showOffline {
                    DeviceOfflineView()
                } else if serverUnreachable {
                    ServerUnreachableView()
                        .background(PlatformColors.systemBackground)
                        .contentShape(Rectangle())
                }
            }
    }
}

extension View {
    func lumaServerReachability(showsDeviceOffline: Bool = true) -> some View {
        modifier(ServerReachabilityOverlay(showsDeviceOffline: showsDeviceOffline))
    }
}

/// An active connection exists, but the configured music server could not be reached.
struct ServerUnreachableView: View {
    @Environment(\.appContainer) private var container
    @State private var isRetrying = false

    private var serverName: String? {
        guard let name = container?.serverState.activeServer?.displayName, !name.isEmpty else { return nil }
        return name
    }

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    var body: some View {
        VStack(spacing: LumaSpacing.l) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(.largeTitle, design: .default).weight(.light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: LumaSpacing.s) {
                Text(localized("Cannot Reach Server"))
                    .font(.lumaSectionTitle)
                    .multilineTextAlignment(.center)

                Text(localized("Luma can't reach your music server. Check your network connection and that the server is running."))
                    .font(.lumaBody)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)

                if let serverName {
                    Text(serverName)
                        .font(.lumaCaption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Button {
                retry()
            } label: {
                HStack(spacing: LumaSpacing.s) {
                    if isRetrying {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(localized("Try Again"))
                        .font(.lumaCellTitle)
                }
                .padding(.horizontal, LumaSpacing.xl)
                .padding(.vertical, LumaSpacing.m)
            }
            .lumaAccentGlassButton(disabled: isRetrying)
            .disabled(isRetrying)

            Text(localized("Your downloads are still available in Library › Downloads."))
                .font(.lumaCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(LumaSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        Task {
            // A successful ping clears `ServerState.isServerReachable`, which swaps this view out —
            // the short sleep only keeps the spinner from flashing for a single frame.
            await container?.serverReachabilityMonitor.checkNow()
            try? await Task.sleep(for: .milliseconds(350))
            isRetrying = false
        }
    }
}
