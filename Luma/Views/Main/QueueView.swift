// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData
import OSLog
import UniformTypeIdentifiers

struct QueueView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.lumaPlayingAccent) private var playingAccent
    #if os(macOS)
    @State private var draggedQueueIndex: Int?
    @State private var dropTargetGap: Int?
    #endif

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("Queue")
                    .font(.headline)
                Spacer()
                Button {
                    Task {
                        guard let state = container?.playerState else { return }
                        await container?.playerService.setAutoExtendEnabled(!state.isAutoExtendEnabled)
                    }
                } label: {
                    Image(systemName: "infinity")
                        .foregroundStyle(container?.playerState.isAutoExtendEnabled == true ? playingAccent : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Auto-extend with Smart Shuffle")
                .accessibilityValue(container?.playerState.isAutoExtendEnabled == true ? "Enabled" : "Disabled")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            queueContent
        }
        #else
        // iOS no longer presents QueueView as a sheet — the queue is inline in FullPlayerView via
        // InlineQueueList. QueueView() is only instantiated on macOS now; this branch exists to compile.
        queueContent
        #endif
    }

    @ViewBuilder
    private var queueContent: some View {
        if let playerState = container?.playerState, !playerState.queue.isEmpty {
            queueList(playerState)
        } else {
            EmptyStateView(
                systemImage: "list.bullet",
                title: "Queue is empty",
                subtitle: "Start playing music to see your queue here."
            )
        }
    }

    @ViewBuilder
    private func queueList(_ playerState: PlayerState) -> some View {
        let queue = playerState.queue
        let currentIndex = playerState.currentIndex
        let snapshot = QueueListSnapshot(tracks: queue, currentIndex: currentIndex)
        let upNext = Array(queue.dropFirst(currentIndex + 1))

        List {
            #if !os(macOS)
            Section {
                queueControlsHeader(playerState)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            #endif

            if let current = playerState.currentTrack {
                Section("Now Playing") {
                    QueueRow(song: current, isCurrent: true, onPlay: {
                        playQueueEntry(at: currentIndex, snapshot: snapshot, container: container)
                    })
                }
            }

            if !upNext.isEmpty {
                Section("Up Next") {
                    ForEach(Array(upNext.enumerated()), id: \.offset) { offset, song in
                        let absoluteIndex = currentIndex + 1 + offset
                        QueueRow(song: song, isCurrent: false, onPlay: {
                            playQueueEntry(at: absoluteIndex, snapshot: snapshot, container: container)
                        })
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playQueueEntry(at: absoluteIndex, snapshot: snapshot, container: container)
                            }
                            #if os(macOS)
                            // macOS reorders by drag-and-drop; show a between-rows insertion line at the
                            // drop gap (top of the target row, or bottom of the last row for an end drop)
                            // instead of a row highlight.
                            .overlay(alignment: .top) {
                                if dropTargetGap == absoluteIndex { queueInsertionLine }
                            }
                            .overlay(alignment: .bottom) {
                                if offset == upNext.count - 1 && dropTargetGap == absoluteIndex + 1 { queueInsertionLine }
                            }
                            .onDrag {
                                // Encode the row's absolute queue position; the delegate resolves the move
                                // positionally (never by song id) so duplicate tracks reorder correctly.
                                draggedQueueIndex = absoluteIndex
                                return NSItemProvider(object: "\(absoluteIndex)" as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: QueueReorderDropDelegate(
                                targetIndex: absoluteIndex,
                                draggedIndex: $draggedQueueIndex,
                                dropTargetGap: $dropTargetGap,
                                move: { from, toOffset in
                                    Task { await container?.playerService.moveInQueue(fromIndex: from, toIndex: toOffset) }
                                }
                            ))
                            #endif
                    }
                    #if !os(macOS)
                    .onMove { source, destination in
                        // iOS uses native List reorder — offset-based, so duplicate-safe by construction.
                        // `destination` is the Array.move toOffset that moveInQueue already replicates.
                        guard let relativeSource = source.first else { return }
                        let absoluteSource = currentIndex + 1 + relativeSource
                        let absoluteDestination = currentIndex + 1 + destination
                        HapticFeedback.light.trigger()
                        Task { await container?.playerService.moveInQueue(fromIndex: absoluteSource, toIndex: absoluteDestination) }
                    }
                    #endif
                    .onDelete { indices in
                        let absoluteIndices = indices.sorted(by: >).map { currentIndex + 1 + $0 }
                        HapticFeedback.light.trigger()
                        Task {
                            for absoluteIndex in absoluteIndices {
                                await container?.playerService.removeFromQueue(at: absoluteIndex)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        #if !os(macOS)
        // iOS List reorder only engages in edit mode (per the PlaylistDetailView precedent). Keep it
        // always-on so Up Next is reorderable via the system grips without an explicit Edit toggle.
        .environment(\.editMode, .constant(.active))
        #endif
    }

    #if os(macOS)
    /// Thin accent line drawn between rows at the current drop gap (macOS drag-reorder feedback).
    private var queueInsertionLine: some View {
        Rectangle()
            .fill(playingAccent)
            .frame(height: 2)
            .padding(.horizontal, LumaSpacing.l)
    }
    #endif

    @ViewBuilder
    private func queueControlsHeader(_ playerState: PlayerState) -> some View {
        HStack(spacing: LumaSpacing.xxxxl) {
            Button {
                HapticFeedback.light.trigger()
                Task { await container?.playerService.toggleShuffle() }
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(playerState.isShuffled ? playingAccent : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playerState.isShuffled ? "Shuffle On" : "Shuffle Off")

            Button {
                HapticFeedback.light.trigger()
                Task { await container?.playerService.setRepeatMode(playerState.repeatMode.next) }
            } label: {
                Image(systemName: playerState.repeatMode.systemImage)
                    .font(.title3)
                    .foregroundStyle(playerState.repeatMode != .off ? playingAccent : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Repeat: \(playerState.repeatMode == .one ? "One" : playerState.repeatMode == .off ? "Off" : "All")")

            Button {
                HapticFeedback.light.trigger()
                Task { await container?.playerService.setAutoExtendEnabled(!playerState.isAutoExtendEnabled) }
            } label: {
                Image(systemName: "infinity")
                    .font(.title3)
                    .foregroundStyle(playerState.isAutoExtendEnabled ? playingAccent : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Auto-extend with Smart Shuffle")
            .accessibilityValue(playerState.isAutoExtendEnabled ? "Enabled" : "Disabled")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LumaSpacing.m)
    }
}

struct QueueRow: View {
    let song: DisplayableSong
    let isCurrent: Bool
    let onRemove: (() -> Void)?
    let onPlay: () -> Void
    // Default to the system label colors (macOS popover, which has its own background); the inline iOS
    // queue passes the full player's luminance-adaptive content colors so text reads over the cover blur.
    var contentColor: Color = .primary
    var secondaryContentColor: Color = .secondary
    var loadArtwork: Bool = true
    var compactPhoneLayout: Bool = false

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @Environment(\.lumaPlayingAccent) private var playingAccent
    @ScaledMetric(relativeTo: .body) private var compactArtworkSide: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var compactTitleSize: CGFloat = 18
    @ScaledMetric(relativeTo: .subheadline) private var compactArtistSize: CGFloat = 15
    @State private var showAddToPlaylist = false
    @Query private var favoriteMatches: [FavoriteRecord]

    init(song: DisplayableSong, isCurrent: Bool, onRemove: (() -> Void)? = nil,
         contentColor: Color = .primary, secondaryContentColor: Color = .secondary, loadArtwork: Bool = true, compactPhoneLayout: Bool = false, onPlay: @escaping () -> Void) {
        self.song = song
        self.isCurrent = isCurrent
        self.onRemove = onRemove
        self.onPlay = onPlay
        self.contentColor = contentColor
        self.secondaryContentColor = secondaryContentColor
        self.loadArtwork = loadArtwork
        self.compactPhoneLayout = compactPhoneLayout
        let itemId = song.id
        let type = FavoriteType.song.rawValue
        _favoriteMatches = Query(filter: #Predicate<FavoriteRecord> {
            $0.itemId == itemId && $0.itemType == type
        })
    }

    private var isOnline: Bool { container?.serverState.isOnline == true }
    private var isPlaying: Bool { container?.playerState.playbackState == .playing }
    private var isFavorite: Bool {
        guard let serverId = container?.serverState.activeServer?.id else { return false }
        return favoriteMatches.contains { $0.serverId == serverId }
    }

    var body: some View {
        HStack(spacing: LumaSpacing.m) {
            CoverArtView(id: song.effectiveCoverArtId, size: compactPhoneLayout ? 96 : 104, loadingEnabled: loadArtwork)
                .frame(width: compactPhoneLayout ? compactArtworkSide : 52, height: compactPhoneLayout ? compactArtworkSide : 52)
                .lumaCoverStyle(cornerRadius: LumaCornerRadius.xs)

            VStack(alignment: .leading, spacing: compactPhoneLayout ? 2 : LumaSpacing.xs) {
                Text(song.title)
                    #if os(iOS)
                    .font(.system(size: compactPhoneLayout ? compactTitleSize : 18, weight: .regular))
                    #else
                    .font(compactPhoneLayout ? .system(size: compactTitleSize, weight: .regular) : .lumaCellTitle)
                    #endif
                    .foregroundStyle(contentColor)
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        #if os(iOS)
                        .font(.system(size: compactPhoneLayout ? compactArtistSize : 15, weight: .regular))
                        #else
                        .font(compactPhoneLayout ? .system(size: compactArtistSize, weight: .regular) : .lumaCaption)
                        #endif
                        .foregroundStyle(secondaryContentColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isCurrent {
                NowPlayingBarsIndicator(isPlaying: isPlaying,
                        isBuffering: container?.playerState.playbackState == .buffering)
            } else {
                #if os(macOS)
                // macOS has no edit-mode grip, so keep the visual reorder hint here; on iOS the system
                // renders its own reorder grip in edit mode, so a second one would be redundant.
                ReorderIndicator()
                #endif
            }
        }
        .padding(.vertical, compactPhoneLayout ? 0 : LumaSpacing.xs)
        .contextMenu {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
            }

            Button {
                Task { await container?.playerService.playNext(song) }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                Task { await container?.playerService.addToQueue(song) }
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }

            Divider()

            Button {
                showAddToPlaylist = true
            } label: {
                Label("Add to Playlist...", systemImage: "music.note.list")
            }
            .disabled(!isOnline)

            Divider()

            Button {
                let fav = isFavorite
                Task {
                    guard let container else { return }
                    do {
                        if fav {
                            try await container.favoritesService.unstar(itemType: .song, itemId: song.id)
                        } else {
                            try await container.favoritesService.star(itemType: .song, itemId: song.id)
                        }
                    } catch {
                        container.toastService.showError(error.localizedDescription)
                    }
                }
            } label: {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.slash" : "heart"
                )
            }
            .disabled(container?.serverState.activeServer == nil)

            if let onRemove {
                Divider()
                Button(role: .destructive, action: onRemove) {
                    Label("Remove from Queue", systemImage: "minus.circle")
                }
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(song: song)
                .environment(artworkImageCache)
        }
    }
}

/// A rendered row owns its song and position even while the live queue changes.
nonisolated struct QueueListSnapshot {
    struct Entry: Identifiable, Sendable {
        let id: Int
        let song: DisplayableSong
    }

    let tracks: [DisplayableSong]
    let currentIndex: Int
    let intentionalEnd: Int
    private let entries: [Entry]

    init(tracks: [DisplayableSong], currentIndex: Int, intentionalEnd: Int? = nil) {
        self.tracks = tracks
        self.currentIndex = min(max(0, currentIndex), tracks.count)
        self.intentionalEnd = min(max(0, intentionalEnd ?? tracks.count), tracks.count)
        entries = tracks.enumerated().map { Entry(id: $0.offset, song: $0.element) }
    }

    var history: ArraySlice<Entry> { entries[..<currentIndex] }
    var continuing: ArraySlice<Entry> { entries[min(currentIndex + 1, intentionalEnd)..<intentionalEnd] }
    var autoplay: ArraySlice<Entry> { entries[intentionalEnd...] }

    func selection(at index: Int, currentQueue: [DisplayableSong]) -> (tracks: [DisplayableSong], index: Int)? {
        guard tracks == currentQueue, tracks.indices.contains(index) else { return nil }
        return (tracks, index)
    }
}

@MainActor
private func playQueueEntry(at index: Int, snapshot: QueueListSnapshot, container: AppContainer?) {
    guard let container else { return }
    HapticFeedback.medium.trigger()
    Task {
        guard let selection = snapshot.selection(at: index, currentQueue: container.playerState.queue) else { return }
        do {
            try await container.playerService.play(tracks: selection.tracks, startIndex: selection.index)
        } catch {
            Logger.player.error("[PLAYBACK] queue selection failed: \(error, privacy: .public)")
        }
    }
}

/// The iOS queue list: History (scroll up) · Continue Playing · Autoplay.
/// Native `List` + `.onMove` — offset-based / duplicate-safe. Removal via row context menu.
struct InlineQueueList: View {
    let playerState: PlayerState
    var contentColor: Color = .primary
    var secondaryContentColor: Color = .secondary
    /// Defer row artwork loads until the queue is actually visible (it is mounted at opacity 0 for the
    /// morph). The List stays mounted with stable identity — only the per-row artwork task is gated.
    var loadArtwork: Bool = true
    var compactPhoneLayout: Bool = false
    @Environment(\.appContainer) private var container

    /// Only name a source when the intentional queue is actually one album.
    /// Mixed queues and autoplay must not inherit the current song's album label.
    private func continuationAlbum(in snapshot: QueueListSnapshot) -> String? {
        guard let current = playerState.currentTrack, let album = current.albumName, !album.isEmpty else { return nil }
        let intentional = snapshot.tracks.prefix(snapshot.intentionalEnd)
        guard !intentional.isEmpty, intentional.allSatisfy({ song in
            if let albumID = current.albumId { return song.albumId == albumID }
            return song.albumName == album && song.artist == current.artist
        }) else { return nil }
        return album
    }

    private var sectionFont: Font {
        compactPhoneLayout ? .system(size: 18, weight: .semibold) : .lumaSectionTitle
    }
    private var rowInsets: EdgeInsets? {
        compactPhoneLayout ? EdgeInsets(top: 6, leading: 32, bottom: 7, trailing: 32) : nil
    }

    var body: some View {
        let snapshot = QueueListSnapshot(tracks: playerState.queue, currentIndex: playerState.currentIndex,
                                         intentionalEnd: playerState.originalQueueEndIndex)
        let historyEmpty = snapshot.history.isEmpty
        let continueEmpty = snapshot.continuing.isEmpty
        let autoplayEmpty = snapshot.autoplay.isEmpty
        let showAutoplaySection = playerState.isAutoExtendEnabled && playerState.repeatMode == .off
        let showContinueSection = !continueEmpty || !showAutoplaySection || autoplayEmpty
        let firstSectionID = showContinueSection ? "continuePlayingHeader" : "autoplayHeader"

        if historyEmpty, continueEmpty, autoplayEmpty, !showAutoplaySection {
            EmptyStateView(
                systemImage: "list.bullet",
                title: String(localized: "Nothing up next", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                subtitle: String(localized: "Tracks you add to the queue appear here.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List {
                    if !historyEmpty {
                        Section {
                            ForEach(Array(snapshot.history)) { entry in
                                queueTapRow(entry: entry, snapshot: snapshot, reorderable: false)
                            }
                        } header: {
                            HStack {
                                Text(String(localized: "History", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                    .font(sectionFont)
                                    .foregroundStyle(contentColor)
                                    .textCase(nil)
                                Spacer(minLength: 0)
                                Button(String(localized: "Clear", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                                    HapticFeedback.light.trigger()
                                    Task { await container?.playerService.clearQueueHistory() }
                                }
                                .font(.lumaCaption.weight(.semibold))
                                .foregroundStyle(secondaryContentColor)
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listSectionSeparator(.hidden)
                    }

                    // Avoid a native empty-section filler between Continue Playing and Autoplay.
                    if showContinueSection {
                        Section {
                            if continueEmpty {
                                if playerState.repeatMode == .one {
                                    Text(String(localized: "Repeating this song", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                        .font(.lumaCaption)
                                        .foregroundStyle(secondaryContentColor)
                                        .listRowBackground(Color.clear)
                                } else {
                                    Text(String(localized: "Nothing up next", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                        .font(.lumaCaption)
                                        .foregroundStyle(secondaryContentColor)
                                        .listRowBackground(Color.clear)
                                }
                            } else {
                                ForEach(Array(snapshot.continuing)) { entry in
                                    queueTapRow(entry: entry, snapshot: snapshot, reorderable: true)
                                }
                                .onMove { source, destination in
                                    guard let relativeSource = source.first else { return }
                                    let absoluteSource = snapshot.continuing.startIndex + relativeSource
                                    let absoluteDestination = snapshot.continuing.startIndex + destination
                                    HapticFeedback.light.trigger()
                                    Task {
                                        guard container?.playerState.queue == snapshot.tracks else { return }
                                        await container?.playerService.moveInQueue(
                                            fromIndex: absoluteSource,
                                            toIndex: absoluteDestination
                                        )
                                    }
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Continue Playing", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                    .font(sectionFont)
                                    .foregroundStyle(contentColor)
                                    .textCase(nil)
                                if compactPhoneLayout, let album = continuationAlbum(in: snapshot) {
                                    Text(String(localized: "Provided by: \(album)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundStyle(secondaryContentColor.opacity(0.78))
                                        .lineLimit(1)
                                        .textCase(nil)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .listRowInsets(EdgeInsets(top: 8, leading: compactPhoneLayout ? 32 : 16, bottom: 12, trailing: compactPhoneLayout ? 32 : 16))
                            .id("continuePlayingHeader")
                        } footer: {
                            VStack(alignment: .leading, spacing: 6) {
                                repeatFooter
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listSectionSeparator(.hidden)
                    }

                    if showAutoplaySection {
                        Section {
                            if autoplayEmpty {
                                Text(String(localized: "Finding similar music…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                    .font(.lumaCaption)
                                    .foregroundStyle(secondaryContentColor)
                                    .listRowBackground(Color.clear)
                            } else {
                                ForEach(Array(snapshot.autoplay)) { entry in
                                    queueTapRow(entry: entry, snapshot: snapshot, reorderable: true)
                                }
                                .onMove { source, destination in
                                    guard let relativeSource = source.first else { return }
                                    let absoluteSource = snapshot.autoplay.startIndex + relativeSource
                                    let absoluteDestination = snapshot.autoplay.startIndex + destination
                                    HapticFeedback.light.trigger()
                                    Task {
                                        guard container?.playerState.queue == snapshot.tracks else { return }
                                        await container?.playerService.moveInQueue(
                                            fromIndex: absoluteSource,
                                            toIndex: absoluteDestination
                                        )
                                    }
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(String(localized: "Autoplay", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "infinity")
                                    .font(sectionFont)
                                    .foregroundStyle(contentColor)
                                    .labelStyle(.titleAndIcon)
                                    .textCase(nil)
                                Text(String(localized: "Similar music keeps playing.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                    .font(.lumaCaption)
                                    .foregroundStyle(secondaryContentColor)
                                    .textCase(nil)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("autoplayHeader")
                        }
                        .listRowBackground(Color.clear)
                        .listSectionSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                #if !os(macOS)
                .listRowSpacing(0)
                #endif
                .environment(\.defaultMinListRowHeight, compactPhoneLayout ? 61 : 44)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .lumaHideScrollEdgeEffects()
                .lumaContentEdgeFade(top: 24, bottom: 40)
                #if !os(macOS)
                .environment(\.editMode, .constant(.active))
                #endif
                .onAppear {
                    // Land on Continue Playing so History sits above (scroll up to reveal).
                    DispatchQueue.main.async {
                        proxy.scrollTo(firstSectionID, anchor: .top)
                    }
                }
                .onChange(of: snapshot.currentIndex) { _, _ in
                    withAnimation(LumaAnimation.surface) {
                        proxy.scrollTo(firstSectionID, anchor: .top)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var repeatFooter: some View {
        switch playerState.repeatMode {
        case .all:
            Label(
                String(localized: "Repeating \(playerState.queue.count) songs", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                systemImage: "repeat"
            )
            .font(.lumaCaption)
            .foregroundStyle(secondaryContentColor)
        case .one:
            Label(
                String(localized: "Repeating one", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                systemImage: "repeat.1"
            )
            .font(.lumaCaption)
            .foregroundStyle(secondaryContentColor)
        case .off:
            EmptyView()
        }
    }

    @ViewBuilder
    private func queueTapRow(entry: QueueListSnapshot.Entry, snapshot: QueueListSnapshot, reorderable: Bool) -> some View {
        Button {
            playQueueEntry(at: entry.id, snapshot: snapshot, container: container)
        } label: {
            QueueRow(
                song: entry.song,
                isCurrent: false,
                onRemove: { removeFromQueue(at: entry.id, snapshot: snapshot) },
                contentColor: contentColor,
                secondaryContentColor: secondaryContentColor,
                loadArtwork: loadArtwork,
                compactPhoneLayout: compactPhoneLayout,
                onPlay: { playQueueEntry(at: entry.id, snapshot: snapshot, container: container) }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(rowInsets)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .moveDisabled(!reorderable)
    }

    private func removeFromQueue(at index: Int, snapshot: QueueListSnapshot) {
        Task {
            guard let queue = container?.playerState.queue, snapshot.selection(at: index, currentQueue: queue) != nil else { return }
            HapticFeedback.light.trigger()
            await container?.playerService.removeFromQueue(at: index)
        }
    }
}

/// Positional drag-reorder drop delegate for the queue, shared by both queue surfaces.
///
/// Follows edit-pinned's `.onDrag`/`.onDrop` structure, with two deliberate differences:
/// - It resolves the move by **absolute queue position** (`targetIndex` + the bound grab index), not
///   edit-pinned's `firstIndex(by id)` — the queue can hold the same song twice, so an id lookup would
///   move the wrong copy; positions are unique.
/// - It commits a **single** move in `performDrop`, not per-`dropEntered`. `PlayerService` is an actor
///   and `moveInQueue` is an order-sensitive incremental mutation, so firing one unstructured `Task`
///   per hover would let commits interleave and scramble the queue; one move on drop is race-free.
///
/// `move(from:toOffset:)` receives the grabbed row's absolute index and the SwiftUI `Array.move`
/// `toOffset` for the target slot (the convention `PlayerService.moveInQueue` expects).
struct QueueReorderDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggedIndex: Int?
    @Binding var dropTargetGap: Int?
    let move: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let from = draggedIndex else { return }
        // Track the insertion gap (== the Array.move toOffset the drop will use) so the view can draw
        // the line where the item will land. This does NOT commit — the move is applied once, on drop.
        dropTargetGap = targetIndex > from ? targetIndex + 1 : targetIndex
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggedIndex = nil; dropTargetGap = nil }
        guard let from = draggedIndex, from != targetIndex else { return true }
        // Land the dragged row exactly at targetIndex; moveInQueue applies dest = from < to ? to-1 : to.
        let toOffset = targetIndex > from ? targetIndex + 1 : targetIndex
        move(from, toOffset)
        return true
    }
}
