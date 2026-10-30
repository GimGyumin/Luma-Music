import Foundation

/// Supports Navidrome's imported tag map and its raw file-inspection tag map.
/// Unknown fields (including file paths) are never retained.
struct NavidromeCopyrightMetadata: Decodable {
    let copyright: String?

    private enum CodingKeys: String, CodingKey { case tags, rawTags }
    private struct Values: Decodable {
        let values: [String]
        private struct LegacyValue: Decodable { let value: String }
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let strings = try? container.decode([String].self) { values = strings }
            else if let objects = try? container.decode([LegacyValue].self) { values = objects.map(\.value) }
            else if let string = try? container.decode(String.self) { values = [string] }
            else { values = [] }
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let imported = try container.decodeIfPresent([String: Values].self, forKey: .tags) ?? [:]
        let raw = try container.decodeIfPresent([String: Values].self, forKey: .rawTags) ?? [:]
        var result: String?
        for source in [imported, raw] {
            let normalized = Dictionary(source.map { ($0.key.lowercased(), $0.value.values) }, uniquingKeysWith: +)
            for alias in ["copyright", "cprt", "tcop", "©cpy", "wm/copyright"] {
                var seen = Set<String>()
                let lines = (normalized[alias] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
                if !lines.isEmpty { result = lines.joined(separator: "\n"); break }
            }
            if result != nil { break }
        }
        copyright = result
    }
}
