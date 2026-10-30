import CoreSpotlight
import SwiftUI

/// Cold-launch URL/activity delivery lives above the loading view, so a Spotlight
/// tap is retained while credentials and the app's normal navigation boot.
struct NativeSearchLifecycle: ViewModifier {
    let container: AppContainer?
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingURL: URL?
    @State private var recentAction = NativeSearchActionGate()

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                enqueue(url)
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                if let key = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                    if let url = Self.url(for: key) { enqueue(url) }
                }
            }
            .task(id: "\(pendingURL?.absoluteString ?? "")|\(container?.serverState.activeServer?.id.uuidString ?? "")|\(container?.serverState.accountRevision ?? 0)") {
                guard let url = pendingURL, let container else { return }
                await AppBootGate.waitForHome()
                guard !Task.isCancelled else { return }
                // Session restoration may finish after Home's boot gate.
                guard container.serverState.activeServer != nil else { return }
                guard let reference = LumaDeepLink.parse(url),
                      reference.id.serverId == container.serverState.activeServer?.id,
                      !container.serverState.isSigningOut else { pendingURL = nil; return }
                if #available(iOS 27.0, macOS 27.0, *), let catalog = await SiriBridge.catalogProvider?() {
                    let revision = container.serverState.accountRevision
                    switch reference.kind {
                    case .song:
                        let song = await catalog.playableSong(id: reference.id)
                        guard revision == container.serverState.accountRevision, !Task.isCancelled else { return }
                        guard let song, reference.id.serverId == container.serverState.activeServer?.id,
                              recentAction.claim(url) else { pendingURL = nil; return }
                        do {
                            if container.playerState.currentTrack?.id == song.id {
                                if !container.playerState.playbackState.hasPlaybackIntent {
                                    await container.playerService.resume()
                                }
                            } else if let index = container.playerState.queue.firstIndex(where: { $0.id == song.id }) {
                                try await container.playerService.play(tracks: container.playerState.queue, startIndex: index)
                            } else {
                                try await container.playerService.play(tracks: [song], startIndex: 0)
                            }
                            guard !Task.isCancelled, revision == container.serverState.accountRevision else { return }
                            NotificationCenter.default.post(name: .lumaOpenFullPlayer, object: nil)
                        } catch {
                            guard !Task.isCancelled, revision == container.serverState.accountRevision else { return }
                            container.toastService.showError(UserFacingError.from(error).displayMessage)
                        }
                    case .album:
                        if let album = await catalog.album(id: reference.id), !Task.isCancelled,
                           revision == container.serverState.accountRevision, recentAction.claim(url) {
                            NotificationCenter.default.post(name: .lumaNavigateToAlbum, object: nil,
                                userInfo: ["albumId": reference.id.localId, "albumName": album.title])
                        }
                    case .artist:
                        if let artist = await catalog.artist(id: reference.id), !Task.isCancelled,
                           revision == container.serverState.accountRevision, recentAction.claim(url) {
                            NotificationCenter.default.post(name: .lumaNavigateToArtist, object: nil,
                                userInfo: ["artistId": reference.id.localId, "artistName": artist.name])
                        }
                    case .playlist:
                        if let playlist = await catalog.playlist(id: reference.id), !Task.isCancelled,
                           revision == container.serverState.accountRevision, recentAction.claim(url) {
                            NotificationCenter.default.post(name: .lumaNavigateToPlaylist, object: nil,
                                userInfo: ["playlistId": reference.id.localId, "name": playlist.title])
                        }
                    }
                }
                if pendingURL == url { pendingURL = nil }
            }
            .task(id: container?.serverState.accountRevision) {
                guard let container else { return }
                if #available(iOS 27.0, macOS 27.0, *) {
                    await LumaNativeSearch.shared.accountDidChange()
                    guard !Task.isCancelled, !container.serverState.isSigningOut else { return }
                    await container.libraryIndexService.ensureIndexedAndWait(using: container.libraryService)
                    guard !Task.isCancelled, let snapshot = container.libraryIndexService.searchableSnapshot,
                          let serverID = container.serverState.activeServer?.id else { return }
                    LumaNativeSearch.shared.accept(snapshot, serverID: serverID)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if #available(iOS 27.0, macOS 27.0, *) {
                    if phase == .background { LumaNativeSearch.shared.suspend() }
                    else if phase == .active { LumaNativeSearch.shared.resume() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: OriginalArtwork.didInstall)) { event in
                if #available(iOS 27.0, macOS 27.0, *), let id = event.object as? String {
                    LumaNativeSearch.shared.artworkChanged(coverID: id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .lumaPlaylistMetadataChanged)) { notification in
                guard let container, notification.userInfo?["serverID"] as? UUID == container.serverState.activeServer?.id else { return }
                container.libraryIndexService.refreshPlaylistMetadata(using: container.playlistService)
            }
            .onReceive(NotificationCenter.default.publisher(for: .lumaFavoritesChanged)) { _ in refreshFlags() }
            .onReceive(NotificationCenter.default.publisher(for: .lumaDownloadCompleted)) { _ in refreshFlags() }
            .onReceive(NotificationCenter.default.publisher(for: .lumaOfflineMetadataChanged)) { _ in refreshFlags() }
    }

    private func enqueue(_ url: URL) {
        guard LumaDeepLink.parse(url) != nil, pendingURL != url else { return }
        pendingURL = url
    }

    private func refreshFlags() {
        if #available(iOS 27.0, macOS 27.0, *) { LumaNativeSearch.shared.refreshLocalState() }
    }

    nonisolated static func url(for key: String) -> URL? {
        guard let colon = key.firstIndex(of: ":"), let id = LumaEntityID(rawValue: String(key[key.index(after: colon)...])) else { return nil }
        let kind: LumaDeepLink.Kind
        switch key[..<colon] {
        case "song": kind = .song
        case "album": kind = .album
        case "artist": kind = .artist
        case "playlist": kind = .playlist
        default: return nil
        }
        return LumaDeepLink.url(kind: kind, id: id)
    }
}

/// URL and NSUserActivity may deliver one tap twice. Expiration permits later intentional opens.
nonisolated struct NativeSearchActionGate {
    private var lastURL: URL?
    private var lastDate = Date.distantPast
    mutating func claim(_ url: URL, now: Date = Date()) -> Bool {
        guard url != lastURL || now.timeIntervalSince(lastDate) >= 1 else { return false }
        lastURL = url; lastDate = now
        return true
    }
}
