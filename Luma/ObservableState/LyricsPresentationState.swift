// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Presentation-only lyric layer visibility that outlives a single
/// `FullPlayerView` instance.
///
/// `LyricsViewModel` is created when the full player appears and discarded when
/// it is dismissed. Translation and pronunciation visibility are user choices,
/// not song metadata, so closing the player must not silently reset them.
/// This state is process-scoped: it does not override the user's persisted
/// translation settings or per-song lyrics data.
@MainActor
final class LyricsPresentationState {
    var areTranslationsVisible = false
    var arePronunciationsVisible = false
}
