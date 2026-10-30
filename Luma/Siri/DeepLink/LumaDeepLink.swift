// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Parses Luma's own `luma://` deep links into namespaced entity ids.
///
/// Shape: `luma://<kind>/<serverId>/<localId>`, where `<kind>` is one of
/// `song`, `album`, `artist`, or `playlist`. `AudioSearch.Criteria.url` hands
/// these URLs back when Siri resolves onscreen or shared content.
nonisolated enum LumaDeepLink {
    enum Kind: Sendable {
        case song
        case album
        case artist
        case playlist
    }

    static func parse(_ url: URL) -> (kind: Kind, id: LumaEntityID)? {
        guard url.scheme?.lowercased() == "luma" else { return nil }
        guard let host = url.host?.lowercased() else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil, components.fragment == nil else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/").compactMap { String($0).removingPercentEncoding }
        guard parts.count == 2, !parts[1].isEmpty, let serverId = UUID(uuidString: parts[0]) else { return nil }

        let id = LumaEntityID(serverId: serverId, localId: parts[1])
        switch host {
        case "song": return (.song, id)
        case "album": return (.album, id)
        case "artist": return (.artist, id)
        case "playlist": return (.playlist, id)
        default: return nil
        }
    }

    /// Builds the URL for an entity, used by onscreen awareness and sharing.
    static func url(kind: Kind, id: LumaEntityID) -> URL? {
        let raw: String
        switch kind {
        case .song: raw = "song"
        case .album: raw = "album"
        case .artist: raw = "artist"
        case .playlist: raw = "playlist"
        }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let local = id.localId.addingPercentEncoding(withAllowedCharacters: safe), !local.isEmpty else { return nil }
        return URL(string: "luma://\(raw)/\(id.serverId.uuidString)/\(local)")
    }
}
