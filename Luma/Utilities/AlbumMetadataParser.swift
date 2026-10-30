import Foundation
import SwiftSonic

/// Pure album text normalization, independent of presentation and network lifetimes.
nonisolated enum AlbumMetadataParser {
    private static let copyrightExpression = try? NSRegularExpression(
        pattern: #"\[\[COPYRIGHT\]\]([\s\S]*?)\[\[/COPYRIGHT\]\]"#
    )

    /// Detects a copyright / phonogram marker (`℗`, `©`, `®`, or `copyright:`) among track
    /// comments. Many servers fold the ID3 `TCOP`/`TPUB` copyright text into the COMMENT field.
    ///
    /// Returns only the copyright block (the description portion is stripped) and picks the
    /// first track that carries one.
    nonisolated static func findTrackCopyright(_ comments: [String?]) -> String? {
        for raw in comments {
            if let copyright = splitComment(raw).copyright {
                return copyright
            }
        }
        return nil
    }

    /// Splits a single `comment` string into its copyright block and description.
    ///
    /// Two forms are supported:
    /// 1. An explicit `[[COPYRIGHT]]…[[/COPYRIGHT]]` block — matched with a single regex pass and
    ///    treated as authoritative. Everything outside the block (markers removed) becomes the
    ///    description, so the copyright never leaks into the About text.
    /// 2. A legacy heuristic fallback for comments that carry ID3 `TCOP`/`TPUB` text as plain
    ///    lines: a line opening a copyright block (phonogram/copyright marker) starts the block,
    ///    which continues until a blank line.
    nonisolated static func splitComment(_ raw: String?) -> (copyright: String?, description: String?) {
        guard let raw else { return (nil, nil) }

        let (markedCopyright, withoutMarkers) = extractMarkedCopyright(from: raw)
        if let withoutMarkers {
            let description = compactDescription(withoutMarkers.components(separatedBy: .newlines))
            return (markedCopyright, description)
        }

        let lines = raw.components(separatedBy: .newlines)
        var blocks: [[String]] = []
        var descriptionLines: [String] = []
        var currentBlock: [String]?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentBlock != nil {
                if trimmed.isEmpty {
                    blocks.append(currentBlock!)
                    currentBlock = nil
                } else {
                    currentBlock!.append(line)
                }
            } else if isCopyrightLine(trimmed) {
                currentBlock = [line]
            } else {
                descriptionLines.append(line)
            }
        }
        if let currentBlock {
            blocks.append(currentBlock)
        }

        let copyright = blocks.first.flatMap { joinedBlock($0) }
        let description = compactDescription(descriptionLines)
        return (copyright, description)
    }

    /// Extracts an explicit `[[COPYRIGHT]]…[[/COPYRIGHT]]` block from a comment.
    ///
    /// The first block's inner text is the copyright; every such block is removed from the
    /// returned `withoutMarkers` text. Returns `(nil, nil)` when no marker block is present so
    /// callers can distinguish "no markers" from "markers present but empty body".
    nonisolated private static func extractMarkedCopyright(
        from raw: String
    ) -> (copyright: String?, withoutMarkers: String?) {
        guard let regex = copyrightExpression else { return (nil, nil) }
        let range = NSRange(raw.startIndex..., in: raw)
        let matches = regex.matches(in: raw, range: range)
        guard !matches.isEmpty else { return (nil, nil) }

        let copyright: String?
        if let first = matches.first, let bodyRange = Range(first.range(at: 1), in: raw) {
            let trimmed = String(raw[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            copyright = trimmed.isEmpty ? nil : trimmed
        } else {
            copyright = nil
        }

        let withoutMarkers = regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
        return (copyright, withoutMarkers)
    }

    /// A line opens a copyright block when it contains a phonogram/copyright symbol or starts
    /// with a copyright marker word such as `copyright`, `(p)`, or `p `.
    nonisolated private static func isCopyrightLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let symbols = ["℗", "©", "®"]
        if symbols.contains(where: line.contains) { return true }
        let lowered = line.lowercased()
        return lowered.hasPrefix("copyright")
            || lowered.hasPrefix("(p)")
            || lowered.hasPrefix("p ")
            || lowered.hasPrefix("(c)")
            || lowered.hasPrefix("c ")
    }

    /// Joins a copyright block, preserving original newlines exactly as carried in the tag.
    nonisolated private static func joinedBlock(_ lines: [String]) -> String? {
        let text = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Joins description lines, dropping surrounding whitespace and collapsing stray blank lines.
    nonisolated private static func compactDescription(_ lines: [String]) -> String? {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = trimmed.firstIndex(where: { !$0.isEmpty }),
              let last = trimmed.lastIndex(where: { !$0.isEmpty }) else { return nil }

        var out: [String] = []
        var collapsed = true
        for line in trimmed[first...last] {
            if line.isEmpty {
                if !collapsed {
                    out.append("")
                    collapsed = true
                }
            } else {
                out.append(line)
                collapsed = false
            }
        }
        return out.joined(separator: "\n")
    }

    /// Last.fm / server often return tiny placeholders that aren't useful About copy.
    nonisolated static func isStubDescription(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered == "n/a" || lowered == "na" || lowered == "none" || lowered == "null" {
            return true
        }
        // Fewer than ~2 short sentences — treat as stub and allow Wikipedia to replace.
        return text.count < 80
    }

    /// Prefer server notes, then a shared ID3 comment tag across tracks.
    nonisolated static func resolveAlbumDescription(infoNotes: String?, songs: [Song]) -> String? {
        if let fromInfo = plainTextDescription(from: infoNotes), !isStubDescription(fromInfo) {
            return fromInfo
        }
        if let fromComments = descriptionFromSongComments(songs) {
            return fromComments
        }
        return plainTextDescription(from: infoNotes)
    }

    /// When many tracks share the same COMMENT tag, treat it as the album About text.
    /// The copyright portion of each comment is stripped first so it never leaks into the
    /// description block (it is shown in the footer instead).
    nonisolated static func descriptionFromSongComments(_ songs: [Song]) -> String? {
        var counts: [String: Int] = [:]
        for song in songs {
            guard let splitDescription = splitComment(song.comment).description,
                  let plain = plainTextDescription(from: splitDescription),
                  !plain.isEmpty,
                  !isTechnicalComment(plain) else { continue }
            counts[plain, default: 0] += 1
        }
        guard let best = counts.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.count < rhs.key.count
        }) else { return nil }

        // Accept shared comments, or any single descriptive COMMENT tag (≥20 chars).
        let majority = best.value * 2 >= max(songs.count, 1) || best.value >= 2
        let descriptive = best.key.count >= 20
        guard majority || descriptive else { return nil }
        return best.key
    }

    nonisolated private static func isTechnicalComment(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let technical = [
            "dolby atmos", "dolby audio", "temporal", "joc", "explicit",
            "itunes_cddb", "encoded by", "ripped by", "track ",
        ]
        if technical.contains(where: { lowered.contains($0) }) && text.count < 80 {
            return true
        }
        return isStubDescription(text) && text.count < 24
    }

    /// Last.fm / OpenSubsonic notes often arrive as HTML — strip tags for display.
    nonisolated static func plainTextDescription(from raw: String?) -> String? {
        guard let raw else { return nil }
        var text = raw
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</p\s*>"#, with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

}
