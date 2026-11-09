// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Local, server-free filtering shared by the Siri catalog and the metadata
/// store. The optional fields are intentionally independent so callers can
/// combine “1987 FLAC” or “Pop by Michael Jackson” without a full-library fetch.
nonisolated struct LibrarySongQuery: Sendable {
    let text: String?
    let genre: String?
    let year: Int?
    let audioFormat: String?

    init(text: String? = nil, genre: String? = nil, year: Int? = nil, audioFormat: String? = nil) {
        self.text = Self.trimmed(text)
        self.genre = Self.trimmed(genre)
        self.year = year
        self.audioFormat = Self.normalizedFormat(audioFormat)
    }

    var hasCriteria: Bool {
        text != nil || genre != nil || year != nil || audioFormat != nil
    }

    func matches(_ song: DisplayableSong) -> Bool {
        if let text, !Self.contains(text, in: song.title) {
            let artist = song.artist ?? ""
            let album = song.albumName ?? ""
            let genreText = song.genre ?? ""
            guard Self.contains(text, in: artist) || Self.contains(text, in: album) || Self.contains(text, in: genreText) else {
                return false
            }
        }
        if let genre {
            let value = song.genre ?? ""
            guard !value.isEmpty,
                  Self.contains(genre, in: value) || Self.contains(value, in: genre) else { return false }
        }
        if let year, song.year != year { return false }
        if let audioFormat, !Self.formatMatches(audioFormat, song: song) { return false }
        return true
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func contains(_ needle: String, in haystack: String) -> Bool {
        guard !haystack.isEmpty else { return false }
        return haystack.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        ) != nil
    }

    private static func normalizedFormat(_ value: String?) -> String? {
        guard var value = trimmed(value)?.lowercased() else { return nil }
        if value.hasPrefix(".") { value.removeFirst() }
        switch value {
        case "무손실", "lossless": return "lossless"
        default: return value
        }
    }

    private static func formatMatches(_ requested: String, song: DisplayableSong) -> Bool {
        let suffix = song.audioFormat?.lowercased() ?? ""
        let mime = song.contentType?.lowercased() ?? ""
        if requested == "lossless" {
            return ["flac", "alac", "wav", "aiff", "aif", "dsf", "dff"].contains(suffix)
        }
        if suffix == requested { return true }
        // MIME subtypes cover entries whose server did not provide a suffix.
        return mime == "audio/\(requested)" || mime.hasSuffix("+\(requested)")
    }
}
