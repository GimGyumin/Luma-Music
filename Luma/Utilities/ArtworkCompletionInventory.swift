import Foundation

/// Account-scoped proof of a previously validated original-artwork inventory.
/// Checking file stamps is cheap; a missing or changed asset requires image validation again.
nonisolated enum ArtworkCompletionInventory {
    struct FileStamp: Codable, Equatable, Sendable {
        let name: String
        let size: Int64
        let modified: Date
        let identity: String
    }
    struct Record: Codable, Sendable {
        let version: Int
        let serverID: UUID
        let files: [FileStamp]
        var uniqueCount: Int { Set(files.map(\.identity)).count }
    }
    private static func url(directory: URL, serverID: UUID) -> URL {
        directory.appendingPathComponent(".completed-originals-\(serverID.uuidString).plist")
    }
    private static func stamp(_ name: String, directory: URL) -> FileStamp? {
        guard (name as NSString).lastPathComponent == name, name.hasSuffix("@original-v1") else { return nil }
        // Explicit hint: the default overload stats the filesystem to infer a directory.
        let file = directory.appendingPathComponent(name, isDirectory: false)
        guard let info = FileStat.read(file), info.isRegularFile, info.size > 0 else { return nil }
        return FileStamp(name: name, size: info.size, modified: info.modified, identity: info.identity)
    }
    static func save(ids: [String], directory: URL, serverID: UUID) throws -> Record {
        let names = Set(ids.map { DownloadService.coverStorageName(for: OriginalArtwork.storageID($0), serverId: serverID) })
        let files = names.sorted().compactMap { stamp($0, directory: directory) }
        guard files.count == names.count else { throw CocoaError(.fileReadNoSuchFile) }
        let record = Record(version: 1, serverID: serverID, files: files)
        // A property list preserves the exact Date stamps across launches.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        try data.write(to: url(directory: directory, serverID: serverID), options: .atomic)
        return record
    }
    static func load(directory: URL, serverID: UUID) -> Record? {
        guard let data = try? Data(contentsOf: url(directory: directory, serverID: serverID)),
              let record = try? PropertyListDecoder().decode(Record.self, from: data),
              record.version == 1, record.serverID == serverID,
              record.files.allSatisfy({ stamp($0.name, directory: directory) == $0 }) else { return nil }
        return record
    }
    static func clear(directory: URL, serverID: UUID) {
        try? FileManager.default.removeItem(at: url(directory: directory, serverID: serverID))
    }
}
