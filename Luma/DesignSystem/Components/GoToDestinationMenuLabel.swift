// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// SwiftUI renders the icon, title and separate subtitle as a system menu item.
struct DestinationMenuLabel: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    @ViewBuilder
    var body: some View {
        Label(title, systemImage: systemImage)
        if let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            Text(verbatim: subtitle)
        }
    }

    static func playNext(after currentTitle: String?) -> Self {
        let bundle = AppUILanguage.localizationBundle
        let locale = AppUILanguage.locale
        let subtitle: String
        if let title = currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            subtitle = String(format: String(localized: "After “%@”", bundle: bundle, locale: locale), locale: locale, title)
        } else {
            subtitle = String(localized: "Next in the queue", bundle: bundle, locale: locale)
        }
        return Self(title: String(localized: "Play Next", bundle: bundle, locale: locale),
                    subtitle: subtitle, systemImage: "text.line.first.and.arrowtriangle.forward")
    }

    static func addToQueue(systemImage: String = "text.append") -> Self {
        Self(
            title: String(localized: "Add to Queue", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            subtitle: String(localized: "At the end of your queue", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            systemImage: systemImage
        )
    }

    static func addToPlaylist(systemImage: String = "music.note.list") -> Self {
        Self(
            title: String(localized: "Add to Playlist…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            subtitle: String(localized: "Choose a playlist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            systemImage: systemImage
        )
    }
}
