// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import OSLog

/// Records and manages local playback events for Wrapped statistics.
///
/// Pure actor — no MainActor, no singleton, no network access.
/// Injected via AppContainer. All persistence uses a private ModelContext;
/// PlaybackEvent PersistentModel instances never leave this actor.
actor StatsService {
    private let modelContainer: ModelContainer
    private let preparation: Task<Void, Never>?

    private let replay: ReplayHistorySync?
    private let account: @MainActor @Sendable () -> ServerSnapshot?
    private let songs: @MainActor @Sendable (UUID) -> [String: DisplayableSong]

    init(modelContainer: ModelContainer, preparation: Task<Void, Never>? = nil, replay: ReplayHistorySync? = nil,
         account: @escaping @MainActor @Sendable () -> ServerSnapshot? = { nil },
         songs: @escaping @MainActor @Sendable (UUID) -> [String: DisplayableSong] = { _ in [:] }) {
        self.replay = replay
        self.account = account
        self.songs = songs
        self.modelContainer = modelContainer
        self.preparation = preparation
    }

    @concurrent static func backupLocalHistory(container: ModelContainer, serverID: String, to url: URL) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        guard fm.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { if fm.fileExists(atPath: temporary.path) { try? fm.removeItem(at: temporary) } }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        let encoder = JSONEncoder()
        let descriptor = FetchDescriptor<PlaybackEvent>(predicate: #Predicate { $0.serverId == serverID })
        try ModelContext(container).enumerate(descriptor, batchSize: 256) { e in
            try Task.checkCancellation()
            let dto = PlaybackEventDTO(id: e.id, trackId: e.trackId, trackTitle: e.trackTitle, albumId: e.albumId,
                albumTitle: e.albumTitle, artistId: e.artistId, artistName: e.artistName, genre: e.genre,
                timestamp: e.timestamp, durationListened: e.durationListened, trackDuration: e.trackDuration,
                wasCompleted: e.wasCompleted, serverId: e.serverId)
            var line = try encoder.encode(dto)
            line.append(10)
            try output.write(contentsOf: line)
        }
        try output.synchronize()
        try fm.moveItem(at: temporary, to: url)
    }

    // MARK: - Public API

    func recordPlayback(_ event: PlaybackEventDTO, trigger: String = "") async {
        await preparation?.value
        let context = ModelContext(modelContainer)
        let model = PlaybackEvent(
            id: event.id,
            trackId: event.trackId,
            trackTitle: event.trackTitle,
            albumId: event.albumId,
            albumTitle: event.albumTitle,
            artistId: event.artistId,
            artistName: event.artistName,
            genre: event.genre,
            timestamp: event.timestamp,
            durationListened: event.durationListened,
            trackDuration: event.trackDuration,
            wasCompleted: event.wasCompleted,
            serverId: event.serverId
        )
        context.insert(model)
        do {
            try context.save()
            let artistIdForLog = event.artistId ?? "nil"
            let durationForLog = String(format: "%.1f", event.durationListened)
            Logger.stats.debug(
                "[INSERT] trigger=\(trigger, privacy: .public) trackId=\(event.trackId, privacy: .public) artistId=\(artistIdForLog, privacy: .public) durationListened=\(durationForLog, privacy: .public)s startedAt=\(event.timestamp, privacy: .public) completed=\(event.wasCompleted, privacy: .public) serverId=\(event.serverId, privacy: .public)"
            )
        } catch {
            Logger.stats.error("Failed to save playback event: \(error, privacy: .public)")
        }
    }

    func eventCount(forServer serverId: String) async -> Int {
        await preparation?.value
        let active = await account()
        let sid = replay == nil ? serverId : (active?.id.uuidString == serverId ? active?.localReplayID ?? "" : "")
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<PlaybackEvent>(
            predicate: #Predicate { $0.serverId == sid }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Most recent playback events (≥30s listens, as recorded), newest first.
    /// Returns Sendable DTOs — PlaybackEvent instances never leave this actor.
    func recentEvents(limit: Int, serverId: String) async -> [PlaybackEventDTO] {
        await preparation?.value
        let active = await account()
        let sid = replay == nil ? serverId : (active?.id.uuidString == serverId ? active?.localReplayID ?? "" : "")
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<PlaybackEvent>(
            predicate: #Predicate { $0.serverId == sid },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let events = (try? context.fetch(descriptor)) ?? []
        return events.map { event in
            PlaybackEventDTO(
                id: event.id,
                trackId: event.trackId,
                trackTitle: event.trackTitle,
                albumId: event.albumId,
                albumTitle: event.albumTitle,
                artistId: event.artistId,
                artistName: event.artistName,
                genre: event.genre,
                timestamp: event.timestamp,
                durationListened: event.durationListened,
                trackDuration: event.trackDuration,
                wasCompleted: event.wasCompleted,
                serverId: event.serverId
            )
        }
    }

    /// Local, album-level listening candidates for the Playlists “listen again” shelf.
    /// Reads only the app's listening store; it never contacts the server and never
    /// fabricates an album when no event exists.
    func albumListenAgainCandidates(serverId: String, limit: Int = 3,
                                    now: Date = Date()) async -> [AlbumListenAgainRecommendation] {
        await preparation?.value
        let active = await account()
        let sid = replay == nil ? serverId : (active?.id.uuidString == serverId ? active?.localReplayID ?? "" : "")
        let cutoff = now.addingTimeInterval(-Double(AlbumListenAgainPolicy.lookbackDays) * 86_400)
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<PlaybackEvent>(
            predicate: #Predicate { $0.serverId == sid && $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        // Bound the local read; this is a recommendation shelf, not a history export.
        descriptor.fetchLimit = 1_200
        let events = (try? context.fetch(descriptor)) ?? []

        struct Aggregate {
            var albumTitle: String
            var artistName: String
            var lastPlayed: Date
            var playCount = 0
            var tracks = Set<String>()
            var completed = 0
            var seconds: TimeInterval = 0
            var completionSum = 0.0
        }
        var aggregates: [String: Aggregate] = [:]
        for event in events {
            guard let albumId = event.albumId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !albumId.isEmpty,
                  let title = event.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            let completion: Double
            if event.trackDuration > 0 {
                completion = min(1, max(0, event.durationListened / event.trackDuration))
            } else {
                completion = event.wasCompleted ? 1 : 0
            }
            var aggregate = aggregates[albumId] ?? Aggregate(
                albumTitle: title,
                artistName: event.artistName,
                lastPlayed: event.timestamp
            )
            aggregate.albumTitle = title
            aggregate.artistName = event.artistName
            aggregate.lastPlayed = max(aggregate.lastPlayed, event.timestamp)
            aggregate.playCount += 1
            if !event.trackId.isEmpty { aggregate.tracks.insert(event.trackId) }
            if event.wasCompleted { aggregate.completed += 1 }
            aggregate.seconds += max(0, event.durationListened)
            aggregate.completionSum += completion
            aggregates[albumId] = aggregate
        }

        let recommendations = aggregates.compactMap { albumId, aggregate -> AlbumListenAgainRecommendation? in
            let averageCompletion = aggregate.playCount > 0 ? aggregate.completionSum / Double(aggregate.playCount) : 0
            guard AlbumListenAgainPolicy.qualifies(
                distinctTracks: aggregate.tracks.count,
                completedTracks: aggregate.completed,
                totalListenedSeconds: aggregate.seconds,
                averageCompletion: averageCompletion
            ) else { return nil }
            return AlbumListenAgainRecommendation(
                albumId: albumId,
                albumTitle: aggregate.albumTitle,
                artistName: aggregate.artistName,
                lastPlayed: aggregate.lastPlayed,
                playCount: aggregate.playCount,
                distinctTrackCount: aggregate.tracks.count,
                completedTrackCount: aggregate.completed,
                totalListenedSeconds: aggregate.seconds
            )
        }
        return AlbumListenAgainPolicy.ranked(recommendations, limit: limit)
    }

    /// Home has exactly one leading “Listen Again” card. The caller uses this method so
    /// no surface can accidentally render a second album recommendation.
    func albumListenAgainRecommendation(serverId: String, now: Date = Date()) async -> AlbumListenAgainRecommendation? {
        await albumListenAgainCandidates(serverId: serverId, limit: 1, now: now).first
    }

    func deleteAllEvents(forServer serverId: String) async {
        await preparation?.value
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<PlaybackEvent>(
            predicate: #Predicate { $0.serverId == serverId }
        )
        do {
            let events = try context.fetch(descriptor)
            guard !events.isEmpty else { return }
            for event in events {
                context.delete(event)
            }
            try context.save()
            Logger.stats.info("Deleted \(events.count) event(s) for serverId=\(serverId, privacy: .public)")
        } catch {
            Logger.stats.error("Failed to delete events for serverId=\(serverId, privacy: .public): \(error, privacy: .public)")
        }
    }

    // MARK: - Phase 2: Wrapped aggregation

    private func reportingCalendar(for profile: ServerSnapshot?, period: WrappedPeriod, local: Calendar) async -> Calendar {
        guard let profile, let mirror = try? await replay?.mirror(account: profile) else { return local }
        let utc = WrappedPeriod.serverCalendar
        let range = period.dateRange(in: utc)
        guard (try? ReplayHistoryStore(url: mirror.url).hasEvents(uid: mirror.uid, start: range.start, end: range.end)) == true else { return local }
        return utc
    }

    func firstHistoryDate(for profile: ServerSnapshot) async -> Date? {
        await preparation?.value
        let sid = profile.localReplayID
        let context = ModelContext(modelContainer)
        var query = FetchDescriptor<PlaybackEvent>(predicate: #Predicate { $0.serverId == sid }, sortBy: [SortDescriptor(\.timestamp)])
        query.fetchLimit = 1
        let firstLocal = try? context.fetch(query).first?.timestamp
        guard let mirror = try? await replay?.mirror(account: profile),
              let firstServer = try? ReplayHistoryStore(url: mirror.url).firstDate(uid: mirror.uid) else { return firstLocal }
        return min(firstLocal ?? firstServer, firstServer)
    }

    func hasEventsInPeriod(_ period: WrappedPeriod, serverId: String, calendar: Calendar) async -> Bool {
        let active = await account()
        let profile = active?.id.uuidString == serverId ? active : nil
        let calendar = await reportingCalendar(for: profile, period: period, local: calendar)
        let range = period.dateRange(in: calendar)
        let start = range.start
        let end = range.end
        let sid = replay == nil ? serverId : (profile?.localReplayID ?? "")
        await preparation?.value
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<PlaybackEvent>(
            predicate: #Predicate { $0.serverId == sid && $0.timestamp >= start && $0.timestamp < end }
        )
        if let profile, let mirror = try? await replay?.mirror(account: profile),
           let db = try? ReplayHistoryStore(url: mirror.url), (try? db.hasEvents(uid: mirror.uid, start: start, end: end)) == true { return true }
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    func wrappedData(for period: WrappedPeriod, serverId: String, calendar: Calendar) async -> WrappedData {
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        #endif

        let active = await account()
        let profile = active?.id.uuidString == serverId ? active : nil
        let calendar = await reportingCalendar(for: profile, period: period, local: calendar)
        let range = period.dateRange(in: calendar)
        let start = range.start
        let end = range.end
        let sid = replay == nil ? serverId : (profile?.localReplayID ?? "")
        await preparation?.value
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<PlaybackEvent>(
            predicate: #Predicate { $0.serverId == sid && $0.timestamp >= start && $0.timestamp < end }
        )

        let events: [PlaybackEvent]
        do {
            events = try context.fetch(descriptor)
        } catch {
            Logger.stats.error("wrappedData fetch failed for serverId=\(sid, privacy: .public): \(error, privacy: .public)")
            events = []
        }

        if let data = await serverSummary(period: period, account: profile, local: events, calendar: calendar, limit: 10) { return data }
        let data = aggregate(events: events, period: period, serverId: serverId, periodRange: range, calendar: calendar)

        #if DEBUG
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        Logger.stats.debug(
            "wrappedData: \(events.count, privacy: .public) events aggregated in \(String(format: "%.1f", elapsed * 1000), privacy: .public)ms period=\(period.displayName, privacy: .public)"
        )
        #endif

        return data
    }

    func topTracks(forPeriod period: WrappedPeriod, serverId: String, limit: Int, calendar: Calendar) async -> [TopTrackEntry] {
        let active = await account()
        let profile = active?.id.uuidString == serverId ? active : nil
        let calendar = await reportingCalendar(for: profile, period: period, local: calendar)
        let range = period.dateRange(in: calendar)
        let start = range.start
        let end = range.end
        let sid = replay == nil ? serverId : (profile?.localReplayID ?? "")
        await preparation?.value
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<PlaybackEvent>(
            predicate: #Predicate { $0.serverId == sid && $0.timestamp >= start && $0.timestamp < end }
        )
        let events: [PlaybackEvent]
        do {
            events = try context.fetch(descriptor)
        } catch {
            Logger.stats.error("topTracks fetch failed for serverId=\(sid, privacy: .public): \(error, privacy: .public)")
            return []
        }
        if let data = await serverSummary(period: period, account: profile, local: events, calendar: calendar, limit: limit) { return data.topTracks }
        guard !events.isEmpty else { return [] }
        var groups: [String: (duration: TimeInterval, count: Int, title: String, artist: String, album: String?)] = [:]
        for e in events {
            let d = effectiveDuration(for: e)
            if var g = groups[e.trackId] {
                g.duration += d
                g.count += 1
                groups[e.trackId] = g
            } else {
                groups[e.trackId] = (d, 1, e.trackTitle, e.artistName, e.albumTitle)
            }
        }
        let sorted = groups.sorted {
            if $0.value.duration != $1.value.duration { return $0.value.duration > $1.value.duration }
            return $0.key < $1.key
        }
        return sorted.prefix(limit).enumerated().map { idx, pair in
            TopTrackEntry(
                rank: idx + 1,
                trackId: pair.key,
                title: pair.value.title,
                artistName: pair.value.artist,
                albumTitle: pair.value.album,
                totalSecondsListened: pair.value.duration,
                playCount: pair.value.count
            )
        }
    }

    // MARK: - Private aggregation

    private func serverSummary(period: WrappedPeriod, account: ServerSnapshot?, local: [PlaybackEvent], calendar: Calendar, limit: Int) async -> WrappedData? {
        guard let account, let mirror = try? await replay?.mirror(account: account) else { return nil }
        let catalogue = await songs(account.id)
        let range = period.dateRange(in: calendar)
        var counts: [String: Int] = [:]
        var days: [Date: Int] = [:]
        var first: String?
        var last: String?
        var count = 0
        var matched: Set<UUID> = []
        do {
            let db = try ReplayHistoryStore(url: mirror.url)
            try db.enumerate(uid: mirror.uid, start: range.start, end: range.end) { _, track, stamp in
                counts[track, default: 0] += 1
                days[calendar.startOfDay(for: Date(timeIntervalSince1970: Double(stamp))), default: 0] += 1
                if first == nil { first = track }
                last = track
                count += 1
            }
            matched = try db.linkedSessions(uid: mirror.uid, owner: account.outboxOwner, start: range.start, end: range.end)
        } catch { return nil }
        guard count > 0 else { return nil }
        var seconds: [String: Double] = [:]
        var metadata: [String: PlaybackEvent] = [:]
        for event in local {
            seconds[event.trackId, default: 0] += effectiveDuration(for: event)
            metadata[event.trackId] = event
        }
        func entry(_ id: String, rank: Int) -> TopTrackEntry {
            TopTrackEntry(rank: rank, trackId: id, title: catalogue[id]?.title ?? metadata[id]?.trackTitle ?? id,
                artistName: catalogue[id]?.artist ?? metadata[id]?.artistName ?? "", albumTitle: catalogue[id]?.albumName ?? metadata[id]?.albumTitle,
                totalSecondsListened: seconds[id] ?? 0, playCount: counts[id] ?? 0)
        }
        struct Group {
            var title: String
            var artist: String
            var count = 0
            var tracks = 0
            var seconds = 0.0
            mutating func add(_ plays: Int, _ duration: Double) { count += plays; tracks += 1; seconds += duration }
        }
        var albums: [String: Group] = [:]
        var artists: [String: Group] = [:]
        var genres: [String: Int] = [:]
        let ordered = counts.keys.sorted { (counts[$0]! != counts[$1]!) ? counts[$0]! > counts[$1]! : $0 < $1 }
        for id in ordered {
            let track = entry(id, rank: 0)
            if let album = catalogue[id]?.albumId ?? metadata[id]?.albumId {
                albums[album, default: Group(title: track.albumTitle ?? album, artist: track.artistName)].add(track.playCount, track.totalSecondsListened)
            }
            if let artist = catalogue[id]?.artistId ?? metadata[id]?.artistId {
                artists[artist, default: Group(title: track.artistName, artist: track.artistName)].add(track.playCount, track.totalSecondsListened)
            }
            if let genre = catalogue[id]?.genre ?? metadata[id]?.genre { genres[genre, default: 0] += track.playCount }
        }
        func ranked(_ groups: [String: Group]) -> [(key: String, value: Group)] {
            groups.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        }
        var day = calendar.startOfDay(for: min(Date(), range.end.addingTimeInterval(-1)))
        var streak = 0
        while days[day] != nil, let previous = calendar.date(byAdding: .day, value: -1, to: day) { streak += 1; day = previous }
        return WrappedData(period: period, serverId: account.id.uuidString, generatedAt: Date(),
            totalSecondsListened: seconds.values.reduce(0,+), totalTracksPlayed: count, totalUniqueTracks: counts.count,
            totalUniqueArtists: artists.count, totalUniqueAlbums: albums.count,
            topTracks: ordered.prefix(limit).enumerated().map { entry($1, rank: $0 + 1) },
            topAlbums: ranked(albums).prefix(10).enumerated().map { i, g in
                TopAlbumEntry(rank: i+1, albumId: g.key, title: g.value.title, artistName: g.value.artist,
                    totalSecondsListened: g.value.seconds, playCount: g.value.count, uniqueTracks: g.value.tracks)
            },
            topArtists: ranked(artists).prefix(10).enumerated().map { i, g in
                TopArtistEntry(rank: i+1, artistId: g.key, name: g.value.title, totalSecondsListened: g.value.seconds,
                    playCount: g.value.count, uniqueTracks: g.value.tracks)
            }, dominantGenre: genres.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key,
            streakDays: streak, firstTrackOfPeriod: first.map { entry($0, rank: 0) }, lastTrackOfPeriod: last.map { entry($0, rank: 0) },
            serverSyncedAt: mirror.lastSync, dailyPlays: days, unlinkedLocalListens: local.filter { !matched.contains($0.id) }.count)
    }

    private func aggregate(
        events: [PlaybackEvent],
        period: WrappedPeriod,
        serverId: String,
        periodRange: (start: Date, end: Date),
        calendar: Calendar
    ) -> WrappedData {
        guard !events.isEmpty else {
            return WrappedData(
                period: period, serverId: serverId, generatedAt: Date(),
                totalSecondsListened: 0, totalTracksPlayed: 0,
                totalUniqueTracks: 0, totalUniqueArtists: 0, totalUniqueAlbums: 0,
                topTracks: [], topAlbums: [], topArtists: [],
                dominantGenre: nil, streakDays: 0,
                firstTrackOfPeriod: nil, lastTrackOfPeriod: nil
            )
        }

        let totalSecondsListened = events.reduce(0.0) { $0 + effectiveDuration(for: $1) }
        let totalUniqueTracks = Set(events.map(\.trackId)).count
        let totalUniqueArtists = Set(events.compactMap(\.artistId)).count
        let totalUniqueAlbums = Set(events.compactMap(\.albumId)).count

        let topTracks = buildTopTracks(from: events)
        let topAlbums = buildTopAlbums(from: events)
        let topArtists = buildTopArtists(from: events)
        let dominantGenre = buildDominantGenre(from: events)
        let streak = buildStreak(from: events, periodRange: periodRange, calendar: calendar)
        let (first, last) = buildFirstLast(from: events)

        return WrappedData(
            period: period,
            serverId: serverId,
            generatedAt: Date(),
            totalSecondsListened: totalSecondsListened,
            totalTracksPlayed: events.count,
            totalUniqueTracks: totalUniqueTracks,
            totalUniqueArtists: totalUniqueArtists,
            totalUniqueAlbums: totalUniqueAlbums,
            topTracks: topTracks,
            topAlbums: topAlbums,
            topArtists: topArtists,
            dominantGenre: dominantGenre,
            streakDays: streak,
            firstTrackOfPeriod: first,
            lastTrackOfPeriod: last
        )
    }

    private func buildTopTracks(from events: [PlaybackEvent]) -> [TopTrackEntry] {
        var groups: [String: (duration: TimeInterval, count: Int, title: String, artist: String, album: String?)] = [:]
        for e in events {
            let d = effectiveDuration(for: e)
            if var g = groups[e.trackId] {
                g.duration += d
                g.count += 1
                groups[e.trackId] = g
            } else {
                groups[e.trackId] = (d, 1, e.trackTitle, e.artistName, e.albumTitle)
            }
        }
        // Primary: playCount — reflects actual listening intent; loop time is tiebreaker.
        let sorted = groups.sorted {
            if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
            if $0.value.duration != $1.value.duration { return $0.value.duration > $1.value.duration }
            return $0.key < $1.key
        }
        return sorted.prefix(10).enumerated().map { idx, pair in
            TopTrackEntry(
                rank: idx + 1,
                trackId: pair.key,
                title: pair.value.title,
                artistName: pair.value.artist,
                albumTitle: pair.value.album,
                totalSecondsListened: pair.value.duration,
                playCount: pair.value.count
            )
        }
    }

    private func buildTopAlbums(from events: [PlaybackEvent]) -> [TopAlbumEntry] {
        var groups: [String: (duration: TimeInterval, count: Int, tracks: Set<String>, title: String, artist: String)] = [:]
        for e in events {
            guard let albumId = e.albumId else { continue }
            let d = effectiveDuration(for: e)
            if var g = groups[albumId] {
                g.duration += d
                g.count += 1
                g.tracks.insert(e.trackId)
                groups[albumId] = g
            } else {
                groups[albumId] = (d, 1, [e.trackId], e.albumTitle ?? "", e.artistName)
            }
        }
        // Primary: playCount; tiebreaker: totalSecondsListened.
        let sorted = groups.sorted {
            if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
            if $0.value.duration != $1.value.duration { return $0.value.duration > $1.value.duration }
            return $0.key < $1.key
        }
        return sorted.prefix(10).enumerated().map { idx, pair in
            TopAlbumEntry(
                rank: idx + 1,
                albumId: pair.key,
                title: pair.value.title,
                artistName: pair.value.artist,
                totalSecondsListened: pair.value.duration,
                playCount: pair.value.count,
                uniqueTracks: pair.value.tracks.count
            )
        }
    }

    private func buildTopArtists(from events: [PlaybackEvent]) -> [TopArtistEntry] {
        var groups: [String: (duration: TimeInterval, count: Int, tracks: Set<String>, name: String)] = [:]
        for e in events {
            guard let artistId = e.artistId else { continue }
            let d = effectiveDuration(for: e)
            if var g = groups[artistId] {
                g.duration += d
                g.count += 1
                g.tracks.insert(e.trackId)
                groups[artistId] = g
            } else {
                groups[artistId] = (d, 1, [e.trackId], e.artistName)
            }
        }
        // Primary: totalSecondsListened; tiebreaker: playCount.
        let sorted = groups.sorted {
            if $0.value.duration != $1.value.duration { return $0.value.duration > $1.value.duration }
            if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
            return $0.key < $1.key
        }
        return sorted.prefix(10).enumerated().map { idx, pair in
            TopArtistEntry(
                rank: idx + 1,
                artistId: pair.key,
                name: pair.value.name,
                totalSecondsListened: pair.value.duration,
                playCount: pair.value.count,
                uniqueTracks: pair.value.tracks.count
            )
        }
    }

    private func buildDominantGenre(from events: [PlaybackEvent]) -> String? {
        var durations: [String: TimeInterval] = [:]
        for e in events {
            guard let genre = e.genre else { continue }
            durations[genre, default: 0] += effectiveDuration(for: e)
        }
        guard !durations.isEmpty else { return nil }
        return durations.max {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.key > $1.key
        }?.key
    }

    private func buildStreak(
        from events: [PlaybackEvent],
        periodRange: (start: Date, end: Date),
        calendar: Calendar
    ) -> Int {
        let eventDays = Set(events.map { calendar.startOfDay(for: $0.timestamp) })
        let today = calendar.startOfDay(for: Date())
        let referenceDay: Date
        if today >= periodRange.start && today < periodRange.end {
            referenceDay = today
        } else {
            // Period is in the past: use last day of period
            let lastInstant = calendar.date(byAdding: .second, value: -1, to: periodRange.end)!
            referenceDay = calendar.startOfDay(for: lastInstant)
        }
        guard eventDays.contains(referenceDay) else { return 0 }
        var streak = 0
        var day = referenceDay
        while eventDays.contains(day) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    /// Caps a single event's contribution at its track duration.
    /// Prevents wall-clock inflation (paused time counted as listened time) from
    /// distorting Wrapped totals for existing data. Falls back to a 600 s ceiling
    /// when trackDuration was not recorded (value of 0).
    private func effectiveDuration(for event: PlaybackEvent) -> TimeInterval {
        guard event.trackDuration > 0 else {
            return min(event.durationListened, 600)
        }
        return min(event.durationListened, event.trackDuration)
    }

    private func buildFirstLast(from events: [PlaybackEvent]) -> (first: TopTrackEntry?, last: TopTrackEntry?) {
        guard !events.isEmpty,
              let earliest = events.min(by: { $0.timestamp < $1.timestamp }),
              let latest = events.max(by: { $0.timestamp < $1.timestamp })
        else { return (nil, nil) }
        let first = TopTrackEntry(
            rank: 0, trackId: earliest.trackId, title: earliest.trackTitle,
            artistName: earliest.artistName, albumTitle: earliest.albumTitle,
            totalSecondsListened: effectiveDuration(for: earliest), playCount: 1
        )
        let last = TopTrackEntry(
            rank: 0, trackId: latest.trackId, title: latest.trackTitle,
            artistName: latest.artistName, albumTitle: latest.albumTitle,
            totalSecondsListened: effectiveDuration(for: latest), playCount: 1
        )
        return (first, last)
    }
}
