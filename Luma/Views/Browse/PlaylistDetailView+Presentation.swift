// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import SwiftData
import OSLog
#if os(iOS)
import UniformTypeIdentifiers
#endif

extension PlaylistDetailView {
    // MARK: - Color loading

    func loadDominantColor(coverArtId: String) async {
        guard !presentationSuspended else { return }
        guard let image = await container?.artworkImageCache.load(coverArtId: coverArtId, tier: .hero) else { return }
        guard !presentationSuspended, !Task.isCancelled else { return }
        let packed = await Task.detached(priority: .utility) {
            DominantColorExtractor.packedAverageColor(from: image)
        }.value
        guard !presentationSuspended, !Task.isCancelled else { return }
        let color = colorExtractor.storeColor(packed: packed, for: coverArtId)
        withAnimation(LumaAnimation.theme) {
            dominantColor = color
        }
    }

    // MARK: - Download state helpers

    func downloadState(for vm: PlaylistDetailViewModel) -> PlaylistDownloadState {
        let total = vm.songs.count
        guard total > 0 else { return .notDownloaded }
        let downloaded = vm.songs.filter { $0.isDownloaded }.count
        if downloaded == 0 { return .notDownloaded }
        if downloaded == total { return .fullyDownloaded }
        return .partiallyDownloaded(downloaded: downloaded, total: total)
    }
}
