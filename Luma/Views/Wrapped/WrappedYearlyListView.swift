// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct WrappedYearlyListView: View {
    @Environment(\.appContainer) private var container
    @State private var playlists: [WrappedYearlyPlaylist] = []
    @State private var isLoading = true

    private var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    private var hasCurrentYearPlaylist: Bool {
        playlists.contains { $0.year == currentYear }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LumaSpacing.l) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, LumaSpacing.xxxxl)
                } else if playlists.isEmpty && hasCurrentYearPlaylist {
                    emptyState
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: LumaSpacing.s)],
                        spacing: LumaSpacing.s
                    ) {
                        if !hasCurrentYearPlaylist {
                            WrappedRecapMonthCard(period: .year(currentYear))
                        }
                        ForEach(playlists) { playlist in
                            WrappedYearlyCard(playlist: playlist)
                        }
                    }

                    NavigationLink(value: HomeDestination.replay) {
                        HStack(spacing: LumaSpacing.s) {
                            Image(systemName: "chart.bar.fill")
                                .font(.title2)
                                .foregroundStyle(Color.lumaAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("View Listening Stats")
                                    .font(.lumaCellTitle)
                                    .foregroundStyle(.primary)
                                Text("Monthly and annual breakdowns")
                                    .font(.lumaCaption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(LumaSpacing.m)
                        .background(Color.lumaAccent.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: LumaCornerRadius.standard, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(LumaSpacing.l)
        }
        .lumaContentWidth()
        .miniPlayerBottomMargin()
        .navigationTitle(String(localized: "Replay", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .task {
            guard let container,
                  let serverId = container.serverState.activeServer?.id.uuidString else {
                isLoading = false
                return
            }
            playlists = await container.wrappedPlaylistService.fetchYearlyPlaylists(serverId: serverId)
            isLoading = false
        }
    }

    private var emptyState: some View {
        VStack(spacing: LumaSpacing.s) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(Color.lumaAccent.opacity(0.5))
            Text("No Replay playlists yet.")
                .font(.lumaCellTitle)
            Text("Your Replay \(currentYear) will be available on December 28.")
                .font(.lumaCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, LumaSpacing.xxxxl)
    }
}
