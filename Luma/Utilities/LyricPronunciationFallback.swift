// Luma — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.

import Foundation
import CoreFoundation

/// Offline, display-only fallback. Never writes provider data or invents timings.
nonisolated enum LyricPronunciationFallback {
    static func text(_ source: String, language: String?) -> String? {
        guard source.utf16.count < 4096 else { return nil }
        let scalars = source.unicodeScalars
        let kana = scalars.contains { (0x3040...0x30FF).contains($0.value) }
        let hangul = scalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }
        let han = scalars.contains { (0x3400...0x9FFF).contains($0.value) }
        guard kana || hangul || han else { return nil }
        let japanese = kana || language?.lowercased().hasPrefix("ja") == true
        let output: String
        if japanese {
            // Word-boundary tokenization retains punctuation and whitespace. The
            // Japanese tokenizer supplies readings for kanji; Any-Latin alone
            // would incorrectly give Chinese readings for those characters.
            let string = source as NSString
            let tokenizer = CFStringTokenizerCreate(nil, source as CFString,
                CFRange(location: 0, length: string.length),
                kCFStringTokenizerUnitWordBoundary | kCFStringTokenizerAttributeLatinTranscription,
                CFLocaleCreate(nil, CFLocaleIdentifier(rawValue: "ja" as CFString)))
            var result = ""
            var cursor = 0
            while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
                let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                guard range.location >= cursor, range.length > 0 else { continue }
                result += string.substring(with: NSRange(location: cursor, length: range.location - cursor))
                let original = string.substring(with: NSRange(location: range.location, length: range.length))
                let reading = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer,
                    kCFStringTokenizerAttributeLatinTranscription) as? String
                result += reading ?? original
                cursor = range.location + range.length
            }
            result += string.substring(from: cursor)
            output = result
        } else {
            output = source.applyingTransform(.toLatin, reverse: false) ?? source
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != source.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return trimmed
    }
}
