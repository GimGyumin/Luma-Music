// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
@testable import Luma

@Suite("Library song query")
struct LibrarySongQueryTests {
    private func song(
        title: String = "Billie Jean",
        artist: String? = "Michael Jackson",
        album: String? = "Thriller",
        genre: String? = "Pop",
        year: Int? = 1982,
        format: String? = "FLAC"
    ) -> DisplayableSong {
        DisplayableSong(
            id: UUID().uuidString,
            title: title,
            artist: artist,
            albumName: album,
            genre: genre,
            year: year,
            audioFormat: format
        )
    }

    @Test("matches genre case-insensitively")
    func genreMatch() {
        let query = LibrarySongQuery(genre: "pop")
        #expect(query.matches(song(genre: "Pop/Rock")))
        #expect(!query.matches(song(genre: "Jazz")))
    }

    @Test("matches an exact release year")
    func yearMatch() {
        #expect(LibrarySongQuery(year: 1982).matches(song(year: 1982)))
        #expect(!LibrarySongQuery(year: 1983).matches(song(year: 1982)))
        #expect(!LibrarySongQuery(year: 1982).matches(song(year: nil)))
    }

    @Test("matches file suffixes and the lossless alias")
    func formatMatch() {
        #expect(LibrarySongQuery(audioFormat: ".flac").matches(song(format: "FLAC")))
        #expect(LibrarySongQuery(audioFormat: "mp3").matches(song(format: "MP3")))
        #expect(LibrarySongQuery(audioFormat: "lossless").matches(song(format: "FLAC")))
        #expect(!LibrarySongQuery(audioFormat: "mp3").matches(song(format: "FLAC")))
    }

    @Test("matches text across title, artist, and album")
    func textMatch() {
        let target = song()
        #expect(LibrarySongQuery(text: "billie").matches(target))
        #expect(LibrarySongQuery(text: "michael").matches(target))
        #expect(LibrarySongQuery(text: "thriller").matches(target))
        #expect(!LibrarySongQuery(text: "smooth criminal").matches(target))
    }

    @Test("combines independent criteria")
    func combinedCriteria() {
        let query = LibrarySongQuery(text: "michael", genre: "pop", year: 1982, audioFormat: "flac")
        #expect(query.matches(song()))
        #expect(!query.matches(song(year: 1987)))
        #expect(!query.matches(song(format: "MP3")))
    }
}
