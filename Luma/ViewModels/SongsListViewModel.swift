// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import SwiftSonic

/// One alphabetically grouped block of the Library → Songs list (header letter + its songs).
nonisolated struct SongAlphabetSection: Identifiable, Sendable {
    let letter: String
    let songs: [DisplayableSong]
    /// Index of this section's first song within the flattened section order (for playback).
    let startIndex: Int
    var id: String { letter }
    /// A shared section snapshot keeps rendered rows and playback indices in the same locale order.
    static func grouped(_ songs: [DisplayableSong], sort: SongSort, locale: Locale) -> [Self] {
        guard sort.groupsAlphabetically else { return [] }
        let grouped = Dictionary(grouping: songs) { song -> String in
            let value = sort.groupingKey(for: song).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = value.first, first.isLetter else { return "#" }
            return String(first).uppercased()
        }
        let letters = grouped.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive, .numeric],
                locale: locale) == .orderedAscending
        }
        var offset = 0
        return letters.map { letter in
            let sectionSongs = grouped[letter] ?? []
            defer { offset += sectionSongs.count }
            return Self(letter: letter, songs: sectionSongs, startIndex: offset)
        }
    }

}

/// Drives the Library → Songs screen: pages the whole server library, and can swap that source for the
/// starred songs or the tracks downloaded on this device (`SongListFilter`). Sorting / A–Z grouping
/// (`SongSort`) is applied client-side to whichever source is active.
@Observable
@MainActor
final class SongsListViewModel {
    /// Alphabetically grouped sections driving the list headers + jump bar. Empty for "Date Added".
    private(set) var sections: [SongAlphabetSection] = []
    /// Flat, display-ordered list used for playback.
    private(set) var allSongs: [DisplayableSong] = []
    /// Active source (All Songs / Favorites / Downloads).
    private(set) var filter: SongListFilter = .allSongs
    /// Active ordering, mirrored from the caller's persisted preference.
    private(set) var sort: SongSort = .title
    var isLoading = false
    var isLoadingMore = false
    /// True while a Favorites/Downloads source is being swapped in after a filter change.
    var isLoadingFilterSource = false
    var error: UserFacingError?
    /// Only meaningful for `SongListFilter.allSongs` — the other sources are fetched whole.
    var hasMore = true

    /// `true` when the active sort groups into lettered sections (drives the alphabet jump bar).
    var usesAlphabetSections: Bool { sort.groupsAlphabetically }

    private let libraryService: any LibraryServiceProtocol
    /// Needed for the Downloads filter — the local `DownloadedTrack` store is the source of truth.
    private let modelContainer: ModelContainer?
    /// Supplies the active server id for the local downloads lookup.
    private let serverState: ServerState?
    private let downloadService: (any DownloadServiceProtocol)?

    private let pageSize = 500
    private var requestGeneration: UInt64 = 0
    private var offset = 0
    private var libraryHasMore = true
    /// Songs of the active filter before sorting (library pages, starred songs, or local downloads).
    private var source: [DisplayableSong] = []
    /// `Song.created` (library/starred) or `DownloadedTrack.downloadedAt` (downloads), keyed by song id.
    private var addedDates: [String: Date] = [:]
    private var rawSongs: [Song] = []
    private var localTracks: [DownloadedTrack] = []
    private var cachedSongs: [DisplayableSong] = []
    private var cachedDates: [String: Date] = [:]
    private var downloadedSongIds: Set<String> = []

    init(
        libraryService: any LibraryServiceProtocol,
        modelContainer: ModelContainer? = nil,
        serverState: ServerState? = nil,
        downloadService: (any DownloadServiceProtocol)? = nil
    ) {
        self.libraryService = libraryService
        self.modelContainer = modelContainer
        self.serverState = serverState
        self.downloadService = downloadService
    }

    // MARK: - Loading

    /// Reloads the active source from its origin (page 0 for the library, a fresh fetch otherwise).
    func load() async {
        guard !isLoading else { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        let requestedFilter = filter
        let requestedServer = serverState?.activeServer?.id
        isLoading = true
        defer { if generation == requestGeneration { isLoading = false } }
        error = nil
        await refreshLocalTracks()
        guard isCurrent(generation, filter: requestedFilter, server: requestedServer) else { return }

        switch filter {
        case .allSongs:
            offset = 0
            do {
                let page = try await libraryService.librarySongs(offset: 0, count: pageSize)
                guard isCurrent(generation, filter: requestedFilter, server: requestedServer) else { return }
                rawSongs = page
                offset = page.count
                libraryHasMore = page.count == pageSize
                addedDates = Self.addedDates(from: page)
                source = page.map { DisplayableSong(from: $0) }
            } catch {
                guard isCurrent(generation, filter: requestedFilter, server: requestedServer) else { return }
                self.error = UserFacingError.from(error)
            }
        case .favorites:
            await reloadStarredSongs(generation: generation, server: requestedServer)
        case .downloads:
            applyLocalTrackSource()
        }

        guard isCurrent(generation, filter: requestedFilter, server: requestedServer) else { return }
        hasMore = filter == .allSongs && libraryHasMore
        rebuild()
    }

    func loadMoreIfNeeded() async {
        guard filter == .allSongs, !isLoading, !isLoadingMore, libraryHasMore else { return }
        let generation = requestGeneration
        let requestedServer = serverState?.activeServer?.id
        isLoadingMore = true
        defer { if generation == requestGeneration { isLoadingMore = false } }
        do {
            let page = try await libraryService.librarySongs(offset: offset, count: pageSize)
            guard isCurrent(generation, filter: .allSongs, server: requestedServer) else { return }
            if page.isEmpty {
                libraryHasMore = false
            } else {
                var seen = Set(rawSongs.map(\.id))
                for song in page where !seen.contains(song.id) {
                    rawSongs.append(song)
                    seen.insert(song.id)
                }
                offset += page.count
                addedDates.merge(Self.addedDates(from: page)) { _, new in new }
                source = rawSongs.map { DisplayableSong(from: $0) }
                libraryHasMore = page.count == pageSize
                rebuild()
            }
        } catch {
            // Pagination failures are non-fatal; pull-to-refresh retries from the top.
        }
        guard isCurrent(generation, filter: .allSongs, server: requestedServer) else { return }
        hasMore = libraryHasMore
    }

    // MARK: - Source & ordering

    /// Swaps the list's source. Favorites/Downloads are fetched whole (they are not paginated), so the
    /// alphabet jump bar and the Play/Shuffle header always act on the complete selection.
    func setFilter(_ newFilter: SongListFilter) async {
        guard newFilter != filter else { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        let requestedServer = serverState?.activeServer?.id
        filter = newFilter
        isLoading = false
        isLoadingMore = false
        isLoadingFilterSource = false
        error = nil

        switch newFilter {
        case .allSongs:
            // Library pages are already cached — reuse them unless the first load never happened.
            guard !rawSongs.isEmpty else {
                await load()
                return
            }
            addedDates = Self.addedDates(from: rawSongs)
            source = rawSongs.map { DisplayableSong(from: $0) }
            hasMore = libraryHasMore
            rebuild()
        case .favorites:
            isLoadingFilterSource = true
            await reloadStarredSongs(generation: generation, server: requestedServer)
            guard isCurrent(generation, filter: newFilter, server: requestedServer) else { return }
            hasMore = false
            rebuild()
            isLoadingFilterSource = false
        case .downloads:
            isLoadingFilterSource = true
            await refreshLocalTracks()
            guard isCurrent(generation, filter: newFilter, server: requestedServer) else { return }
            applyLocalTrackSource()
            hasMore = false
            rebuild()
            isLoadingFilterSource = false
        }
    }

    /// Re-orders the current source. Synchronous — nothing is refetched.
    func setSort(_ newSort: SongSort) {
        guard newSort != sort else { return }
        sort = newSort
        rebuild()
    }

    private func isCurrent(_ generation: UInt64, filter expected: SongListFilter, server: UUID?) -> Bool {
        !Task.isCancelled && generation == requestGeneration && filter == expected && serverState?.activeServer?.id == server
    }

    private func reloadStarredSongs(generation: UInt64, server: UUID?) async {
        do {
            let songs = try await libraryService.getStarred2().song ?? []
            guard isCurrent(generation, filter: .favorites, server: server) else { return }
            addedDates = Self.addedDates(from: songs)
            source = songs.map { DisplayableSong(from: $0) }
        } catch {
            guard isCurrent(generation, filter: .favorites, server: server) else { return }
            self.error = UserFacingError.from(error)
            addedDates = [:]
            source = []
        }
    }

    /// The Downloads source: local tracks carry a `downloadedAt` timestamp that stands in for "date added".
    private func applyLocalTrackSource() {
        addedDates = Dictionary(localTracks.map { ($0.songId, $0.downloadedAt) }, uniquingKeysWith: { first, _ in first })
        addedDates.merge(cachedDates) { first, _ in first }
        let downloaded = localTracks.map { DisplayableSong(from: $0) }
        let downloadedIDs = Set(downloaded.map(\.id))
        // Cached tracks are playable from local storage too, so they belong in
        // the Downloads source. A permanent download of the same song wins.
        source = downloaded + cachedSongs.filter { !downloadedIDs.contains($0.id) }
    }

    /// Reads the active server's downloaded and cached tracks (metadata only) so the Downloads
    /// filter and the per-row downloaded badge need no network round-trip.
    private func refreshLocalTracks() async {
        guard let modelContainer, let serverId = serverState?.activeServer?.id else {
            localTracks = []
            cachedSongs = []
            cachedDates = [:]
            downloadedSongIds = []
            return
        }
        let usable = await downloadService?.downloadedSongIds(serverId: serverId)
        guard serverState?.activeServer?.id == serverId, !Task.isCancelled else { return }
        let context = ModelContext(modelContainer)
        let sid = serverId
        let descriptor = FetchDescriptor<DownloadedTrack>(predicate: #Predicate<DownloadedTrack> { $0.serverId == sid })
        localTracks = ((try? context.fetch(descriptor)) ?? []).filter { track in
            guard let usable else { return true }
            return usable.contains(track.songId) || track.currentRemoteID.map(usable.contains) == true
                || !usable.isDisjoint(with: track.legacyRemoteIDs ?? [])
        }
        downloadedSongIds = usable ?? Set(localTracks.map(\.songId))

        let cachedDescriptor = FetchDescriptor<CachedTrack>(
            predicate: #Predicate<CachedTrack> { $0.serverId == sid }
        )
        let cached = (try? context.fetch(cachedDescriptor)) ?? []
        var downloadedIDs = downloadedSongIds
        downloadedIDs.formUnion(localTracks.map(\.songId))
        cachedSongs = cached
            .filter { !downloadedIDs.contains($0.songId) }
            .map { DisplayableSong(from: $0) }
        cachedDates = Dictionary(
            cached.map { ($0.songId, $0.lastAccessedAt ?? $0.cachedAt) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Grouping

    private func rebuild() {
        let ordered = orderedSongs()

        guard sort.groupsAlphabetically else {
            sections = []
            allSongs = ordered
            return
        }

        sections = SongAlphabetSection.grouped(ordered, sort: sort, locale: AppUILanguage.locale)
        allSongs = sections.flatMap(\.songs)
    }

    /// Applies the active sort to the source songs. The alphabetical sorts also order the array, so
    /// `rebuild()` only has to partition it into sections; "Date Added" sorts newest-first (songs the
    /// server never dated land last) and stays a single flat list.
    private func orderedSongs() -> [DisplayableSong] {
        let songs = source.map { downloadedSongIds.contains($0.id) ? $0.withDownloaded(true) : $0 }
        switch sort {
        case .title:
            return songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            return songs.sorted { lhs, rhs in
                let left = sort.groupingKey(for: lhs)
                let right = sort.groupingKey(for: rhs)
                let byArtist = left.localizedStandardCompare(right)
                guard byArtist == .orderedSame else { return byArtist == .orderedAscending }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        case .dateAdded:
            return songs.sorted { (addedDates[$0.id] ?? .distantPast) > (addedDates[$1.id] ?? .distantPast) }
        }
    }

    /// `Song.created` is optional — servers that omit it simply sort last under "Date Added".
    private static func addedDates(from songs: [Song]) -> [String: Date] {
        var result: [String: Date] = [:]
        for song in songs {
            if let created = song.created { result[song.id] = created }
        }
        return result
    }
}
