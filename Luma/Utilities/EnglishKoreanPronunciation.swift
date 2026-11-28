// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Offline English → Korean phonetic transliteration for the pronunciation row.
///
/// This is deliberately a pronunciation aid, not a translation: it uses the CMU
/// Pronouncing Dictionary's ARPAbet entries and maps the phones to Hangul. Words
/// that are not in the dictionary are left untouched so a name or slang word never
/// turns into an unrelated Korean word. The result is display-only and is never
/// written back to the server.
nonisolated enum EnglishKoreanPronunciation {
    /// Words pronounced with a dedicated Korean spelling rather than the default
    /// phone mapping. These are function words whose unstressed vowel is not
    /// predictable from ARPAbet alone (`the` is `DH AH0` but reads as "더").
    private static let overrides: [String: String] = [
        "the": "더",
        "a": "어",
        "an": "어",
        "of": "어브",
        "to": "투",
        "do": "두",
        "does": "더즈",
        "was": "워즈",
        "were": "워",
        "are": "아",
        "from": "프롬",
        "for": "포",
        "or": "오어",
        "your": "유어",
        "our": "아워",
        "their": "데어",
        "there": "데어",
        "they're": "데어",
        "where": "웨어",
        "what": "왓",
        "want": "원트",
        "water": "워터",
        "work": "워크",
        "word": "워드",
        "world": "월드",
        "would": "우드",
        "could": "쿠드",
        "should": "슈드",
        "you're": "유어",
        "we're": "위어",
        "i've": "아이브",
        "i'll": "아일",
        "i'd": "아이드",
        "don't": "돈트",
        "can't": "캔트",
        "won't": "원트",
        "isn't": "이즌트",
        "hello": "헬로",
        "yeah": "예",
        "hey": "헤이",
        "oh": "오",
        "whoa": "워",
    ]

    private static let vowels: Set<String> = [
        "IY", "IH", "EH", "AE", "AA", "AO", "OW", "UH", "UW", "ER", "AH",
    ]

    private static let vowelJamo: [String: Character] = [
        "IY": "ㅣ", "IH": "ㅣ", "EH": "ㅔ", "AE": "ㅐ", "AA": "ㅏ",
        "AO": "ㅗ", "OW": "ㅗ", "UH": "ㅜ", "UW": "ㅜ", "ER": "ㅓ",
    ]

    private static let onsetJamo: [String: Character] = [
        "P": "ㅍ", "B": "ㅂ", "T": "ㅌ", "D": "ㄷ", "K": "ㅋ", "G": "ㄱ",
        "F": "ㅍ", "V": "ㅂ", "TH": "ㅅ", "DH": "ㄷ", "S": "ㅅ", "Z": "ㅈ",
        "SH": "ㅅ", "ZH": "ㅈ", "CH": "ㅊ", "JH": "ㅈ", "M": "ㅁ", "N": "ㄴ",
        "L": "ㄹ", "R": "ㄹ", "HH": "ㅎ",
    ]

    /// Korean syllable-final indices. The trailing consonant is a single final
    /// where Korean allows it; fricatives that would otherwise disappear are
    /// emitted as a separate `ㅡ` syllable by `hangul(for:)`.
    private static let codaFinal: [String: Int] = [
        "P": 17, "B": 17, "T": 19, "D": 7, "K": 1, "G": 1, "F": 17,
        "V": 17, "TH": 19, "DH": 7, "S": 19, "Z": 22, "SH": 19, "ZH": 22,
        "CH": 23, "JH": 22, "M": 16, "N": 4, "NG": 21, "L": 8,
    ]

    private static let initialIndex: [Character: Int] = [
        "ㄱ": 0, "ㄲ": 1, "ㄴ": 2, "ㄷ": 3, "ㄸ": 4, "ㄹ": 5, "ㅁ": 6,
        "ㅂ": 7, "ㅃ": 8, "ㅅ": 9, "ㅆ": 10, "ㅇ": 11, "ㅈ": 12, "ㅉ": 13,
        "ㅊ": 14, "ㅋ": 15, "ㅌ": 16, "ㅍ": 17, "ㅎ": 18,
    ]

    private static let medialIndex: [Character: Int] = [
        "ㅏ": 0, "ㅐ": 1, "ㅑ": 2, "ㅒ": 3, "ㅓ": 4, "ㅔ": 5, "ㅕ": 6,
        "ㅖ": 7, "ㅗ": 8, "ㅘ": 9, "ㅙ": 10, "ㅚ": 11, "ㅛ": 12, "ㅜ": 13,
        "ㅝ": 14, "ㅞ": 15, "ㅟ": 16, "ㅠ": 17, "ㅡ": 18, "ㅢ": 19, "ㅣ": 20,
    ]

    private final class BundleToken: NSObject {}

    /// `word -> space-separated ARPAbet phones`. The dictionary is immutable and
    /// loaded once; `seedOriginalLyrics` calls this from its detached build task.
    private static let dictionary: [String: String] = loadDictionary()

    /// Returns a Hangul pronunciation line for English text, or `nil` when no
    /// word could be pronounced. Punctuation and unknown words are preserved.
    static func transliterate(_ text: String) -> String? {
        var output = ""
        var buffer = ""
        var changed = false

        func flush() {
            guard !buffer.isEmpty else { return }
            if let hangul = hangul(for: buffer), !hangul.isEmpty {
                output += hangul
                changed = true
            } else {
                output += buffer
            }
            buffer = ""
        }

        for character in text {
            if isWordCharacter(character) {
                buffer.append(character)
            } else {
                flush()
                output.append(character)
            }
        }
        flush()

        return changed ? output : nil
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) {
            return true
        }
        return character == "'" || character == "’"
    }

    private static func loadDictionary() -> [String: String] {
        let bundles = [Bundle.main, Bundle(for: BundleToken.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: "cmudict", withExtension: "txt")
                ?? bundle.url(forResource: "cmudict", withExtension: "txt", subdirectory: "Pronunciation")
                ?? bundle.url(forResource: "cmudict", withExtension: "dict")
                ?? bundle.url(forResource: "cmudict", withExtension: "dict", subdirectory: "Pronunciation"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                return parseDictionary(text)
            }
        }
        return [:]
    }

    private static func parseDictionary(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(140_000)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(where: \.isWhitespace) else { continue }
            var word = String(line[..<separator]).lowercased()
            if let alternate = word.firstIndex(of: "(") {
                word = String(word[..<alternate])
            }
            guard !word.isEmpty, result[word] == nil else { continue }
            let phones = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !phones.isEmpty { result[word] = phones }
        }
        return result
    }

    private static func base(_ phone: String) -> String {
        guard let last = phone.last, last.isNumber else { return phone }
        return String(phone.dropLast())
    }

    private static func stress(_ phone: String) -> Int {
        guard let last = phone.last, let value = last.wholeNumberValue,
              (0...2).contains(value) else { return 0 }
        return value
    }

    private static func isVowel(_ phone: String) -> Bool {
        vowels.contains(base(phone))
    }

    private static func jamo(forVowel phone: String) -> Character {
        if base(phone) == "AH" {
            return stress(phone) == 0 ? "ㅡ" : "ㅓ"
        }
        return vowelJamo[base(phone)] ?? "ㅡ"
    }

    /// ARPAbet diphthongs become two Korean vowels. `OW` stays a single ㅗ so
    /// "go"/"know" read as 고/노 rather than 고우/노우.
    private static func expanded(_ phones: [String]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(phones.count + 2)
        for phone in phones {
            switch base(phone) {
            case "AY": result += ["AA1", "IY1"]
            case "AW": result += ["AA1", "UH1"]
            case "OY": result += ["AO1", "IY1"]
            case "EY": result += ["EH1", "IY1"]
            case "OW": result.append("AO1")
            default: result.append(phone)
            }
        }
        return result
    }

    private static func syllable(
        initial: Character,
        medial: Character,
        final: Int = 0
    ) -> Character {
        let initialValue = initialIndex[initial] ?? 11
        let medialValue = medialIndex[medial] ?? 18
        let scalar = UnicodeScalar(0xAC00 + (initialValue * 21 + medialValue) * 28 + final)!
        return Character(scalar)
    }

    private static func bareSyllable(_ phone: String) -> String {
        guard let jamo = onsetJamo[base(phone)] else { return "" }
        return String(syllable(initial: jamo, medial: "ㅡ"))
    }

    private static func hangul(for word: String) -> String? {
        let key = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if let override = overrides[key] { return override }
        guard let raw = dictionary[key] else { return nil }

        let phones = expanded(raw.split(separator: " ").map(String.init))
        let vowelIndices = phones.indices.filter { isVowel(phones[$0]) }
        guard !vowelIndices.isEmpty else { return nil }

        var result = ""
        for (position, index) in vowelIndices.enumerated() {
            let previous = position > 0 ? vowelIndices[position - 1] : -1
            let next = position + 1 < vowelIndices.count ? vowelIndices[position + 1] : phones.count
            let onset = Array(phones[(previous + 1)..<index])
            var coda = Array(phones[(index + 1)..<next])

            // A single consonant between vowels belongs to the next syllable:
            // "hidden" is 히 + 든, not 힛 + 던.
            if position + 1 < vowelIndices.count, !coda.isEmpty {
                coda.removeLast()
            }

            var initial: Character = "ㅇ"
            var glide: String?
            if let last = onset.last, ["W", "Y"].contains(base(last)) {
                glide = base(last)
                if onset.count >= 2 {
                    for consonant in onset.dropLast(2) {
                        result += bareSyllable(consonant)
                    }
                    initial = onsetJamo[base(onset[onset.count - 2])] ?? "ㅇ"
                }
            } else if !onset.isEmpty {
                for consonant in onset.dropLast() {
                    result += bareSyllable(consonant)
                }
                initial = onsetJamo[base(onset.last!)] ?? "ㅇ"
            }

            var medial = jamo(forVowel: phones[index])
            if let glide {
                switch (glide, medial) {
                case ("W", "ㅣ"): initial = "ㅇ"; medial = "ㅟ"
                case ("W", "ㅔ"): initial = "ㅇ"; medial = "ㅞ"
                case ("W", "ㅐ"): initial = "ㅇ"; medial = "ㅙ"
                case ("W", "ㅏ"): initial = "ㅇ"; medial = "ㅘ"
                case ("W", "ㅓ"), ("W", "ㅗ"): initial = "ㅇ"; medial = "ㅝ"
                case ("W", "ㅜ"): initial = "ㅇ"; medial = "ㅜ"
                case ("Y", "ㅜ"): initial = "ㅇ"; medial = "ㅠ"
                case ("Y", "ㅓ"): initial = "ㅇ"; medial = "ㅕ"
                case ("Y", "ㅔ"): initial = "ㅇ"; medial = "ㅖ"
                case ("Y", "ㅏ"): initial = "ㅇ"; medial = "ㅑ"
                case ("Y", "ㅗ"): initial = "ㅇ"; medial = "ㅛ"
                case ("Y", "ㅣ"): initial = "ㅇ"; medial = "ㅣ"
                default: medial = "ㅕ"
                }
            }
            if base(phones[index]) == "AA", let first = coda.first,
               ["N", "NG"].contains(base(first)) {
                medial = "ㅗ"
            }

            func appendMain(final: Int = 0) {
                result.append(syllable(initial: initial, medial: medial, final: final))
            }

            if coda.isEmpty {
                appendMain()
                continue
            }

            let codas = coda.map(base)
            // Korean renders "just" as 저스트, not 젓트.
            if codas.count == 2, codas == ["S", "T"] {
                appendMain()
                result += String(syllable(initial: "ㅅ", medial: "ㅡ"))
                result += String(syllable(initial: "ㅌ", medial: "ㅡ"))
                continue
            }

            let first = codas[0]
            if first == "R" {
                appendMain()
                result += String(syllable(initial: "ㅇ", medial: "ㅓ"))
            } else if ["Z", "D", "S", "CH", "JH", "F"].contains(first) {
                appendMain()
                switch first {
                case "Z": result += String(syllable(initial: "ㅈ", medial: "ㅡ"))
                case "D": result += String(syllable(initial: "ㄷ", medial: "ㅡ"))
                case "S": result += String(syllable(initial: "ㅅ", medial: "ㅡ"))
                case "CH": result += String(syllable(initial: "ㅊ", medial: "ㅣ"))
                case "JH": result += String(syllable(initial: "ㅈ", medial: "ㅣ"))
                case "F": result += String(syllable(initial: "ㅍ", medial: "ㅡ"))
                default: break
                }
            } else {
                appendMain(final: codaFinal[first] ?? 0)
            }

            for consonant in codas.dropFirst() {
                result += bareSyllable(consonant)
            }
        }
        return result
    }
}
