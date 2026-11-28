// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Shared Apple-style motion tokens — prefer these over ad-hoc `easeInOut` / hard cuts.
enum LumaAnimation {
    /// Theme / dominant-color settles (album, artist, player).
    static let theme = Animation.spring(response: 0.45, dampingFraction: 0.86)

    /// Sheets, overlays, centered cards (alert-like).
    static let present = Animation.spring(response: 0.42, dampingFraction: 0.72)

    /// Overlay / card dismiss.
    static let dismiss = Animation.spring(response: 0.28, dampingFraction: 0.92)

    /// Player surface morph (lyrics ↔ queue ↔ cover).
    static let surface = Animation.smooth(duration: 0.32)

    /// Scrubber / chrome show-hide.
    static let chrome = Animation.smooth(duration: 0.28)

    /// Compact interactive feedback (toggles, pills).
    static let interactive = Animation.snappy(duration: 0.22)

    /// Auto-scroll to the playing lyric. A non-overshooting curve keeps the viewport
    /// synchronized with the line-emphasis handoff when consecutive cues are close.
    static let lyricScroll = Animation.smooth(duration: 0.38)

    /// Reduce-motion fallbacks.
    static func present(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2) : present
    }

    static func dismiss(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeIn(duration: 0.15) : dismiss
    }
}
