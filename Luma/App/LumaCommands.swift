// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI

struct LumaCommands: Commands {
    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play / Pause") {
                NotificationCenter.default.post(name: .lumaTogglePlayPause, object: nil)
            }
            .keyboardShortcut(.space, modifiers: [])

            Divider()

            Button("Next Track") {
                NotificationCenter.default.post(name: .lumaSkipNext, object: nil)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Button("Previous Track") {
                NotificationCenter.default.post(name: .lumaSkipPrevious, object: nil)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Divider()

            Button("Toggle Shuffle") {
                NotificationCenter.default.post(name: .lumaToggleShuffle, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Toggle Repeat") {
                NotificationCenter.default.post(name: .lumaToggleRepeat, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Show Queue") {
                NotificationCenter.default.post(name: .lumaToggleQueue, object: nil)
            }
            .keyboardShortcut("e", modifiers: .command)

            Button("Show Lyrics") {
                NotificationCenter.default.post(name: .lumaOpenFullPlayerLyrics, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button("Search") {
                NotificationCenter.default.post(name: .lumaFocusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}
#endif
