#if os(iOS)
import AppIntents
import Foundation
import MediaPlayer
import NowPlaying
import Observation
import OSLog
import UIKit

/// One native local session; it never registers MPRemoteCommandCenter handlers.
/// The established player service continues to own audio, queue and seeks.
@available(iOS 27.0, *)
@MainActor @Observable
final class LumaNativeMediaSession: @MainActor MediaSessionRepresentable {
    let id = "luma.playback"
    private(set) var content: (any MediaContentRepresentable)?
    private(set) var playbackSnapshot: MediaPlaybackSnapshot?
    private var isLive = false
    @ObservationIgnored private(set) var metadata: [String: Any]?
    @ObservationIgnored private var session: MediaSession<LumaNativeMediaSession>?
    @ObservationIgnored private var primaryRequest: Task<Void, Never>?
    @ObservationIgnored private let action: @MainActor (NowPlayingService.RemoteCommand) async -> Void
    @ObservationIgnored private let identity: @MainActor () -> ServerRequestIdentity?
    @ObservationIgnored private let favorite: NowPlayingFavoriteController?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var contentKey: ContentKey?
    private struct ClockKey: Equatable {
        let id: String
        let elapsed: Double?
        let rate: Float
    }
    @ObservationIgnored private var clockKey: ClockKey?
    @ObservationIgnored private var immersiveArtwork: AnimatedArtwork?
    @ObservationIgnored private var immersiveIdentifier: String?
    @ObservationIgnored private var primaryAttempts = 0
    @ObservationIgnored private var primaryRetryAfter = Date.distantPast

    private struct ContentKey: Equatable {
        var id: String; var title: String; var artist: String; var album: String
        var duration: Double; var isrc: String?; var artwork: ObjectIdentifier?; var animatedID: String?; var live: Bool
    }

    init(favorites: (any FavoritesServiceProtocol)?, identity: @escaping @MainActor () -> ServerRequestIdentity?,
         action: @escaping @MainActor (NowPlayingService.RemoteCommand) async -> Void) {
        self.identity = identity
        self.action = action
        self.favorite = favorites.map { NowPlayingFavoriteController(favorites: $0, currentIdentity: identity) }
        observer = NotificationCenter.default.addObserver(forName: .lumaFavoritesChanged, object: nil, queue: .main) { [weak favorite = self.favorite] _ in
            Task { @MainActor [weak favorite] in favorite?.refresh() }
        }
        session = MediaSession(self)
    }

    var commands: [MediaCommand] {
        var result: [MediaCommand] = [
            .play { [weak self] in await self?.action(.play) },
            .pause { [weak self] in await self?.action(.pause) },
            .togglePlayPause { [weak self] in await self?.action(.toggle) },
            .next { [weak self] in await self?.action(.next) }.enabled(!isLive),
            .previous { [weak self] in await self?.action(.previous) }.enabled(!isLive),
            .seekToPosition { [weak self] position in await self?.action(.seek(position)) }.enabled(!isLive)
        ]
        if !isLive, let favorite, let selection = favorite.selection {
            result.append(.feedback(title: String(localized: "Favorite"), shortTitle: String(localized: "Favorite"),
                status: favorite.isFavorite == true ? .positive : .neutral) { [weak favorite] status in
                    guard let favorite else { throw CancellationError() }
                    try await favorite.setFavorite(status == .positive, for: selection)
                }.enabled(favorite.isFavorite != nil && !favorite.isMutating))
        }
        return result
    }

    func apply(_ value: [String: Any]?) {
        metadata = value
        guard let value, let title = value[MPMediaItemPropertyTitle] as? String else {
            content = nil; contentKey = nil
            immersiveArtwork = nil; immersiveIdentifier = nil
            playbackSnapshot = .init(state: .stopped)
            clockKey = nil
            favorite?.select(songID: nil, identity: nil)
            primaryRequest?.cancel(); primaryRequest = nil
            session = nil; primaryAttempts = 0
            return
        }
        if session == nil { session = MediaSession(self) }
        let external = value[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String ?? title
        let localID = external.hasPrefix("luma.track.") ? String(external.dropFirst("luma.track.".count)) : nil
        let account = identity()
        let canonical = localID.flatMap { song in account.map { LumaEntityID(serverId: $0.serverID, localId: song).rawValue } } ?? external
        if immersiveIdentifier != external { immersiveArtwork = nil; immersiveIdentifier = nil }
        let artwork = value[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        let live = value[MPNowPlayingInfoPropertyIsLiveStream] as? Bool ?? false
        let key = ContentKey(id: canonical, title: title, artist: value[MPMediaItemPropertyArtist] as? String ?? "",
            album: value[MPMediaItemPropertyAlbumTitle] as? String ?? "",
            duration: (value[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue ?? 0,
            isrc: value[MPNowPlayingInfoPropertyInternationalStandardRecordingCode] as? String,
            artwork: artwork.map(ObjectIdentifier.init), animatedID: immersiveArtwork?.id, live: live)
        isLive = live
        favorite?.select(songID: live ? nil : localID, identity: account)
        if key != contentKey {
            if key.id != contentKey?.id { primaryAttempts = 0; primaryRetryAfter = .distantPast }
            contentKey = key
            let nativeArtwork = artwork.map { legacy in
                Artwork(id: canonical + ":" + String(describing: ObjectIdentifier(legacy))) { requestedSize in
                    let image = await MainActor.run { legacy.image(at: requestedSize) }
                    guard let cgImage = image?.cgImage else { throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable }
                    return try ArtworkRepresentation(cgImage: cgImage)
                }
            }
            if live {
                content = RadioContent(id: canonical, stationName: title, programName: key.artist.isEmpty ? nil : key.artist,
                    duration: .live, artwork: nativeArtwork)
            } else {
                var music: MusicContent
                if let nativeArtwork, let immersiveArtwork {
                    music = MusicContent(id: canonical, songTitle: title, artistName: key.artist, albumName: key.album,
                        type: .audio, duration: .finite(key.duration), artwork: nativeArtwork, animatedArtwork: immersiveArtwork)
                } else {
                    music = MusicContent(id: canonical, songTitle: title, artistName: key.artist, albumName: key.album,
                        type: .audio, duration: .finite(key.duration), artwork: nativeArtwork)
                }
                music.isrc = key.isrc
                if let localID, let account {
                    let entity = LumaSongEntity(song: DisplayableSong(id: localID, title: title, artist: key.artist,
                        albumName: key.album, duration: key.duration, isrc: key.isrc), serverId: account.serverID)
                    music.appEntityIdentifiers = [EntityIdentifier(for: entity)]
                }
                content = music
            }
        }
        let rate = (value[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.floatValue ?? 0
        let clock = ClockKey(id: canonical, elapsed: live ? nil : (value[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue, rate: rate)
        if clock != clockKey {
            clockKey = clock
            // Artwork/ISRC-only changes keep the system's extrapolated clock;
            // re-stamping an old elapsed value here rewound the scrubber.
            playbackSnapshot = .init(state: rate > 0 ? .playing(rate: rate) : .paused,
                elapsedTime: clock.elapsed, timestamp: Date())
        }
        if rate > 0 { requestPrimaryIfNeeded() }
    }

    func installImmersive(_ prepared: LockScreenImmersiveArtwork.Prepared?, for identifier: String?) {
        guard let identifier, metadata?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String == identifier else { return }
        immersiveIdentifier = identifier
        immersiveArtwork = prepared.map(LockScreenImmersiveArtwork.native)
        apply(metadata)
    }

    func reassert() { primaryAttempts = 0; primaryRetryAfter = .distantPast; favorite?.refresh(); requestPrimaryIfNeeded() }
    private func requestPrimaryIfNeeded() {
        guard content != nil, let session, !session.isSystemPrimary, primaryRequest == nil,
              primaryAttempts < 3, Date() >= primaryRetryAfter else { return }
        primaryAttempts += 1
        primaryRetryAfter = Date().addingTimeInterval(Double(primaryAttempts * 2))
        primaryRequest = Task { [weak self] in
            defer { self?.primaryRequest = nil }
            do {
                if !session.isApplicationPrimary { try await session.requestToBecomeApplicationPrimary() }
                try Task.checkCancellation()
                try await session.requestToBecomeSystemPrimary()
            } catch { Logger.nowPlaying.error("Native Now Playing primary request failed") }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        primaryRequest?.cancel()
    }
}
#endif
