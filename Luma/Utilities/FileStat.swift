import Darwin
import Foundation

/// One `stat` syscall instead of `FileManager.attributesOfItem`, which also
/// fetches extended attributes for every file. Background artwork inventories
/// stamp each cover on every pass, so the extra attribute calls dominate.
nonisolated enum FileStat {
    struct Info: Sendable {
        let isRegularFile: Bool
        let size: Int64
        let modified: Date
        let identity: String
    }

    static func read(_ url: URL) -> Info? {
        guard url.isFileURL else { return nil }
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &value)
        }
        guard result == 0 else { return nil }
        let modified = Date(
            timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec)
                + TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return Info(
            isRegularFile: (value.st_mode & S_IFMT) == S_IFREG,
            size: Int64(value.st_size),
            modified: modified,
            identity: "\(value.st_dev):\(value.st_ino)"
        )
    }
}
