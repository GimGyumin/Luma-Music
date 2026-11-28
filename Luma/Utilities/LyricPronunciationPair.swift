import Foundation
import SwiftUI

nonisolated enum LyricPronunciationSeparator: Equatable, Sendable {
    case joined, space, lineBreak
}

nonisolated struct LyricPronunciationSeparatorKey: LayoutValueKey {
    nonisolated static let defaultValue = LyricPronunciationSeparator.space
}

/// A source span and any provider-supplied reading spans that belong to its time interval.
nonisolated struct LyricPronunciationPair: Equatable, Sendable {
    let original: LyricDisplayWord
    let readings: [LyricDisplayWord]
    let separator: LyricPronunciationSeparator

    static func matching(original: [LyricDisplayWord], reading: [LyricDisplayWord]) -> [Self] {
        let original = original.filter { !$0.isBackground }
        let reading = reading.filter { !$0.isBackground && !$0.text.allSatisfy(\.isWhitespace) }
        guard !reading.isEmpty else { return [] }
        // Keep native paragraph shaping for bidirectional scripts.
        guard !original.contains(where: { word in
            word.text.unicodeScalars.contains {
                (0x0590...0x08FF).contains($0.value) || (0xFB1D...0xFEFF).contains($0.value)
            }
        }) else { return [] }

        let sourceTexts = LyricKaraokeSpacing.sourceTexts(original, secondary: false)
        var sources: [(word: LyricDisplayWord, separator: LyricPronunciationSeparator)] = []
        var separator = LyricPronunciationSeparator.joined
        for (word, text) in zip(original, sourceTexts) {
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let leading = text.prefix(while: \.isWhitespace)
            if leading.contains(where: \.isNewline) {
                separator = .lineBreak
            } else if !leading.isEmpty && separator == .joined {
                separator = .space
            }
            guard !trimmedText.isEmpty else { continue }
            if let previous = sources.last, separator != .lineBreak,
               previous.word.startMs == word.startMs, previous.word.endMs == word.endMs {
                let gap = separator == .space ? " " : ""
                sources[sources.count - 1].word = withText(previous.word, previous.word.text + gap + trimmedText)
            } else {
                sources.append((withText(word, trimmedText), separator))
            }
            let trailing = text.reversed().prefix(while: \.isWhitespace)
            separator = trailing.contains(where: \.isNewline) ? .lineBreak : (trailing.isEmpty ? .joined : .space)
        }
        guard !sources.isEmpty else { return [] }

        // A reading may be split into several syllables or have a slightly different
        // interval. Keep its own timings, and decline any ambiguous placement.
        let tolerance = 120
        var readings = Array(repeating: [LyricDisplayWord](), count: sources.count)
        var previousIndex = 0
        for word in reading {
            guard word.endMs > word.startMs else { return [] }
            var bestIndex: Int?
            var bestOverlap = 0
            for (index, source) in sources.enumerated() {
                let original = source.word
                guard original.endMs > original.startMs,
                      word.startMs >= original.startMs - tolerance,
                      word.endMs <= original.endMs + tolerance else { continue }
                let overlap = min(original.endMs, word.endMs) - max(original.startMs, word.startMs)
                if overlap > bestOverlap {
                    bestIndex = index
                    bestOverlap = overlap
                } else if overlap > 0 && overlap == bestOverlap {
                    bestIndex = nil
                }
            }
            guard let index = bestIndex, index >= previousIndex else { return [] }
            readings[index].append(word)
            previousIndex = index
        }

        return sources.enumerated().map { index, source in
            let words = readings[index]
            let normalized = words.enumerated().map { offset, word in
                var text = word.text
                if offset == 0 { text = String(text.drop(while: \.isWhitespace)) }
                if offset == words.count - 1 {
                    text = String(text.reversed().drop(while: \.isWhitespace).reversed())
                }
                return withText(word, text)
            }
            return Self(original: source.word, readings: normalized, separator: source.separator)
        }
    }

    private static func withText(_ word: LyricDisplayWord, _ text: String) -> LyricDisplayWord {
        LyricDisplayWord(text: text, startMs: word.startMs, endMs: word.endMs, role: word.role,
                         preservesSourceSpacing: true)
    }
}

/// Each column reserves the larger width of its original and reading. Wrapping
/// therefore keeps annotations directly below their actual source word.
struct LyricPronunciationLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    struct Cache {
        var ideal: [CGSize] = []
        var width: CGFloat?
        var frames: [CGRect] = []
        var size = CGSize.zero
    }
    func makeCache(subviews: Subviews) -> Cache {
        Cache(ideal: subviews.map { $0.sizeThatFits(.unspecified) })
    }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = makeCache(subviews: subviews) }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = max(1, proposal.width ?? cache.ideal.reduce(0) { $0 + $1.width + spacing })
        measure(width: width, subviews: subviews, cache: &cache)
        return cache.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(width: max(1, bounds.width), subviews: subviews, cache: &cache)
        for (view, frame) in zip(subviews, cache.frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
    private func measure(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard cache.width != width || cache.frames.count != subviews.count else { return }
        cache.width = width
        cache.frames.removeAll(keepingCapacity: true)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let cellWidth = min(width, cache.ideal[index].width)
            let size = view.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil))
            let separator = view[LyricPronunciationSeparatorKey.self]
            var gap: CGFloat = x > 0 && separator == .space ? spacing : 0
            if x > 0, separator == .lineBreak || x + gap + size.width > width {
                x = 0
                gap = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            cache.frames.append(CGRect(origin: CGPoint(x: x + gap, y: y), size: size))
            x += gap + size.width
            rowHeight = max(rowHeight, size.height)
        }
        cache.size = CGSize(width: width, height: y + rowHeight)
    }
}
