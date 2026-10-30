import Foundation
import SwiftData

nonisolated struct SpotlightLocalState: Sendable {
    var favoriteKeys: Set<String> = []
    var downloadedSongs: Set<String> = []
}

actor SpotlightLocalStateStore {
    private let container: ModelContainer
    init(container: ModelContainer) { self.container = container }
    func favorites(serverID: UUID) throws -> Set<String> {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<FavoriteRecord>(predicate: #Predicate { $0.serverId == serverID }))
        return Set(records.map { $0.itemType + ":" + LumaEntityID(serverId: serverID, localId: $0.itemId).rawValue })
    }
}

extension Notification.Name {
    static let lumaPlaylistMetadataChanged = Notification.Name("luma.playlistMetadataChanged")
    static let lumaOfflineMetadataChanged = Notification.Name("luma.offlineMetadataChanged")
}
