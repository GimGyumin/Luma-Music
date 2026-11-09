// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

extension AlbumDetailContentView {
    func resolveDominantColor(coverArtId: String) async {
        guard !Task.isCancelled, viewModel?.acceptsPresentationUpdates != false,
              albumCoverId == coverArtId else { return }
        let identity = paletteIdentity
        let changed = paletteRequestID != nil && paletteRequestID != identity
        paletteRequestID = identity
        artworkPreference = artworkImageCache.artworkPreference(for: albumId)
        // Preparation owns image decoding and edge analysis. The page reads a
        // finished snapshot when one is current. A palette from an older analyzer
        // version is rebuilt on demand, so a migration can update the page once.
        if let palette = artworkImageCache.preparedPalette(for: coverArtId),
           palette.edgeAnalysis?.isPreparedForCurrentPresentation == true,
           palette.isProvisional != true {
            applyAlbumPalette(palette, coverArtId: coverArtId)
            return
        }
        if changed {
            artworkAnalysis = nil
            dominantColor = .clear
        }
        if await AlbumCoverPreloadService.prepareTheme(
            for: coverArtId,
            artworkImageCache: artworkImageCache,
            dominantColorExtractor: colorExtractor, allowNetwork: isOnline
        ), !Task.isCancelled, viewModel?.acceptsPresentationUpdates != false,
           paletteIdentity == identity, albumCoverId == coverArtId,
           let palette = artworkImageCache.preparedPalette(for: coverArtId) {
            applyAlbumPalette(palette, coverArtId: coverArtId)
        }
    }

    private func applyAlbumPalette(_ palette: ArtworkPalette, coverArtId: String) {
        if coverArtId != albumId {
            artworkImageCache.storePreparedPalette(palette, for: albumId)
        }
        colorExtractor.storePreparedBackground(palette.packedBackground, for: coverArtId)
        // One state update gives artwork, canvas, ink, and controls a consistent decision.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dominantColor = colorExtractor.colorOverride(for: coverArtId) ?? palette.background
            artworkAnalysis = palette.edgeAnalysis
        }
    }

    func setArtworkPreference(_ preference: AlbumArtworkPreference) {
        artworkPreference = preference
        artworkImageCache.setArtworkPreference(preference, for: albumId)
    }
}
