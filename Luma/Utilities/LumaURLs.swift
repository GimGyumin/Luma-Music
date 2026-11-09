// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

nonisolated enum LumaURLs {
    static let audioStreaming = URL(string: "https://github.com/dimitris-c/AudioStreaming")!
    static let listenBrainz = URL(string: "https://listenbrainz.org")!

    // Official Luma Music project endpoints. Guides are fetched only from this repository.
    static let repository = URL(string: "https://github.com/GimGyumin/Luma-Music")!
    static let issues = URL(string: "https://github.com/GimGyumin/Luma-Music/issues")!

    static func newIssue(title: String, body: String) -> URL? {
        var components = URLComponents(string: "https://github.com/GimGyumin/Luma-Music/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body)
        ]
        return components?.url
    }

    static func guideHTML(language: String, id: String) -> URL? {
        URL(string: "https://github.com/GimGyumin/Luma-Music/blob/main/docs/guides/\(language)/\(id).md")
    }

    static func guideRaw(language: String, id: String) -> URL? {
        URL(string: "https://raw.githubusercontent.com/GimGyumin/Luma-Music/main/docs/guides/\(language)/\(id).md")
    }

    static func isTrustedGitHubURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "www.github.com" || host == "raw.githubusercontent.com"
    }
}

