import Foundation
import OSLog

nonisolated struct GuideContent: Sendable {
    enum Source: String, Sendable {
        case remote
        case cache
        case fallback
    }

    let text: String
    let source: Source
    let fetchedAt: Date?
}

/// Fetches official guides from the Luma Music repository only. One conditional GET per
/// guide is cached on disk and reused for six hours; a failed request falls back to the
/// last cached copy, then to a short bundled explanation. Nothing is fetched at launch.
actor GuideStore {
    static let shared = GuideStore()

    private struct CacheMetadata: Codable {
        var etag: String?
        var lastModified: String?
        var fetchedAt: Date
    }

    private let session: URLSession
    private let directory: URL
    private let freshness: TimeInterval = 6 * 60 * 60
    private let maximumBytes = 512 * 1024

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = caches.appendingPathComponent("LumaGuides", isDirectory: true)
    }

    func content(for id: GuideID, language: String) async -> GuideContent {
        let cached = read(id: id, language: language)
        if let cached, cached.metadata.map({ Date().timeIntervalSince($0.fetchedAt) < freshness }) == true {
            return GuideContent(text: cached.text, source: .cache, fetchedAt: cached.metadata?.fetchedAt)
        }
        guard let url = LumaURLs.guideRaw(language: language, id: id.rawValue),
              LumaURLs.isTrustedGitHubURL(url) else {
            return fallback(id: id, cached: cached)
        }

        var request = URLRequest(url: url)
        request.setValue("text/markdown, text/plain;q=0.9", forHTTPHeaderField: "Accept")
        if let metadata = cached?.metadata {
            if let etag = metadata.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = metadata.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return fallback(id: id, cached: cached)
            }
            if http.statusCode == 304, let cached {
                writeMetadata(cached.metadata, id: id, language: language)
                return GuideContent(text: cached.text, source: .cache, fetchedAt: cached.metadata?.fetchedAt)
            }
            guard http.statusCode == 200, data.count <= maximumBytes,
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return fallback(id: id, cached: cached)
            }
            let metadata = CacheMetadata(
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                fetchedAt: Date()
            )
            write(text: text, metadata: metadata, id: id, language: language)
            return GuideContent(text: text, source: .remote, fetchedAt: metadata.fetchedAt)
        } catch {
            Logger.network.debug("Guide fetch failed for \(id.rawValue, privacy: .public): \(error, privacy: .public)")
            return fallback(id: id, cached: cached)
        }
    }

    private func fallback(id: GuideID, cached: (text: String, metadata: CacheMetadata?)?) -> GuideContent {
        if let cached {
            return GuideContent(text: cached.text, source: .cache, fetchedAt: cached.metadata?.fetchedAt)
        }
        return GuideContent(text: GuideCatalog.fallback(id), source: .fallback, fetchedAt: nil)
    }

    private func read(id: GuideID, language: String) -> (text: String, metadata: CacheMetadata?)? {
        let textURL = fileURL(id: id, language: language)
        guard let text = try? String(contentsOf: textURL, encoding: .utf8) else { return nil }
        let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: Data(contentsOf: metadataURL(id: id, language: language)))
        return (text, metadata)
    }

    private func write(text: String, metadata: CacheMetadata, id: GuideID, language: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: fileURL(id: id, language: language), atomically: true, encoding: .utf8)
            try JSONEncoder().encode(metadata).write(to: metadataURL(id: id, language: language), options: .atomic)
        } catch {
            Logger.network.debug("Guide cache write failed for \(id.rawValue, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func writeMetadata(_ metadata: CacheMetadata?, id: GuideID, language: String) {
        guard let metadata else { return }
        try? JSONEncoder().encode(metadata).write(to: metadataURL(id: id, language: language), options: .atomic)
    }

    private func fileURL(id: GuideID, language: String) -> URL {
        directory.appendingPathComponent("\(language)-\(id.rawValue).md")
    }

    private func metadataURL(id: GuideID, language: String) -> URL {
        directory.appendingPathComponent("\(language)-\(id.rawValue).json")
    }
}
