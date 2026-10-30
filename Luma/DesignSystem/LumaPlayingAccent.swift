// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

private struct LumaPlayingAccentKey: EnvironmentKey {
    // Falls back to the standard brand accent when no dominant background is available.
    static let defaultValue: Color = LumaColors.accent
}

extension EnvironmentValues {
    /// Accent color for currently-playing indicators (title, bars, active transport buttons).
    /// Parent views with a dominant background should override this with
    /// `LumaColors.accentForeground(on: dominantColor)` so child components
    /// automatically stay WCAG-contrast-safe without prop drilling.
    var lumaPlayingAccent: Color {
        get { self[LumaPlayingAccentKey.self] }
        set { self[LumaPlayingAccentKey.self] = newValue }
    }
}
