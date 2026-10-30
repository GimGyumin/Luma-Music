import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small derived thumbnails from already-downloaded files only. No artwork HTTP
/// requests, full-size image decodes, or file URLs are donated to Spotlight.
actor SpotlightArtworkStore {
    private let downloads: any DownloadServiceProtocol
    private let cache = NSCache<NSString, NSData>()
    init(downloads: any DownloadServiceProtocol) {
        self.downloads = downloads
        cache.countLimit = 96
        cache.totalCostLimit = 6 * 1_024 * 1_024
    }
    func thumbnail(coverID: String, serverID: UUID) async -> Data? {
        guard !Task.isCancelled else { return nil }
        // The bare-ID lookup already resolves originals/legacy downloads but misses
        // browsing-only @thumb/@hero files. Prefer originals so stale tiers cannot mask updates.
        var localURL: URL?
        for id in [OriginalArtwork.storageID(coverID), coverID + "@thumb", coverID, coverID + "@hero"] {
            if let url = await downloads.localCoverArtURL(forId: id, serverId: serverID), url.isFileURL {
                localURL = url
                break
            }
            guard !Task.isCancelled else { return nil }
        }
        guard let url = localURL, !Task.isCancelled else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(serverID):\(ArtworkIdentity.key(coverID)):\(url.lastPathComponent):\(date)" as NSString
        if let value = cache.object(forKey: key) { return value as Data }
        let measurement = SpotlightWorkMeasurement("artwork")
        defer { measurement.end(count: 1) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination), buffer.length <= 64 * 1_024 else { return nil }
        cache.setObject(buffer, forKey: key, cost: buffer.length)
        return buffer as Data
    }
}
