import Foundation
import SwiftUI

/// Only provider-linked word intervals can form reading columns. Whole-line
/// automatic transliteration must never be split by guessed spaces or phonemes.
nonisolated struct LyricPronunciationPair: Equatable {
    let original: LyricDisplayWord
    let reading: LyricDisplayWord

    static func matching(original: [LyricDisplayWord], reading: [LyricDisplayWord]) -> [Self] {
        let original = original.filter { !$0.isBackground && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let reading = reading.filter { !$0.isBackground && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard original.count > 1, original.count == reading.count else { return [] }
        // Connected scripts and unsegmented CJK retain the shaped paragraph path.
        guard original.allSatisfy({ word in word.text.unicodeScalars.allSatisfy {
            !$0.properties.isAlphabetic || $0.value <= 0x024F || (0x1E00...0x1EFF).contains($0.value)
        } }) else { return [] }
        var result: [Self] = []
        for (source, pronunciation) in zip(original, reading) {
            guard source.endMs > source.startMs, source.startMs == pronunciation.startMs,
                  source.endMs == pronunciation.endMs else { return [] }
            result.append(Self(original: source, reading: pronunciation))
        }
        return result
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
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + lineSpacing; rowHeight = 0
            }
            cache.frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        cache.size = CGSize(width: width, height: y + rowHeight)
    }
}
