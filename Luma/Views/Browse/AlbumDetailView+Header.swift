// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import SwiftData
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension AlbumDetailContentView {
    // MARK: - Header

    @ViewBuilder
    func albumHeader(vm: AlbumDetailViewModel?, songs: [DisplayableSong]) -> some View {
        if artworkStyle == .faded {
            ScrollLinkedFadedArtworkHero(coverArtId: albumCoverId, initialImage: effectiveInitialImage,
                             background: atmosphere.pageColor, title: albumDisplayName,
                             treatment: artworkAnalysis?.fadedTreatment ?? .textured,
                             edgeColor: artworkAnalysis?.bottomBackground,
                             topColor: artworkAnalysis?.topBackground,
                             topInsetPoints: artworkTopInset) {
                albumHeaderInformation(vm: vm, songs: songs, includesTitle: false)
                    .padding(.bottom, LumaSpacing.xxl)
            }
            // Page identity, plus the explicit cover-upload revision. Never the
            // resolved cover ID: that changes when album info loads and would rebuild
            // the hero while a navigation transition is in flight.
            .id("\(albumId):\(coverArtUploadVersion)")
        } else if artworkStyle == .uniform {
            VStack(spacing: 0) {
                SeamlessArtworkHero(coverArtId: albumCoverId, initialImage: effectiveInitialImage,
                                    background: atmosphere.pageColor)
                    .overlay(alignment: .bottom) {
                        if atmosphere.pageColor != contentBackgroundColor {
                            LinearGradient(colors: [atmosphere.pageColor.opacity(0), atmosphere.pageColor],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: heroHeight * 0.14).allowsHitTesting(false)
                        }
                    }
                albumHeaderInformation(vm: vm, songs: songs)
                    .padding(.top, LumaSpacing.s)
                    .padding(.bottom, LumaSpacing.xxl)
            }
        } else {
            ImmersiveCoverHero(
                coverArtId: albumCoverId,
                coverImage: effectiveInitialImage,
                theme: theme,
                heroHeight: heroHeight,
                contentBelow: true,
                fillCover: true,
                meltTargetColor: atmosphere.isThemed ? atmosphere.pageColor : nil,
                showBlurredMelt: false,
                showsFloatingShadow: false,
                coverShadowColor: atmosphere.coverShadowColor,
                floatingInset: true,
                floatingHorizontalPadding: LumaAlbumLayout.coverSideInset,
                floatingTopPadding: LumaSpacing.xxl,
                contentTopPadding: LumaSpacing.xxl,
                contentBottomPadding: LumaSpacing.xxl
            ) {
                albumHeaderInformation(vm: vm, songs: songs)
            }
        }
    }

    private func albumHeaderInformation(vm: AlbumDetailViewModel?, songs: [DisplayableSong], includesTitle: Bool = true) -> some View {
        VStack(spacing: artworkStyle == .faded ? LumaSpacing.m : LumaSpacing.l) {
            albumTitleBlock(vm: vm, songs: songs, alignment: .center, includesTitle: includesTitle)
                .anchorPreference(key: FadedArtworkLayoutKey.self, value: .bounds) { .init(details: $0) }
                .padding(.horizontal, LumaSpacing.xl)
            albumActionBar(vm: vm, songs: songs,
                           playMaxWidth: artworkStyle == .faded ? LumaAlbumLayout.fadedPlayWidth : (usesFullBleedArtwork ? .infinity : LumaAlbumLayout.insetPlayWidth))
                .padding(.horizontal, usesFullBleedArtwork ? LumaSpacing.xxxl : LumaSpacing.l)
                .padding(.top, artworkStyle == .faded ? LumaSpacing.xs : (usesFullBleedArtwork ? LumaSpacing.s : 0))
            if let description = vm?.albumDescription, !description.isEmpty {
                albumAboutPreview(description)
            }
            albumDownloadProgress(vm: vm)
        }
    }

    @ViewBuilder
    func albumTitleBlock(
        vm: AlbumDetailViewModel?,
        songs: [DisplayableSong],
        alignment: HorizontalAlignment,
        includesTitle: Bool = true
    ) -> some View {
        let textAlign: TextAlignment = alignment == .leading ? .leading : .center
        let artist = vm?.artistName ?? initialArtist
        VStack(alignment: alignment, spacing: 0) {
            if includesTitle {
                Text(albumDisplayName)
                    // Music uses SF Pro Display here rather than the rounded display face.
                    .font(usesFullBleedArtwork ? .lumaAlbumTitle : .lumaAlbumCardTitle)
                    .foregroundStyle(heroTitleInk)
                    .multilineTextAlignment(textAlign)
                    .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
                    .lineSpacing(1)
                    .padding(.bottom, LumaSpacing.xs)
                    .contentTransition(.opacity)
            }
            if let artist, !artist.isEmpty {
                Group {
                    if let artistId = vm?.artistId, vm?.isOffline != true {
                        // A unique push (see `HomeDestination.artistPush`): an id-only `artistById` value that
                        // matches an artist already in the path makes NavigationStack reuse that entry — the
                        // album would be dropped from the stack and the back button would stop responding.
                        DetailNavigationLink(destination: HomeDestination.artistPush(
                            id: artistId,
                            name: artist,
                            coverArtId: nil,
                            token: artistRouteToken
                        )) {
                            Text(artist)
                                .font(.lumaAlbumArtist)
                                .foregroundStyle(heroTitleInk)
                                .lineLimit(1)
                                .contentTransition(.opacity)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(artist)
                            .font(.lumaAlbumArtist)
                            .foregroundStyle(heroTitleInk)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                .transition(.opacity)
                .padding(.bottom, LumaSpacing.s)
            } else {
                // Reserve the one-line artist slot so the action row stays put when
                // the server metadata arrives. The glyph is intentionally invisible.
                Text(" ")
                    .font(.lumaAlbumArtist)
                    .padding(.bottom, LumaSpacing.s)
                    .accessibilityHidden(true)
            }
            if let vm {
                let qualities = vm.audioQualities(for: songs)
                HStack(spacing: LumaSpacing.xs) {
                    if let genre = vm.genre, !genre.isEmpty {
                        Text(genre)
                    }
                    if let year = vm.year {
                        if vm.genre?.isEmpty == false { Text("·") }
                        Text(ReleaseDateFormatting.yearLabel(year))
                    }
                    ForEach(qualities.indices, id: \.self) { index in
                        if index > 0 || vm.year != nil || (vm.genre?.isEmpty == false) {
                            Text("·")
                        }
                        AudioQualityLabelView(
                            quality: qualities[index],
                            foreground: artworkStyle == .faded ? albumMetadataInk : headerTextColor,
                            interactive: false,
                            style: .album
                        )
                    }
                }
                .font(.lumaFootnote)
                .foregroundStyle(albumMetadataInk)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .task(id: vm.atmosAlternativeIDs(for: songs)) {
                    await vm.refreshLocalAtmosAvailability(for: songs)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: artist)
    }

    func albumActionBar(
        vm: AlbumDetailViewModel?,
        songs: [DisplayableSong],
        playMaxWidth: CGFloat?
    ) -> some View {
        HStack(spacing: LumaSpacing.m) {
            Button {
                HapticFeedback.medium.trigger()
                Task {
                    guard !songs.isEmpty else { return }
                    try? await container?.playerService.play(tracks: songs.shuffled(), startIndex: 0)
                }
            } label: {
                Image(systemName: "shuffle")
                    .font(.lumaCellTitle)
                    .foregroundStyle(headerTextColor)
                    .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
            }
            .disabled(songs.isEmpty)
            .opacity(vm == nil ? 0.4 : 1)

            PlayButton(action: {
                Task {
                    guard !songs.isEmpty else { return }
                    try? await container?.playerService.play(tracks: songs, startIndex: 0)
                }
            }, label: String(localized: "Play", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), isDisabled: songs.isEmpty || (mode == .full && vm?.isDownloadingAlbum == true), accentColor: heroButtonVariant.background, height: usesDesktopDetail ? nil : albumControlSide, labelColor: heroButtonVariant.foreground)
            .frame(maxWidth: playMaxWidth)

            if mode == .downloadedOnly {
                Button {
                    HapticFeedback.heavy.trigger()
                    let sid = container?.serverState.activeServer?.id ?? UUID()
                    let tracks = downloadedAlbumTracks
                    Task {
                        for track in tracks {
                            try? await container?.downloadService.remove(songId: track.songId, serverId: sid)
                        }
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.lumaCellTitle)
                        .foregroundStyle(headerTextColor)
                        .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
                }
            } else if vm?.isOffline != true {
                if let vm {
                    if vm.isDownloadingAlbum {
                        Button { Task { await vm.cancelAlbumDownload() } } label: {
                            Image(systemName: "xmark")
                                .font(.lumaCellTitle)
                                .foregroundStyle(headerTextColor)
                                .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
                        }
                    } else {
                        switch downloadState(for: vm) {
                        case .notDownloaded:
                            Button { Task { await vm.downloadAlbum() } } label: {
                                Image(systemName: "arrow.down")
                                    .font(.lumaCellTitle)
                                    .foregroundStyle(headerTextColor)
                                    .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
                            }
                            .disabled(vm.songs.isEmpty)
                        case .partiallyDownloaded:
                            Button { Task { await vm.downloadMissingTracks() } } label: {
                                Image(systemName: "arrow.down")
                                    .font(.lumaCellTitle)
                                    .foregroundStyle(headerTextColor)
                                    .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
                            }
                        case .fullyDownloaded:
                            Button {
                                HapticFeedback.heavy.trigger()
                                showDeleteAlert = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.lumaCellTitle)
                                    .foregroundStyle(headerTextColor)
                                    .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
                            }
                        }
                    }
                } else {
                    Button { } label: {
                        Image(systemName: "arrow.down")
                            .font(.lumaCellTitle)
                            .foregroundStyle(headerTextColor)
                            .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
                    }
                    .disabled(true)
                    .opacity(0.4)
                }
            }
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    func albumDownloadProgress(vm: AlbumDetailViewModel?) -> some View {
        if mode == .full, let vm, vm.isDownloadingAlbum {
            let total = vm.songs.count
            let downloaded = downloadedCount
            VStack(spacing: LumaSpacing.xs) {
                if downloaded == 0 {
                    HStack(spacing: LumaSpacing.s) {
                        ProgressView().scaleEffect(0.8)
                        Text(String(localized: "Starting download…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            .font(.lumaCaption)
                            .foregroundStyle(headerSecondaryColor)
                    }
                } else {
                    ProgressView(value: Double(downloaded), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                        .tint(atmosphere.isThemed ? atmosphere.contentColor.opacity(0.9) : LumaColors.accentForeground(on: dominantColor))
                        .frame(maxWidth: 280)
                    Text(String(localized: "Downloading \(downloaded)/\(total) tracks", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.lumaCaption)
                        .foregroundStyle(headerSecondaryColor)
                }
            }
            .frame(minHeight: 44)
        }
    }
}

private extension View {
    func albumTransportCircle(ink: Color, side: CGFloat) -> some View {
        self
            .font(.lumaDetailTitle)
            .foregroundStyle(ink)
            .frame(width: side, height: side)
            .background(ink.opacity(0.12), in: Circle())
            .overlay(Circle().strokeBorder(ink.opacity(0.05), lineWidth: 1))
            .contentShape(Circle())
    }
}
