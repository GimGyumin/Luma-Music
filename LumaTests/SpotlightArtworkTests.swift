import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Luma

@MainActor @Suite("Spotlight cached artwork", .serialized)
struct SpotlightArtworkTests {
    @Test(arguments: ["@thumb", "@original-v1", ""])
    func readsExistingCacheWithoutNetwork(_ suffix: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MockServerService()
        server.state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Artwork fixture", baseURL: "https://fixture.invalid", username: "fixture"))
        let id = try #require(server.state.activeServer?.id)
        let downloads = DownloadService(serverService: server, modelContainer: try .luma(inMemory: true),
            toastService: ToastService(), journal: BackgroundDownloadJournal(directory: root.appendingPathComponent("journal")), storageDirectory: root)
        let context = try #require(CGContext(data: nil, width: 1024, height: 768, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 768))
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        await downloads.persistCover(bytes as Data, forId: "cover" + suffix, serverId: id)
        let store = SpotlightArtworkStore(downloads: downloads)
        let data = try #require(await store.thumbnail(coverID: "cover", serverID: id))
        #expect(data.count <= 64 * 1024)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 128 && image.height == 96)
        #expect(await store.thumbnail(coverID: "cover", serverID: id) == data)
        #expect(await store.thumbnail(coverID: "cover", serverID: UUID()) == nil)
        #expect(await store.thumbnail(coverID: "missing", serverID: id) == nil)
        await downloads.persistCover(Data([0, 1, 2]), forId: "broken@thumb", serverId: id)
        #expect(await store.thumbnail(coverID: "broken", serverID: id) == nil)
    }
}
