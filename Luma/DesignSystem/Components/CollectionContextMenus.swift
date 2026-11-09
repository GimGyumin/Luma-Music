// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import OSLog
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct CollectionContextMenuModifier: ViewModifier {
    let itemType: PinnedItemType
    let itemId: String
    let displayName: String
    let displaySubtitle: String
    let coverArtId: String?
    let coverImage: PlatformImage?
    let songs: [DisplayableSong]
    let favoriteType: FavoriteType?
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    @Environment(\.appContainer) private var container
    @State private var showPinLimitAlert = false

    private var isPinned: Bool {
        container?.pinService.isPinned(itemType: itemType, itemId: itemId) == true
    }

    private var isFavorite: Bool {
        guard let ft = favoriteType else { return false }
        return container?.favoritesService.isFavorite(itemType: ft, itemId: itemId) == true
    }

    func body(content: Content) -> some View {
        content
            .musicShareDraggable(itemID: itemId, title: displayName)
            .contextMenu {
                Group {
                    ContextMenuShareAction(itemID: itemId, text: displayName)

                    if !songs.isEmpty {
                        Button {
                            Task {
                                do {
                                    try await container?.playerService.play(tracks: songs, startIndex: 0)
                                } catch {
                                    Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                                }
                            }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }

                        Button {
                            let shuffled = songs.shuffled()
                            Task {
                                do {
                                    try await container?.playerService.play(tracks: shuffled, startIndex: 0)
                                } catch {
                                    Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                                }
                            }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }

                        Button {
                            Task { await container?.playerService.playNext(songs) }
                        } label: {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }

                        Button {
                            Task { await container?.playerService.addToQueue(songs) }
                        } label: {
                            Label("Add to Queue", systemImage: "text.append")
                        }

                        Divider()
                    }

                    Button {
                        playInstantMix(container: container, itemID: itemId, source: instantMixSource)
                    } label: {
                        Label("Instant Mix", systemImage: "wand.and.stars")
                    }

                    Divider()

                    if isPinned {
                        Button {
                            HapticFeedback.light.trigger()
                            container?.pinService.unpin(itemType: itemType, itemId: itemId)
                        } label: {
                            Label("Unpin from Home", systemImage: "pin.slash")
                        }
                    } else {
                        Button {
                            guard let serverId = container?.serverState.activeServer?.id,
                                  let pin = container?.pinService else { return }
                            do {
                                try pin.pin(
                                    itemType: itemType, itemId: itemId,
                                    displayName: displayName, displaySubtitle: displaySubtitle,
                                    coverArtId: coverArtId, serverId: serverId
                                )
                                HapticFeedback.success.trigger()
                                container?.toastService.showConfirmation("Pinned to Home")
                            } catch PinError.limitReached {
                                HapticFeedback.warning.trigger()
                                showPinLimitAlert = true
                            } catch {
                                Logger.pin.error("ItemContextMenus: pin failed — \(error)")
                            }
                        } label: {
                            Label("Pin to Home", systemImage: "pin")
                        }
                    }

                    if favoriteType != nil {
                        Divider()

                        Button {
                            guard let ft = favoriteType else { return }
                            let fav = isFavorite
                            Task {
                                if fav {
                                    try? await container?.favoritesService.unstar(itemType: ft, itemId: itemId)
                                } else {
                                    try? await container?.favoritesService.star(itemType: ft, itemId: itemId)
                                }
                            }
                        } label: {
                            Label(
                                isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                systemImage: isFavorite ? "star.slash" : "star"
                            )
                        }
                    }

                    if onEdit != nil || onDelete != nil {
                        Divider()
                    }

                    if let onEdit {
                        Button { onEdit() } label: { Label("Edit Playlist", systemImage: "pencil") }
                    }

                    if let onDelete {
                        Button(role: .destructive) { onDelete() } label: { Label("Delete Playlist", systemImage: "trash") }
                    }
                }
                .tint(.primary)
                .foregroundStyle(.primary)
            } preview: {
                CollectionContextPreview(
                    coverImage: coverImage,
                    displayName: displayName,
                    displaySubtitle: displaySubtitle,
                    isArtist: itemType == .artist
                )
            }
            .alert("Pin Limit Reached", isPresented: $showPinLimitAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(PinError.limitReached.errorDescription ?? "")
            }
    }

    private var instantMixSource: JellyfinInstantMixSource {
        switch itemType {
        case .song: return .song
        case .album: return .album
        case .artist: return .artist
        case .playlist: return .playlist
        }
    }
}

// MARK: - Lazy collection context menu (albums without pre-loaded songs)

/// Like CollectionContextMenuModifier but fetches songs on-demand when a play action is tapped.
/// Use when tracks are not pre-loaded (e.g., Recently Added albums in HomeView).
struct LazyCollectionContextMenuModifier: ViewModifier {
    let itemType: PinnedItemType
    let itemId: String
    let displayName: String
    let displaySubtitle: String
    let coverArtId: String?
    let coverImage: PlatformImage?
    let favoriteType: FavoriteType?
    let songLoader: () async throws -> [DisplayableSong]

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var showPinLimitAlert = false
    @State private var pinnedSnapshot = false
    @State private var favoriteSnapshot = false
    @State private var loadedCoverImage: PlatformImage?
    @State private var songsToAddToPlaylist: [DisplayableSong] = []
    @State private var showAddToPlaylist = false

    private var isPinned: Bool {
        pinnedSnapshot
    }

    private var isFavorite: Bool {
        favoriteSnapshot
    }

    func body(content: Content) -> some View {
        content
            .musicShareDraggable(itemID: itemId, title: displayName)
            .contextMenu {
                Group {
                    ControlGroup {
                        if favoriteType != nil {
                            Button {
                                toggleFavorite()
                            } label: {
                                Label(
                                    isFavorite ? "Unfavorite" : "Favorite",
                                    systemImage: isFavorite ? "star.fill" : "star"
                                )
                            }
                        }

                        ContextMenuShareAction(itemID: itemId, text: shareText)
                    }

                    Divider()

                    Button {
                        Task {
                            guard let songs = try? await songLoader(), !songs.isEmpty else { return }
                            do {
                                try await container?.playerService.play(tracks: songs, startIndex: 0)
                            } catch {
                                Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                            }
                        }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }

                    Button {
                        Task {
                            guard let songs = try? await songLoader(), !songs.isEmpty else { return }
                            do {
                                try await container?.playerService.play(tracks: songs.shuffled(), startIndex: 0)
                            } catch {
                                Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                            }
                        }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }

                    Button {
                        playInstantMix(container: container, itemID: itemId, source: instantMixSource)
                    } label: {
                        Label("Instant Mix", systemImage: "wand.and.stars")
                    }

                    Divider()

                    if isPinned {
                        Button {
                            HapticFeedback.light.trigger()
                            container?.pinService.unpin(itemType: itemType, itemId: itemId)
                            pinnedSnapshot = false
                        } label: {
                            Label("Unpin from Home", systemImage: "pin.slash")
                        }
                    } else {
                        Button {
                            guard let serverId = container?.serverState.activeServer?.id,
                                  let pin = container?.pinService else { return }
                            do {
                                try pin.pin(
                                    itemType: itemType, itemId: itemId,
                                    displayName: displayName, displaySubtitle: displaySubtitle,
                                    coverArtId: coverArtId, serverId: serverId
                                )
                                pinnedSnapshot = true
                                HapticFeedback.success.trigger()
                                container?.toastService.showConfirmation("Pinned to Home")
                            } catch PinError.limitReached {
                                HapticFeedback.warning.trigger()
                                showPinLimitAlert = true
                            } catch {
                                Logger.pin.error("ItemContextMenus: pin failed — \(error)")
                            }
                        } label: {
                            Label("Pin to Home", systemImage: "pin")
                        }
                    }

                    if itemType == .album {
                        Button {
                            Task {
                                guard let songs = try? await songLoader(), !songs.isEmpty else { return }
                                songsToAddToPlaylist = songs
                                showAddToPlaylist = true
                            }
                        } label: {
                            Label("Add to Playlist…", systemImage: "text.badge.plus")
                        }
                    }

                    Divider()

                    Button {
                        Task {
                            guard let songs = try? await songLoader(), !songs.isEmpty else { return }
                            await container?.playerService.playNext(songs)
                        }
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }

                    Button {
                        Task {
                            guard let songs = try? await songLoader(), !songs.isEmpty else { return }
                            await container?.playerService.addToQueue(songs)
                        }
                    } label: {
                        Label("Add to Queue", systemImage: "text.append")
                    }
                }
                .tint(.primary)
                .foregroundStyle(.primary)
            } preview: {
                CollectionContextPreview(
                    coverImage: coverImage ?? loadedCoverImage,
                    displayName: displayName,
                    displaySubtitle: displaySubtitle,
                    isArtist: itemType == .artist
                )
            }
            .alert("Pin Limit Reached", isPresented: $showPinLimitAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(PinError.limitReached.errorDescription ?? "")
            }
            .sheet(isPresented: $showAddToPlaylist) {
                AddToPlaylistSheet(songs: songsToAddToPlaylist)
            }
            .task(id: "\(itemType.rawValue):\(itemId):\(coverArtId ?? "")") {
                // Snapshot persistent state before a press. Context-menu construction then
                // performs no SwiftData fetches and appears immediately.
                pinnedSnapshot = await container?.pinService.isPinnedInBackground(itemType: itemType, itemId: itemId) == true
                if let favoriteType {
                    favoriteSnapshot = await container?.favoritesService.isFavoriteInBackground(
                        itemType: favoriteType,
                        itemId: itemId
                    ) == true
                }
                guard !Task.isCancelled else { return }
                guard coverImage == nil else { return }
                let artId = coverArtId ?? itemId
                if let cached = artworkImageCache.cachedImage(for: artId, tier: .thumb) {
                    loadedCoverImage = cached
                } else {
                    loadedCoverImage = await artworkImageCache.load(coverArtId: artId, tier: .thumb)
                }
            }
    }

    private var shareText: String {
        displaySubtitle.isEmpty ? displayName : "\(displayName) — \(displaySubtitle)"
    }

    private var instantMixSource: JellyfinInstantMixSource {
        switch itemType {
        case .song: return .song
        case .album: return .album
        case .artist: return .artist
        case .playlist: return .playlist
        }
    }

    private func toggleFavorite() {
        guard let favoriteType else { return }
        let wasFavorite = favoriteSnapshot
        favoriteSnapshot.toggle()
        Task {
            do {
                if wasFavorite {
                    try await container?.favoritesService.unstar(itemType: favoriteType, itemId: itemId)
                } else {
                    try await container?.favoritesService.star(itemType: favoriteType, itemId: itemId)
                }
            } catch {
                favoriteSnapshot = wasFavorite
            }
        }
    }
}

@MainActor
func playInstantMix(container: AppContainer?, itemID: String, source: JellyfinInstantMixSource) {
    guard let container else { return }
    Task {
        do {
            let songs = try await container.jellyfinService.instantMix(
                canonicalItemID: itemID,
                source: source
            )
            guard !songs.isEmpty else {
                container.toastService.showError("No Instant Mix tracks were returned.")
                return
            }
            try await container.playerService.play(tracks: songs, startIndex: 0)
        } catch {
            Logger.player.error("Instant Mix failed: \(error.localizedDescription, privacy: .public)")
            container.toastService.showError("Instant Mix isn't available on this server.")
        }
    }
}

// MARK: - View extensions
