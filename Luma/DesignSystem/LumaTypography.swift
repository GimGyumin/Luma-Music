// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

// MARK: - Typography tokens
//
// Design rules:
//   • SF Pro Rounded is used only for headings that need emphasis (player title, detail headers).
//     Body, cells, and captions stay in SF Pro Default to avoid a "kids app" feel.
//   • All sizes come from Dynamic Type styles — no hardcoded points — so they scale
//     with the user's accessibility text size setting.
//   • Font.weight is always set explicitly; never rely on the Dynamic Type default weight.

extension Font {
    // MARK: Headings (SF Pro Rounded)

    /// Full-player track title. ~28pt. Rounded, bold.
    static let lumaPlayerTitle = Font.system(.title, design: .rounded, weight: .bold)
    static let lumaImmersivePlayerTitle = Font.system(size: 20, weight: .semibold)
    static let lumaImmersivePlayerArtist = Font.system(size: 20, weight: .regular)

    /// Album or artist name in detail-screen headers. ~22pt. Rounded, semibold.
    static let lumaDetailTitle = Font.system(.title2, design: .rounded, weight: .semibold)
    static let lumaAlbumTitle = Font.system(.title, design: .default, weight: .bold)
    static let lumaFadedAlbumTitle = Font.system(.title2, design: .default, weight: .bold)
    static let lumaAlbumCardTitle = Font.system(.title2, design: .default, weight: .semibold)
    static let lumaAlbumArtist = Font.system(.title2, design: .default, weight: .regular)

    /// Section header labels (e.g. "Albums", "Tracks"). ~17pt. Rounded, semibold.
    static let lumaSectionTitle = Font.system(.headline, design: .rounded, weight: .semibold)

    // MARK: Body & cells (SF Pro Default)

    /// Standard readable body. ~17pt. Regular.
    static let lumaBody = Font.system(.body, design: .default, weight: .regular)

    static let lumaSettingsHeader = Font.system(.subheadline, design: .default, weight: .semibold)
    static let lumaFootnote = Font.system(.footnote, design: .default, weight: .regular)

    /// Primary label in list cells (track title, album name). ~16pt. Semibold.
    static let lumaCellTitle = Font.system(.callout, design: .default, weight: .semibold)

    /// Secondary label in cells (artist name below track title). ~15pt. Regular.
    static let lumaCellSubtitle = Font.system(.subheadline, design: .default, weight: .regular)

    /// Tertiary metadata (duration, year, genre). ~12pt. Regular.
    static let lumaCaption = Font.system(.caption, design: .default, weight: .regular)

    /// Very small labels (track count badge, etc.). ~11pt. Regular.
    static let lumaCaption2 = Font.system(.caption2, design: .default, weight: .regular)

    // MARK: Lyrics

    /// Lyric line text in the full-player lyrics view. ~28pt. Rounded, semibold.
    static let lumaLyricsLine = Font.system(.title, design: .rounded, weight: .semibold)
}
