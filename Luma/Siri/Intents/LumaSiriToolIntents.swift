import AppIntents
import Foundation
import SwiftSonic

// MARK: - Playback control

@available(iOS 27.3, macOS 27.3, *)
enum LumaPlaybackCommand: String, AppEnum {
    case playPause
    case play
    case pause
    case next
    case previous
    case seekTo
    case seekForward
    case seekBackward
    case shuffleOn
    case shuffleOff
    case repeatOff
    case repeatAll
    case repeatOne
    case setVolume

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Playback Command")
    }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .playPause: DisplayRepresentation(title: "Play or Pause"),
            .play: DisplayRepresentation(title: "Play"),
            .pause: DisplayRepresentation(title: "Pause"),
            .next: DisplayRepresentation(title: "Next Track"),
            .previous: DisplayRepresentation(title: "Previous Track"),
            .seekTo: DisplayRepresentation(title: "Seek to Position"),
            .seekForward: DisplayRepresentation(title: "Skip Forward"),
            .seekBackward: DisplayRepresentation(title: "Skip Backward"),
            .shuffleOn: DisplayRepresentation(title: "Turn Shuffle On"),
            .shuffleOff: DisplayRepresentation(title: "Turn Shuffle Off"),
            .repeatOff: DisplayRepresentation(title: "Repeat Off"),
            .repeatAll: DisplayRepresentation(title: "Repeat All"),
            .repeatOne: DisplayRepresentation(title: "Repeat One"),
            .setVolume: DisplayRepresentation(title: "Set Volume")
        ]
    }
}

/// Custom Siri AI tool for transport actions that aren't covered by a primary
/// audio schema. It always drives the live `PlayerService` and never creates a
/// second playback engine.
@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct LumaPlaybackControlToolIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Control Luma Playback"
    static let description = IntentDescription(
        "Pauses, resumes, skips, seeks, shuffles, repeats, or changes the volume of the music currently playing in Luma. Use this for transport controls rather than starting new music.",
        categoryName: "Playback"
    )
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Command", description: "The transport action to perform.")
    var command: LumaPlaybackCommand

    @Parameter(title: "Seconds", description: "Seek position, or seconds to skip. Used by seek commands.")
    var seconds: Double?

    @Parameter(title: "Volume", description: "A value from 0 to 1 for the set volume command.")
    var volume: Double?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        guard let player = await SiriBridge.playbackProvider?() else {
            throw LumaAudioIntentError.playerUnavailable
        }
        let state = player.state
        guard state.currentTrack != nil || state.isLiveStream else {
            return .result(dialog: IntentDialog("Luma isn't playing anything right now."))
        }

        switch command {
        case .playPause:
            await player.togglePlayPause()
            return .result(dialog: IntentDialog("Toggled playback."))
        case .play:
            await player.resume()
            return .result(dialog: IntentDialog("Resumed playback."))
        case .pause:
            await player.pause()
            return .result(dialog: IntentDialog("Paused playback."))
        case .next:
            do { try await player.skipToNext() } catch {
                throw LumaAudioIntentError.playbackFailed(underlying: error)
            }
            return .result(dialog: IntentDialog("Skipped to the next track."))
        case .previous:
            do { try await player.skipToPrevious() } catch {
                throw LumaAudioIntentError.playbackFailed(underlying: error)
            }
            return .result(dialog: IntentDialog("Went back to the previous track."))
        case .seekTo:
            guard let seconds else {
                return .result(dialog: IntentDialog("Tell me the time to seek to, for example 2 minutes 30 seconds."))
            }
            await player.seek(to: max(0, min(seconds, state.duration)))
            return .result(dialog: IntentDialog("Seeked to \(Self.time(seconds))."))
        case .seekForward:
            let delta = max(1, seconds ?? 15)
            await player.seek(to: min(state.duration, state.position + delta))
            return .result(dialog: IntentDialog("Skipped forward \(Int(delta)) seconds."))
        case .seekBackward:
            let delta = max(1, seconds ?? 15)
            await player.seek(to: max(0, state.position - delta))
            return .result(dialog: IntentDialog("Skipped back \(Int(delta)) seconds."))
        case .shuffleOn:
            if !state.isShuffled { await player.toggleShuffle() }
            return .result(dialog: IntentDialog("Shuffle is on."))
        case .shuffleOff:
            if state.isShuffled { await player.toggleShuffle() }
            return .result(dialog: IntentDialog("Shuffle is off."))
        case .repeatOff:
            await player.setRepeatMode(.off)
            return .result(dialog: IntentDialog("Repeat is off."))
        case .repeatAll:
            await player.setRepeatMode(.all)
            return .result(dialog: IntentDialog("Repeat all is on."))
        case .repeatOne:
            await player.setRepeatMode(.one)
            return .result(dialog: IntentDialog("Repeat one is on."))
        case .setVolume:
            guard let volume else {
                return .result(dialog: IntentDialog("Tell me a volume from 0 to 100 percent."))
            }
            await player.setVolume(Float(max(0, min(1, volume))))
            return .result(dialog: IntentDialog("Volume set to \(Int(max(0, min(1, volume)) * 100)) percent."))
        }
    }

    private static func time(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Library search

@available(iOS 27.3, macOS 27.3, *)
enum LumaLibrarySearchKind: String, AppEnum {
    case songs
    case albums
    case artists
    case playlists

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Library Item")
    }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .songs: DisplayRepresentation(title: "Songs"),
            .albums: DisplayRepresentation(title: "Albums"),
            .artists: DisplayRepresentation(title: "Artists"),
            .playlists: DisplayRepresentation(title: "Playlists")
        ]
    }
}

/// Custom tool that answers library questions and can start the first result.
/// Search is local-first and reuses the same `SiriCatalogService` as entity
/// resolution, so a Siri request never downloads the whole library.
@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct LumaLibrarySearchToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Luma Library"
    static let description = IntentDescription(
        "Filters the user's Luma music library by title, artist, album, playlist, genre, release year, or file format and reports matches. Optionally starts the first matching item.",
        categoryName: "Library"
    )
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Query", description: "Text to match against the library. Optional when a genre, year, or file format is provided.")
    var query: String?

    @Parameter(title: "Genre", description: "Match songs whose genre contains this value, such as Pop, Jazz, or Rock.")
    var genre: String?

    @Parameter(title: "Year", description: "Match songs released in this year, such as 1987.")
    var year: Int?

    @Parameter(title: "File Format", description: "Match a file format such as FLAC, MP3, AAC, OGG, or lossless.")
    var fileFormat: String?

    @Parameter(title: "Kind", description: "The type of library item to search.", default: .songs)
    var kind: LumaLibrarySearchKind

    @Parameter(title: "Play First Match", description: "Start the first matching item after searching.", default: false)
    var playFirst: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else {
            throw LumaAudioIntentError.serviceUnavailable
        }
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty || genre != nil || year != nil || fileFormat != nil else {
            return .result(dialog: IntentDialog("What should I search for in your Luma library?"))
        }
        let cappedLimit = 12

        let advanced = LibrarySongQuery(text: trimmed, genre: genre, year: year, audioFormat: fileFormat)
        if advanced.genre != nil || advanced.year != nil || advanced.audioFormat != nil {
            let songs = await catalog.songs(filteredBy: advanced, limit: cappedLimit)
            guard !songs.isEmpty else {
                return .result(dialog: IntentDialog("I couldn't find any songs matching those filters in your Luma library."))
            }
            if playFirst, let first = songs.first, let id = LumaEntityID(rawValue: first.id),
               let track = await catalog.playableSong(id: id),
               let player = await SiriBridge.playbackProvider?() {
                try await player.play(tracks: [track], startIndex: 0)
                return .result(dialog: IntentDialog("Playing \(first.title) by \(first.artistName)."))
            }
            let summary = songs.prefix(8).map { "\($0.title) — \($0.artistName)" }.joined(separator: "; ")
            return .result(dialog: IntentDialog(stringLiteral: "Found \(songs.count) matching songs: \(summary)"))
        }

        switch kind {
        case .songs:
            let songs = await catalog.songs(matching: trimmed, limit: cappedLimit)
            guard !songs.isEmpty else {
                return .result(dialog: IntentDialog("I couldn't find any matching songs in your Luma library."))
            }
            if playFirst, let first = songs.first, let id = LumaEntityID(rawValue: first.id),
               let track = await catalog.playableSong(id: id),
               let player = await SiriBridge.playbackProvider?() {
                try await player.play(tracks: [track], startIndex: 0)
                return .result(dialog: IntentDialog("Playing \(first.title) by \(first.artistName)."))
            }
            let summary = songs.prefix(5).map { "\($0.title) — \($0.artistName)" }.joined(separator: "; ")
            return .result(dialog: IntentDialog(stringLiteral: "Found \(songs.count) matching songs: \(summary)"))
        case .albums:
            let albums = await catalog.albums(matching: trimmed, limit: cappedLimit)
            guard !albums.isEmpty else {
                return .result(dialog: IntentDialog("I couldn't find any matching albums in your Luma library."))
            }
            if playFirst, let first = albums.first, let id = LumaEntityID(rawValue: first.id),
               let player = await SiriBridge.playbackProvider?() {
                let tracks = await catalog.playableSongs(inAlbum: id)
                if !tracks.isEmpty {
                    try await player.play(tracks: tracks, startIndex: 0)
                    return .result(dialog: IntentDialog("Playing the album \(first.title) by \(first.artistName)."))
                }
            }
            let summary = albums.prefix(5).map { "\($0.title) — \($0.artistName)" }.joined(separator: "; ")
            return .result(dialog: IntentDialog(stringLiteral: "Found \(albums.count) matching albums: \(summary)"))
        case .artists:
            let artists = await catalog.artists(matching: trimmed, limit: cappedLimit)
            guard !artists.isEmpty else {
                return .result(dialog: IntentDialog("I couldn't find any matching artists in your Luma library."))
            }
            if playFirst, let first = artists.first, let id = LumaEntityID(rawValue: first.id),
               let player = await SiriBridge.playbackProvider?() {
                let tracks = await catalog.playableSongs(byArtist: id)
                if !tracks.isEmpty {
                    try await player.play(tracks: tracks, startIndex: 0)
                    return .result(dialog: IntentDialog("Playing music by \(first.name)."))
                }
            }
            let summary = artists.prefix(5).map(\.name).joined(separator: ", ")
            return .result(dialog: IntentDialog(stringLiteral: "Found \(artists.count) matching artists: \(summary)"))
        case .playlists:
            let playlists = await catalog.playlists(matching: trimmed, limit: cappedLimit)
            guard !playlists.isEmpty else {
                return .result(dialog: IntentDialog("I couldn't find any matching playlists in your Luma library."))
            }
            if playFirst, let first = playlists.first, let id = LumaEntityID(rawValue: first.id),
               let player = await SiriBridge.playbackProvider?() {
                let tracks = await catalog.playableSongs(inPlaylist: id)
                if !tracks.isEmpty {
                    try await player.play(tracks: tracks, startIndex: 0)
                    return .result(dialog: IntentDialog("Playing the playlist \(first.title)."))
                }
            }
            let summary = playlists.prefix(5).map(\.title).joined(separator: ", ")
            return .result(dialog: IntentDialog(stringLiteral: "Found \(playlists.count) matching playlists: \(summary)"))
        }
    }
}

// MARK: - Playlist management

@available(iOS 27.3, macOS 27.3, *)
enum LumaPlaylistToolAction: String, AppEnum {
    case create
    case addCurrentSong
    case addSong
    case play
    case list
    case rename
    case delete

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Playlist Action")
    }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .create: DisplayRepresentation(title: "Create Playlist"),
            .addCurrentSong: DisplayRepresentation(title: "Add Current Song"),
            .addSong: DisplayRepresentation(title: "Add a Song"),
            .play: DisplayRepresentation(title: "Play Playlist"),
            .list: DisplayRepresentation(title: "List Playlists"),
            .rename: DisplayRepresentation(title: "Rename Playlist"),
            .delete: DisplayRepresentation(title: "Delete Playlist")
        ]
    }
}

/// Custom tool for playlist operations that are not covered by the schema's
/// `addToPlaylist` action. Server mutations happen before a success dialog.
@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct LumaPlaylistToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Manage Luma Playlists"
    static let description = IntentDescription(
        "Creates, renames, deletes, lists, plays, or adds songs to the user's Luma playlists. Destructive actions require confirmation.",
        categoryName: "Playlists"
    )
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Action", description: "The playlist operation to perform.")
    var action: LumaPlaylistToolAction

    @Parameter(title: "Playlist", description: "The playlist to modify or play.")
    var playlist: LumaPlaylistEntity?

    @Parameter(title: "Song", description: "A song to add. If omitted, the current song is used.")
    var song: LumaSongEntity?

    @Parameter(title: "Name", description: "A playlist name for create or rename.")
    var name: String?

    @Parameter(title: "Confirmed", description: "Must be true to delete a playlist.", default: false)
    var confirmed: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        guard let playlists = await SiriBridge.playlistProvider?() else {
            throw LumaAudioIntentError.serviceUnavailable
        }
        switch action {
        case .create:
            guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return .result(dialog: IntentDialog("What should I name the new playlist?"))
            }
            let created = try await playlists.createPlaylist(name: name, description: nil)
            return .result(dialog: IntentDialog("Created the playlist \(created.name)."))
        case .list:
            let all = try await playlists.listPlaylists()
            guard !all.isEmpty else {
                return .result(dialog: IntentDialog("You don't have any playlists in Luma yet."))
            }
            let names = all.prefix(10).map(\.name).joined(separator: ", ")
            return .result(dialog: IntentDialog(stringLiteral: "You have \(all.count) playlists: \(names)"))
        case .play:
            guard let playlist, let id = LumaEntityID(rawValue: playlist.id) else {
                return .result(dialog: IntentDialog("Which playlist should I play?"))
            }
            guard let catalog = await SiriBridge.catalogProvider?(),
                  let player = await SiriBridge.playbackProvider?() else {
                throw LumaAudioIntentError.serviceUnavailable
            }
            let tracks = await catalog.playableSongs(inPlaylist: id)
            guard !tracks.isEmpty else {
                throw LumaAudioIntentError.noAudioEntity
            }
            try await player.play(tracks: tracks, startIndex: 0)
            return .result(dialog: IntentDialog("Playing the playlist \(playlist.title)."))
        case .addSong, .addCurrentSong:
            guard let playlist, let playlistID = LumaEntityID(rawValue: playlist.id) else {
                return .result(dialog: IntentDialog("Which playlist should I add the song to?"))
            }
            guard let catalog = await SiriBridge.catalogProvider?() else {
                throw LumaAudioIntentError.serviceUnavailable
            }
            let resolvedSongID: LumaEntityID?
            if action == .addCurrentSong || song == nil {
                guard let player = await SiriBridge.playbackProvider?(),
                      let current = player.state.currentTrack else {
                    return .result(dialog: IntentDialog("Luma isn't playing a song right now."))
                }
                resolvedSongID = LumaEntityID(serverId: playlistID.serverId, localId: current.id)
            } else if let song {
                resolvedSongID = LumaEntityID(rawValue: song.id)
            } else {
                resolvedSongID = nil
            }
            guard let resolvedSongID, resolvedSongID.serverId == playlistID.serverId,
                  let record = await catalog.songRecord(id: resolvedSongID) else {
                throw LumaAudioIntentError.noAudioEntity
            }
            try await playlists.addTracks(playlistId: playlistID.localId, songs: [record])
            return .result(dialog: IntentDialog("Added the song to \(playlist.title)."))
        case .rename:
            guard let playlist, let playlistID = LumaEntityID(rawValue: playlist.id),
                  let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return .result(dialog: IntentDialog("Tell me the playlist and its new name."))
            }
            try await playlists.renamePlaylist(id: playlistID.localId, newName: name)
            return .result(dialog: IntentDialog("Renamed the playlist to \(name)."))
        case .delete:
            guard let playlist, let playlistID = LumaEntityID(rawValue: playlist.id) else {
                return .result(dialog: IntentDialog("Which playlist should I delete?"))
            }
            guard confirmed else {
                return .result(dialog: IntentDialog("Deleting a playlist needs confirmation. Ask me again and confirm the deletion."))
            }
            try await requestConfirmation(
                conditions: [],
                actionName: .do,
                dialog: IntentDialog("Delete the playlist \(playlist.title)?")
            )
            try await playlists.deletePlaylist(id: playlistID.localId, purgeDownloads: false)
            return .result(dialog: IntentDialog("Deleted the playlist \(playlist.title)."))
        }
    }
}

// MARK: - Favorites

@available(iOS 27.3, macOS 27.3, *)
enum LumaFavoriteToolAction: String, AppEnum {
    case like
    case unlike
    case check
    case listSongs
    case listAlbums
    case listArtists
    case playSongs

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Favorite Action")
    }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .like: DisplayRepresentation(title: "Like"),
            .unlike: DisplayRepresentation(title: "Unlike"),
            .check: DisplayRepresentation(title: "Check Favorite"),
            .listSongs: DisplayRepresentation(title: "List Favorite Songs"),
            .listAlbums: DisplayRepresentation(title: "List Favorite Albums"),
            .listArtists: DisplayRepresentation(title: "List Favorite Artists"),
            .playSongs: DisplayRepresentation(title: "Play Favorite Songs")
        ]
    }
}

/// Custom tool for the current song or an explicitly named song. The
/// `.audio.updateAudioAffinity` schema remains the system-facing like action;
/// this tool additionally handles the current track and favorite checks.
@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct LumaFavoriteToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Manage Luma Favorites"
    static let description = IntentDescription(
        "Likes, unlikes, checks, lists, or plays the user's Luma favorites. Song actions use the current song when no song is named.",
        categoryName: "Favorites"
    )
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Action", description: "Like, unlike, check, list, or play favorites.")
    var action: LumaFavoriteToolAction

    @Parameter(title: "Song", description: "The song to use. Omit for the current song.")
    var song: LumaSongEntity?

    @Parameter(title: "Limit", description: "Maximum favorites to list or play.", default: 10)
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        let capped = max(1, min(limit, 25))

        switch action {
        case .listSongs, .playSongs:
            guard let library = await SiriBridge.libraryProvider?() else {
                throw LumaAudioIntentError.serviceUnavailable
            }
            let starred = try await library.getStarred2().song ?? []
            guard !starred.isEmpty else {
                return .result(dialog: IntentDialog("You don't have any favorite songs yet."))
            }
            let selected = Array(starred.prefix(capped))
            if action == .playSongs {
                guard let player = await SiriBridge.playbackProvider?() else {
                    throw LumaAudioIntentError.playerUnavailable
                }
                try await player.play(tracks: selected.map { DisplayableSong(from: $0, isDownloaded: false) }, startIndex: 0)
                return .result(dialog: IntentDialog("Playing your \(selected.count) favorite songs."))
            }
            let summary = selected.map { "\($0.title) — \($0.artist ?? "")" }.joined(separator: "; ")
            return .result(dialog: IntentDialog(stringLiteral: "You have \(starred.count) favorite songs: \(summary)"))
        case .listAlbums:
            guard let library = await SiriBridge.libraryProvider?() else {
                throw LumaAudioIntentError.serviceUnavailable
            }
            let starred = try await library.getStarred2().album ?? []
            guard !starred.isEmpty else {
                return .result(dialog: IntentDialog("You don't have any favorite albums yet."))
            }
            let summary = starred.prefix(capped).map { "\($0.name) — \($0.artist ?? "")" }.joined(separator: "; ")
            return .result(dialog: IntentDialog(stringLiteral: "You have \(starred.count) favorite albums: \(summary)"))
        case .listArtists:
            guard let library = await SiriBridge.libraryProvider?() else {
                throw LumaAudioIntentError.serviceUnavailable
            }
            let starred = try await library.getStarred2().artist ?? []
            guard !starred.isEmpty else {
                return .result(dialog: IntentDialog("You don't have any favorite artists yet."))
            }
            let summary = starred.prefix(capped).map(\.name).joined(separator: ", ")
            return .result(dialog: IntentDialog(stringLiteral: "You have \(starred.count) favorite artists: \(summary)"))
        case .like, .unlike, .check:
            guard let favorites = await SiriBridge.favoritesProvider?(),
                  let identity = await SiriBridge.catalogIdentityProvider?() else {
                throw LumaAudioIntentError.serviceUnavailable
            }
            let resolved: (id: String, title: String, serverID: UUID)
            if let song, let entityID = LumaEntityID(rawValue: song.id) {
                resolved = (entityID.localId, song.title, entityID.serverId)
            } else if let player = await SiriBridge.playbackProvider?(),
                      let current = player.state.currentTrack {
                resolved = (current.id, current.title, identity.serverID)
            } else {
                return .result(dialog: IntentDialog("Luma isn't playing a song right now."))
            }
            guard resolved.serverID == identity.serverID else {
                throw LumaAudioIntentError.unsupportedTarget
            }
            switch action {
            case .like:
                try await favorites.star(itemType: .song, itemId: resolved.id)
                return .result(dialog: IntentDialog("Added \(resolved.title) to your favorites."))
            case .unlike:
                try await favorites.unstar(itemType: .song, itemId: resolved.id)
                return .result(dialog: IntentDialog("Removed \(resolved.title) from your favorites."))
            default:
                let isFavorite = await favorites.isFavoriteInBackground(itemType: .song, itemId: resolved.id)
                return .result(dialog: IntentDialog(isFavorite
                    ? "\(resolved.title) is in your favorites."
                    : "\(resolved.title) isn't in your favorites."))
            }
        }
    }
}

// MARK: - Listening history

@available(iOS 27.3, macOS 27.3, *)
enum LumaListeningHistoryKind: String, AppEnum {
    case recent
    case topSongsThisMonth
    case topArtistsThisMonth
    case topSongsThisYear

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Listening History")
    }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .recent: DisplayRepresentation(title: "Recently Played"),
            .topSongsThisMonth: DisplayRepresentation(title: "Top Songs This Month"),
            .topArtistsThisMonth: DisplayRepresentation(title: "Top Artists This Month"),
            .topSongsThisYear: DisplayRepresentation(title: "Top Songs This Year")
        ]
    }
}

/// Custom tool over Luma's existing local listening-event store. It reports
/// only events the app actually recorded; it never invents statistics.
@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct LumaListeningHistoryToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Review Luma Listening History"
    static let description = IntentDescription(
        "Reports recently played tracks or the most-played songs and artists from Luma's local listening history for the current month or year.",
        categoryName: "History"
    )
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Report", description: "Which listening-history report to build.")
    var kind: LumaListeningHistoryKind

    @Parameter(title: "Limit", description: "Maximum number of entries to report.", default: 5)
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        guard let stats = await SiriBridge.statsProvider?(),
              let identity = await SiriBridge.catalogIdentityProvider?() else {
            throw LumaAudioIntentError.serviceUnavailable
        }
        let capped = max(1, min(limit, 10))
        let serverId = identity.serverID.uuidString
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)

        switch kind {
        case .recent:
            let events = await stats.recentEvents(limit: capped, serverId: serverId)
            guard !events.isEmpty else {
                return .result(dialog: IntentDialog("I don't have any listening history for this server yet."))
            }
            let summary = events.map { "\($0.trackTitle) — \($0.artistName)" }.joined(separator: "; ")
            return .result(dialog: IntentDialog(stringLiteral: "Recently played: \(summary)"))
        case .topSongsThisMonth:
            let entries = await stats.topTracks(
                forPeriod: .month(year: year, month: month),
                serverId: serverId,
                limit: capped,
                calendar: calendar
            )
            guard !entries.isEmpty else {
                return .result(dialog: IntentDialog("I don't have enough listening history for this month yet."))
            }
            let summary = entries.map { "\($0.title) — \($0.artistName)" }.joined(separator: "; ")
            return .result(dialog: IntentDialog(stringLiteral: "Top songs this month: \(summary)"))
        case .topSongsThisYear:
            let entries = await stats.topTracks(
                forPeriod: .year(year),
                serverId: serverId,
                limit: capped,
                calendar: calendar
            )
            guard !entries.isEmpty else {
                return .result(dialog: IntentDialog("I don't have enough listening history for this year yet."))
            }
            let summary = entries.map { "\($0.title) — \($0.artistName)" }.joined(separator: "; ")
            return .result(dialog: IntentDialog(stringLiteral: "Top songs this year: \(summary)"))
        case .topArtistsThisMonth:
            let entries = await stats.topTracks(
                forPeriod: .month(year: year, month: month),
                serverId: serverId,
                limit: 100,
                calendar: calendar
            )
            guard !entries.isEmpty else {
                return .result(dialog: IntentDialog("I don't have enough listening history for this month yet."))
            }
            var counts: [String: (plays: Int, seconds: TimeInterval)] = [:]
            for entry in entries {
                let current = counts[entry.artistName] ?? (0, 0)
                counts[entry.artistName] = (current.plays + entry.playCount,
                                            current.seconds + entry.totalSecondsListened)
            }
            let top = counts.sorted {
                $0.value.plays == $1.value.plays ? $0.value.seconds > $1.value.seconds : $0.value.plays > $1.value.plays
            }.prefix(capped)
            let summary = top.map { "\($0.key) (\($0.value.plays) plays)" }.joined(separator: ", ")
            return .result(dialog: IntentDialog(stringLiteral: "Top artists this month: \(summary)"))
        }
    }
}

// MARK: - Compound playlist builder

@available(iOS 27.3, macOS 27.3, *)
enum LumaPlaylistSourceKind: String, AppEnum {
    case songs
    case albums

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Playlist Source")
    }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .songs: DisplayRepresentation(title: "Matching Songs"),
            .albums: DisplayRepresentation(title: "Matching Albums")
        ]
    }
}

/// One-step compound tool: search the real library, create a playlist from the
/// results, add the tracks, and optionally start it. This is deliberately a
/// custom tool because it spans search, mutation, and playback; the system
/// `createPlaylist` schema remains available for a simple named playlist.
@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct LumaBuildPlaylistToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Build a Playlist from Library Results"
    static let description = IntentDescription(
        "Searches Luma, creates a new playlist from the matching songs or album tracks, adds the tracks on the server, and optionally starts playback.",
        categoryName: "Playlists"
    )
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Name", description: "Name for the new playlist.")
    var name: String

    @Parameter(title: "Query", description: "Text used to find songs or albums in the library.")
    var query: String

    @Parameter(title: "Source", description: "Search songs directly or expand matching albums into tracks.", default: .songs)
    var source: LumaPlaylistSourceKind

    @Parameter(title: "Limit", description: "Maximum songs or albums to include.", default: 10)
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?(),
              let playlists = await SiriBridge.playlistProvider?() else {
            throw LumaAudioIntentError.serviceUnavailable
        }
        let playlistName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !playlistName.isEmpty, !searchTerm.isEmpty else {
            return .result(dialog: IntentDialog("Tell me a playlist name and what music to include."))
        }
        let capped = max(1, min(limit, 50))
        var tracks: [DisplayableSong] = []
        var records: [Song] = []

        switch source {
        case .songs:
            let songs = await catalog.songs(matching: searchTerm, limit: capped)
            for song in songs {
                guard let id = LumaEntityID(rawValue: song.id),
                      let track = await catalog.playableSong(id: id),
                      let record = await catalog.songRecord(id: id) else { continue }
                tracks.append(track)
                records.append(record)
            }
        case .albums:
            let albums = await catalog.albums(matching: searchTerm, limit: capped)
            for album in albums {
                guard let id = LumaEntityID(rawValue: album.id) else { continue }
                let albumTracks = await catalog.playableSongs(inAlbum: id)
                for track in albumTracks {
                    guard records.count < capped * 20,
                          let record = await catalog.songRecord(
                            id: LumaEntityID(serverId: id.serverId, localId: track.id)
                          ) else { continue }
                    tracks.append(track)
                    records.append(record)
                }
            }
        }

        guard !records.isEmpty else {
            return .result(dialog: IntentDialog("I couldn't find any playable tracks for that playlist."))
        }
        let created = try await playlists.createPlaylist(name: playlistName, description: nil)
        try await playlists.addTracks(playlistId: created.id, songs: records)
        if let player = await SiriBridge.playbackProvider?(), !tracks.isEmpty {
            try await player.play(tracks: tracks, startIndex: 0)
            return .result(dialog: IntentDialog("Created and started \(playlistName) with \(records.count) tracks."))
        }
        return .result(dialog: IntentDialog("Created \(playlistName) with \(records.count) tracks."))
    }
}
