// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

struct WrappedView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ReplayHistorySync.enabledKey) private var replayEnabled = true
    @State private var firstYear: Int?
    @State private var mirrorRevision: String?
    @State private var syncStatus = ""
    @State private var selectedPeriod: WrappedPeriod = .currentMonth()
    @State private var data: WrappedData?
    @State private var isLoading = true
    @State private var wrappedPlaylistId: String?
    @State private var appeared = false
    @State private var loadFailed = false
    @State private var refreshDebounceTask: Task<Void, Never>?
    #if DEBUG
    @AppStorage("debug.wrappedFakeDataActive") private var overrideWithFakeData = false
    @AppStorage("debug.wrappedFakeDataJSON") private var persistedFakeDataJSON = ""
    #endif

    init(initialPeriod: WrappedPeriod = .currentMonth()) {
        _selectedPeriod = State(initialValue: initialPeriod)
    }

    private var availablePeriods: [WrappedPeriod] {
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let displayedYear = selectedPeriod.calendarYear
        let lastMonth = displayedYear == year ? month : 12
        var periods = (1...lastMonth).map { WrappedPeriod.month(year: displayedYear, month: $0) }
        periods += stride(from: year, through: min(year, firstYear ?? year), by: -1).map { WrappedPeriod.year($0) }
        return periods
    }

    private var currentYear: Int {
        switch selectedPeriod {
        case .month(let year, _): return year
        case .year(let year): return year
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LumaSpacing.xl) {
                WrappedPeriodPicker(selectedPeriod: $selectedPeriod, availablePeriods: availablePeriods)

                HStack {
                    Text(syncStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Toggle("Navidrome Replay sync", isOn: $replayEnabled)
                        Button("Sync now") { Task { await synchronize(force: true) } }.disabled(!replayEnabled)
                        Button("Check past history") { Task { await synchronize(force: true, rescan: true) } }.disabled(!replayEnabled)
                    } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .accessibilityLabel("Replay sync options")
                }
                ContextualGuideNote(
                    guide: .replay,
                    message: String(localized: "Replay uses local listening events; Navidrome history is only used when Replay sync is enabled. A recap appears after enough plays are recorded.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                )
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, LumaSpacing.xxxxl)
                } else if loadFailed {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "Unable to Load Recap",
                        subtitle: "Something went wrong. Pull to refresh.",
                        action: .init(label: "Retry") { Task { await loadData() } }
                    )
                } else if let d = data, d.totalTracksPlayed > 0 {
                    if let date = d.serverSyncedAt {
                        Text("Plays from Navidrome · listening time measured by Luma. Last synced \(date.formatted()).")
                            .font(.caption).foregroundStyle(.secondary)
                        if let unlinked = d.unlinkedLocalListens, unlinked > 0 {
                            Text("\(unlinked) local listens without a confirmed match are preserved in local history.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    WrappedStatHero(data: d)
                        .cascadeAppear(order: 0, trigger: appeared)
                    if let daily = d.dailyPlays, !daily.isEmpty {
                        DisclosureGroup("Listening activity (UTC)") {
                            let monthly: Bool = { if case .year = d.period { return true }; return false }()
                            let calendar = WrappedPeriod.serverCalendar
                            let buckets = Dictionary(grouping: daily.keys) { date in
                                monthly ? calendar.dateInterval(of: .month, for: date)?.start ?? date : date
                            }
                            ForEach(buckets.keys.sorted(), id: \.self) { date in
                                let count = (buckets[date] ?? []).reduce(0) { $0 + (daily[$1] ?? 0) }
                                HStack {
                                    Text(date, format: Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
                                    Spacer()
                                    Text(count.plural("play", "plays"))
                                }.font(.caption)
                            }
                        }
                    }
                    WrappedTopArtistsSection(artists: d.topArtists)
                        .cascadeAppear(order: 1, trigger: appeared)
                    WrappedTopTracksSection(tracks: d.topTracks)
                        .cascadeAppear(order: 2, trigger: appeared)
                    WrappedTopAlbumsSection(albums: d.topAlbums)
                        .cascadeAppear(order: 3, trigger: appeared)
                    WrappedAwardsSection(data: d)
                        .cascadeAppear(order: 4, trigger: appeared)
                    if case .year = selectedPeriod {
                        WrappedYearCard(
                            year: currentYear,
                            firstTrack: d.firstTrackOfPeriod,
                            lastTrack: d.lastTrackOfPeriod,
                            playlistId: wrappedPlaylistId
                        )
                        .cascadeAppear(order: 5, trigger: appeared)
                    }
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, LumaSpacing.l)
            .padding(.top, LumaSpacing.l)
            .padding(.bottom, LumaSpacing.xl)
        }
        .refreshable { await synchronize(force: true) }
        .miniPlayerBottomMargin()
        .navigationTitle(String(localized: "Replay", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .task(id: "\(container?.serverState.activeServer?.localReplayID ?? "")|\(selectedPeriod)|\(replayEnabled)") {
            data = nil
            wrappedPlaylistId = nil
            isLoading = true
            await loadData()
        }
        .task(id: "\(container?.serverState.activeServer?.replayProfile ?? "")|\(scenePhase == .active)|\(replayEnabled)") {
            guard scenePhase == .active else { return }
            syncStatus = ""
            mirrorRevision = nil
            if let c = container, let account = c.serverState.activeServer {
                let date = await c.statsService.firstHistoryDate(for: account)
                guard !Task.isCancelled else { return }
                firstYear = date.map { Calendar.current.component(.year, from: $0) }
            }
            while !Task.isCancelled {
                if !ProcessInfo.processInfo.isLowPowerModeEnabled || syncStatus.isEmpty { await synchronize(force: false) }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .background {
            if let container,
               let serverId = container.serverState.activeServer?.localReplayID {
                PlaybackEventWatcher(serverId: serverId) {
                    scheduleQuietRefresh()
                }
                .modelContainer(container.listeningModelContainer)
            }
        }
        .onChange(of: container?.libraryIndexService.lastIndexedAt) { _, _ in scheduleQuietRefresh() }
        .onDisappear {
            refreshDebounceTask?.cancel()
            refreshDebounceTask = nil
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: LumaSpacing.s) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(Color.lumaAccent.opacity(0.5))
            Text(String(localized: "No listens for this period.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.lumaCellTitle)
            Text(String(localized: "Listen up — Replay will keep track of your activity.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.lumaCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, LumaSpacing.xxxxl)
    }

    // MARK: - Data loading

    /// Debounce live playback inserts so each scrobble doesn't rebuild the whole Recap UI.
    private func scheduleQuietRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await refreshData()
        }
    }

    private func synchronize(force: Bool, rescan: Bool = false) async {
        guard let container, let account = container.serverState.activeServer else { return }
        let status = await container.replayHistory.sync(force: force, rescan: rescan)
        guard !Task.isCancelled, account == container.serverState.activeServer else { return }
        syncStatus = status
        let revision = try? await container.replayHistory.revision(for: account)
        if !force && mirrorRevision == revision && data != nil { return }
        let earliest = await container.statsService.firstHistoryDate(for: account)
        guard !Task.isCancelled, account == container.serverState.activeServer else { return }
        firstYear = earliest.map { Calendar.current.component(.year, from: $0) }
        mirrorRevision = revision
        await refreshData()
    }

    private func refreshData() async {
        #if DEBUG
        guard !overrideWithFakeData else { return }
        #endif
        guard let container, let serverId = container.serverState.activeServer?.id.uuidString else { return }
        let profile = container.serverState.activeServer?.localReplayID
        let result = await container.statsService.wrappedData(for: selectedPeriod, serverId: serverId, calendar: .current)
        guard !Task.isCancelled, container.serverState.activeServer?.localReplayID == profile, result.period == selectedPeriod else { return }
        data = result
    }

    private func loadData() async {
        #if DEBUG
        if overrideWithFakeData {
            guard isLoading,
                  !persistedFakeDataJSON.isEmpty,
                  let jsonData = persistedFakeDataJSON.data(using: .utf8),
                  let restored = try? JSONDecoder().decode(WrappedData.self, from: jsonData) else { return }
            selectedPeriod = restored.period
            data = restored
            isLoading = false
            loadFailed = false
            if case .year = restored.period { wrappedPlaylistId = "debug-playlist" }
            appeared = true
            return
        }
        #endif
        loadFailed = false
        guard let container, let serverId = container.serverState.activeServer?.id.uuidString else {
            isLoading = false
            loadFailed = true
            return
        }
        Logger.wrapped.debug("[WRAPPED-VIEW] fetch start period=\(selectedPeriod.displayName, privacy: .public)")
        let isFirstPaint = data == nil
        appeared = false
        if isFirstPaint { isLoading = true }
        wrappedPlaylistId = nil
        let profile = container.serverState.activeServer?.localReplayID
        let result = await container.statsService.wrappedData(
            for: selectedPeriod, serverId: serverId, calendar: .current
        )
        guard !Task.isCancelled else { return }
        if case .year(let y) = selectedPeriod {
            wrappedPlaylistId = await container.wrappedPlaylistService.playlistId(year: y, serverId: serverId)
        }
        guard !Task.isCancelled, container.serverState.activeServer?.localReplayID == profile, result.period == selectedPeriod else { return }
        data = result
        isLoading = false
        appeared = true
        Logger.wrapped.debug("[WRAPPED-VIEW] fetch done totalPlays=\(result.totalTracksPlayed, privacy: .public)")
    }
}

// MARK: - Cascade appear modifier

private extension View {
    func cascadeAppear(order: Int, trigger: Bool) -> some View {
        modifier(CascadeAppearModifier(order: order, trigger: trigger))
    }
}

private struct CascadeAppearModifier: ViewModifier {
    let order: Int
    let trigger: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(trigger ? 1 : 0)
            .offset(y: (reduceMotion || trigger) ? 0 : 16)
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.45, dampingFraction: 0.82).delay(Double(order) * 0.07),
                value: trigger
            )
    }
}

// MARK: - Server-scoped playback event watcher

private struct PlaybackEventWatcher: View {
    let onCountChange: () -> Void
    @Query private var events: [PlaybackEvent]

    init(serverId: String, onCountChange: @escaping () -> Void) {
        self.onCountChange = onCountChange
        let sid = serverId
        _events = Query(filter: #Predicate<PlaybackEvent> { $0.serverId == sid })
    }

    var body: some View {
        Color.clear
            .onChange(of: events.count) { _, _ in onCountChange() }
    }
}
