import Foundation

nonisolated enum LyricEmphasisTiming {
    struct Entry: Equatable, Sendable { let index: Int; let start: Int; let end: Int }

    static func entries(rows: [LyricDisplayRow]) -> [Entry] {
        let ordered = rows.indices.filter {
            rows[$0].startMs != nil && !rows[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { rows[$0].startMs! == rows[$1].startMs! ? $0 < $1 : rows[$0].startMs! < rows[$1].startMs! }
        return ordered.compactMap { index in
            let row = rows[index]
            guard let start = row.startMs else { return nil }
            let next = ordered.first { candidate in
                let other = rows[candidate]
                return !other.isSecondaryAgent && other.streamKey == row.streamKey && other.startMs! > start
            }.flatMap { rows[$0].startMs }
            let sourceEnd = row.endMs ?? next ?? start + 9_000
            var end = sourceEnd
            if !row.isSecondaryAgent, let next, next - sourceEnd < 7_000 {
                // Hand the highlight directly to the next phrase at the same boundary.
                // Duets and backing retain their independent vocal clocks.
                end = next
            }
            return end > start ? Entry(index: index, start: start, end: end) : nil
        }
    }
}
