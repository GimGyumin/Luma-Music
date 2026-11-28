// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Testing
@testable import Luma

@Suite("EnglishKoreanPronunciation")
struct EnglishKoreanPronunciationTests {
    @Test("matches the reference pronunciation lines")
    func referenceLines() {
        #expect(EnglishKoreanPronunciation.transliterate("Is that you,") == "이즈 댓 유,")
        #expect(EnglishKoreanPronunciation.transliterate("hidden in the") == "히든 인 더")
        #expect(EnglishKoreanPronunciation.transliterate("breeze?") == "브리즈?")
        #expect(EnglishKoreanPronunciation.transliterate("Can you hear") == "캔 유 히어")
        #expect(EnglishKoreanPronunciation.transliterate("me? I'm on my") == "미? 아임 온 마이")
        #expect(EnglishKoreanPronunciation.transliterate("knees") == "니즈")
        #expect(EnglishKoreanPronunciation.transliterate("Can we just talk") == "캔 위 저스트 톡")
    }

    @Test("keeps punctuation and unknown words")
    func punctuationAndUnknownWords() {
        #expect(EnglishKoreanPronunciation.transliterate("Is that you?!") == "이즈 댓 유?!")
        #expect(EnglishKoreanPronunciation.transliterate("...") == nil)
        #expect(EnglishKoreanPronunciation.transliterate("zzzz") == nil)
    }

    @Test("English fallback is gated by the caller")
    func fallbackGate() {
        #expect(LyricPronunciationFallback.text("Is that you,", language: "en", allowEnglish: false) == nil)
        #expect(LyricPronunciationFallback.text("Is that you,", language: "en", allowEnglish: true) == "이즈 댓 유,")
    }
}
