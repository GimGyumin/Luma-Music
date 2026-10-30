// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// An artist in the Luma library.
///
/// `id` is `"{serverId}:{artistId}"` — see `LumaEntityID`. Artists that are
/// only known by name (for example an inline credit on a song) use the
/// lowercased name as their local id, matching Apple's own sample behavior.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.artist)
struct LumaArtistEntity: IndexedEntity {
    static let defaultQuery = LumaArtistQuery()

    // MARK: Schema properties

    var name: String

    // MARK: Entity properties

    let id: String

    var displayRepresentation: DisplayRepresentation {
        // NOTE: the installed SDK has no trailing-closure initializer for
        // DisplayRepresentation — the image is passed by label.
        DisplayRepresentation(
            title: "\(name)",
            image: DisplayRepresentation.Image(systemName: "music.microphone")
        )
    }
}

// MARK: - Equatable / Hashable

@available(iOS 27.0, macOS 27.0, *)
extension LumaArtistEntity: Equatable {
    static func == (lhs: LumaArtistEntity, rhs: LumaArtistEntity) -> Bool { lhs.id == rhs.id }
}

@available(iOS 27.0, macOS 27.0, *)
extension LumaArtistEntity: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
