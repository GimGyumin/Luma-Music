import AppIntents
import Foundation
import SwiftSonic

@available(iOS 27.3, macOS 27.3, *)
enum LumaPlaylistEditToolAction: String, AppEnum {
    case removeSong
    case reorder
    case duplicate
    case addAlbum

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Playlist Edit")
    }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .removeSong: DisplayRepresentation(title: "Remove a Song"),
            .reorder: DisplayRepresentation(title: "Reorder Songs"),
            .duplicate: DisplayRepresentation(title: "Duplicate Playlist"),
            .addAlbum: DisplayRepresentation(title: "Add an Album")
        ]
    }
}

/// Edits the track list of an existing Luma playlist. Kept separate from the
/// create/play tool so Siri can describe a bounded operation with six inputs.
@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct LumaPlaylistEditToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Edit Luma Playlist Tracks"
    static let description = IntentDescription(
        "Edits an existing Luma playlist: removes one track, moves a track to another position, duplicates the whole playlist, or appends every track from an album. Track removal and duplication ask for confirmation.",
        categoryName: "Playlists"
    )
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Action", description: "The playlist edit to perform.")
    var action: LumaPlaylistEditToolAction

    @Parameter(title: "Playlist", description: "The existing playlist to edit.")
    var playlist: LumaPlaylistEntity?

    @Parameter(title: "Song", description: "The song to remove.")
    var song: LumaSongEntity?

    @Parameter(title: "Album", description: "The album whose tracks should be appended.")
    var album: LumaAlbumEntity?

    @Parameter(title: "Index", description: "One-based position of the song to remove or move.")
    var index: Int?

    @Parameter(title: "To Index", description: "One-based destination position for reordering.")
    var toIndex: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        guard let playlists = await SiriBridge.playlistProvider?() else {
            throw LumaAudioIntentError.serviceUnavailable
        }
        switch action {
        case .removeSong:
            guard let playlist, let playlistID = LumaEntityID(rawValue: playlist.id) else {
                return .result(dialog: IntentDialog("Which playlist should I edit?"))
            }
            let detail = try await playlists.getPlaylist(id: playlistID.localId)
            let entries = detail.entry ?? []
            let candidates = matchingTrackIndices(in: entries, song: song, index: index)
            guard candidates.count == 1, let match = candidates.first else {
                if candidates.count > 1 {
                    return .result(dialog: IntentDialog("I found more than one matching song. Tell me the exact title or its position."))
                }
                return .result(dialog: IntentDialog("I couldn't find that song in \(playlist.title)."))
            }
            let title = entries[match].title
            try await requestConfirmation(
                conditions: [],
                actionName: .do,
                dialog: IntentDialog("Remove \(title) from the playlist \(playlist.title)?")
            )
            try await playlists.removeTracks(playlistId: playlistID.localId, indices: [match])
            return .result(dialog: IntentDialog("Removed \(title) from \(playlist.title)."))
        case .reorder:
            guard let playlist, let playlistID = LumaEntityID(rawValue: playlist.id),
                  let index, let toIndex else {
                return .result(dialog: IntentDialog("Tell me the playlist, the current position, and the new position."))
            }
            let detail = try await playlists.getPlaylist(id: playlistID.localId)
            let entries = detail.entry ?? []
            guard entries.indices.contains(index - 1) else {
                return .result(dialog: IntentDialog("That starting position isn't in the playlist."))
            }
            guard (1...entries.count).contains(toIndex) else {
                return .result(dialog: IntentDialog("That destination position isn't in the playlist."))
            }
            var ordered = entries
            let moved = ordered.remove(at: index - 1)
            ordered.insert(moved, at: min(max(0, toIndex - 1), ordered.count))
            try await playlists.reorderTracks(playlistId: playlistID.localId, orderedSongIds: ordered.map(\.id))
            return .result(dialog: IntentDialog("Moved \(moved.title) to position \(toIndex) in \(playlist.title)."))
        case .duplicate:
            guard let playlist, let playlistID = LumaEntityID(rawValue: playlist.id) else {
                return .result(dialog: IntentDialog("Which playlist should I duplicate?"))
            }
            try await requestConfirmation(
                conditions: [],
                actionName: .do,
                dialog: IntentDialog("Duplicate the playlist \(playlist.title)?")
            )
            let detail = try await playlists.getPlaylist(id: playlistID.localId)
            let newName = "\(playlist.title) Copy"
            let created = try await playlists.createPlaylist(name: newName, description: detail.comment)
            let entries = detail.entry ?? []
            guard !entries.isEmpty else {
                return .result(dialog: IntentDialog("Duplicated \(playlist.title) as an empty playlist named \(created.name)."))
            }
            do {
                try await playlists.addTracks(playlistId: created.id, songs: entries)
            } catch {
                // Do not leave a half-created playlist behind after a failed copy.
                try? await playlists.deletePlaylist(id: created.id, purgeDownloads: false)
                throw error
            }
            return .result(dialog: IntentDialog("Duplicated \(playlist.title) as \(created.name) with \(entries.count) tracks."))
        case .addAlbum:
            guard let playlist, let playlistID = LumaEntityID(rawValue: playlist.id),
                  let album, let albumID = LumaEntityID(rawValue: album.id),
                  albumID.serverId == playlistID.serverId,
                  let catalog = await SiriBridge.catalogProvider?() else {
                return .result(dialog: IntentDialog("Tell me which album and which playlist to use."))
            }
            let tracks = await catalog.playableSongs(inAlbum: albumID)
            guard !tracks.isEmpty else {
                return .result(dialog: IntentDialog("That album has no tracks I can add."))
            }
            try await playlists.addTracks(playlistId: playlistID.localId, songs: tracks.map { $0.asSong() })
            return .result(dialog: IntentDialog("Added \(tracks.count) tracks from \(album.title) to \(playlist.title)."))
        }
    }

    /// One-based or entity matching for playlist entries. Returns every match so
    /// the caller can ask instead of removing the wrong version.
    private func matchingTrackIndices(
        in entries: [Song],
        song: LumaSongEntity?,
        index: Int?
    ) -> [Int] {
        if let index {
            let zeroBased = index - 1
            return entries.indices.contains(zeroBased) ? [zeroBased] : []
        }
        if let song, let id = LumaEntityID(rawValue: song.id) {
            return entries.indices.filter { entries[$0].id == id.localId }
        }
        return []
    }
}
