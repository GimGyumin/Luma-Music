import AppIntents
import Foundation

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.open)
struct LumaOpenAlbumIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Album"
    @Parameter(title: "Album") var target: LumaAlbumEntity
    @MainActor func perform() async throws -> some IntentResult {
        await SiriBridge.waitUntilReady()
        guard let id = LumaEntityID(rawValue: target.id),
              let url = LumaDeepLink.url(kind: .album, id: id) else { return .result() }
        await SiriBridge.openURLAction?(url)
        return .result()
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.open)
struct LumaOpenArtistIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Artist"
    @Parameter(title: "Artist") var target: LumaArtistEntity
    @MainActor func perform() async throws -> some IntentResult {
        await SiriBridge.waitUntilReady()
        guard let id = LumaEntityID(rawValue: target.id),
              let url = LumaDeepLink.url(kind: .artist, id: id) else { return .result() }
        await SiriBridge.openURLAction?(url)
        return .result()
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.open)
struct LumaOpenPlaylistIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Playlist"
    @Parameter(title: "Playlist") var target: LumaPlaylistEntity
    @MainActor func perform() async throws -> some IntentResult {
        await SiriBridge.waitUntilReady()
        guard let id = LumaEntityID(rawValue: target.id),
              let url = LumaDeepLink.url(kind: .playlist, id: id) else { return .result() }
        await SiriBridge.openURLAction?(url)
        return .result()
    }
}
