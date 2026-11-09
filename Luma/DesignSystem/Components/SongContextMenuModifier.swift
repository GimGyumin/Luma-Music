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

struct SongContextMenuModifier: ViewModifier {
    let song: DisplayableSong
    let coverImage: PlatformImage?

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var showPinLimitAlert = false
    @State private var pinnedSnapshot = false
    @State private var favoriteSnapshot = false
    @State private var loadedCoverImage: PlatformImage?
    @State private var showAddToPlaylist = false
    @State private var showAtmosSelection = false

    private var isFavorite: Bool { favoriteSnapshot }
    private var isPinned: Bool { pinnedSnapshot }
    private var isOnline: Bool { container?.serverState.isOnline == true }

    func body(content: Content) -> some View {
        content
            .musicShareDraggable(itemID: song.id, title: song.title)
            .contextMenu {
                Group {
                    ControlGroup {
                        Button {
                            toggleFavorite()
                        } label: {
                            Label(
                                isFavorite ? "Unfavorite" : "Favorite",
                                systemImage: isFavorite ? "star.fill" : "star"
                            )
                        }
                        .disabled(!isOnline)

                        ContextMenuShareAction(itemID: song.id, text: shareText)
                    }

                    Divider()

                    Button {
                        Task {
                            do {
                                try await container?.playerService.play(tracks: [song], startIndex: 0)
                            } catch {
                                Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                            }
                        }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }

                    Button {
                        playInstantMix(container: container, itemID: song.id, source: .song)
                    } label: {
                        Label("Instant Mix", systemImage: "wand.and.stars")
                    }
                    .disabled(!isOnline)

                    Divider()

                    pinButton

                    if !AtmosVariantCatalogue.isAtmos(song) {
                        Button { showAtmosSelection = true } label: {
                            Label("Dolby Atmos Version…", systemImage: "waveform")
                        }
                    }

                    Button {
                        showAddToPlaylist = true
                    } label: {
                        Label("Add to Playlist…", systemImage: "text.badge.plus")
                    }
                    .disabled(!isOnline)

                    Divider()

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
                }
                .tint(.primary)
                .foregroundStyle(.primary)
            } preview: {
                SongContextPreview(coverImage: coverImage ?? loadedCoverImage, song: song)
            }
            .alert("Pin Limit Reached", isPresented: $showPinLimitAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(PinError.limitReached.errorDescription ?? "")
            }
            .sheet(isPresented: $showAddToPlaylist) {
                AddToPlaylistSheet(song: song)
            }
            .sheet(isPresented: $showAtmosSelection) {
                AtmosVersionSelectionView(song: song)
            }
            .task(id: song.id) {
                // Preload persistent state and artwork while the row is idle, so the
                // long-press presentation performs no database or network work.
                pinnedSnapshot = await container?.pinService.isPinnedInBackground(itemType: .song, itemId: song.id) == true
                favoriteSnapshot = await container?.favoritesService.isFavoriteInBackground(itemType: .song, itemId: song.id) == true
                guard !Task.isCancelled else { return }
                guard coverImage == nil else { return }
                let artId = song.coverArtId ?? song.id
                if let cached = artworkImageCache.cachedImage(for: artId, tier: .thumb) {
                    loadedCoverImage = cached
                } else {
                    loadedCoverImage = await artworkImageCache.load(coverArtId: artId, tier: .thumb)
                }
            }
    }

    @ViewBuilder
    private var pinButton: some View {
        if isPinned {
            Button {
                HapticFeedback.light.trigger()
                container?.pinService.unpin(itemType: .song, itemId: song.id)
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
                        itemType: .song,
                        itemId: song.id,
                        displayName: song.title,
                        displaySubtitle: song.artist ?? "",
                        coverArtId: song.coverArtId,
                        serverId: serverId
                    )
                    pinnedSnapshot = true
                    HapticFeedback.success.trigger()
                    container?.toastService.showConfirmation(String(localized: "Pinned to Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } catch PinError.limitReached {
                    HapticFeedback.warning.trigger()
                    showPinLimitAlert = true
                } catch {}
            } label: {
                Label("Pin Song", systemImage: "pin")
            }
        }
    }

    private var shareText: String {
        [song.title, song.artist, song.albumName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    private func toggleFavorite() {
        let wasFavorite = favoriteSnapshot
        favoriteSnapshot.toggle()
        Task {
            do {
                if wasFavorite {
                    try await container?.favoritesService.unstar(itemType: .song, itemId: song.id)
                } else {
                    try await container?.favoritesService.star(itemType: .song, itemId: song.id)
                }
            } catch {
                favoriteSnapshot = wasFavorite
            }
        }
    }
}

// MARK: - Collection context menu (albums and playlists)

/// Adds Play / Shuffle / Play Next / Add to Queue (when songs are provided),
/// Pin / Unpin, and Favorite (when favoriteType is non-nil) for albums and playlists.
/// `songs` defaults to empty — omit it on list rows where tracks aren't pre-loaded.
/// `favoriteType` is nil for playlists (Subsonic does not support playlist starring).
