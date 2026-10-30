import Foundation
import Observation

/// Shared favorite mutation semantics for the system surface. The existing
/// FavoritesService remains authoritative and owns Navidrome rollback/sync.
@MainActor @Observable
final class NowPlayingFavoriteController {
    struct Selection: Equatable, Sendable { let songID: String; let identity: ServerRequestIdentity }
    private(set) var selection: Selection?
    private(set) var isFavorite: Bool?
    private(set) var isMutating = false
    @ObservationIgnored private let favorites: any FavoritesServiceProtocol
    @ObservationIgnored private let currentIdentity: @MainActor () -> ServerRequestIdentity?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var revision: UInt64 = 0

    init(favorites: any FavoritesServiceProtocol, currentIdentity: @escaping @MainActor () -> ServerRequestIdentity?) {
        self.favorites = favorites
        self.currentIdentity = currentIdentity
    }
    func select(songID: String?, identity: ServerRequestIdentity?) {
        let next = songID.flatMap { id in identity.map { Selection(songID: id, identity: $0) } }
        guard next != selection else { return }
        revision &+= 1
        readTask?.cancel()
        selection = next; isFavorite = nil; isMutating = false
        refresh()
    }
    func refresh() {
        guard let selection, selection.identity == currentIdentity(), !isMutating else { return }
        revision &+= 1
        let token = revision
        readTask?.cancel()
        readTask = Task { [weak self, favorites] in
            let value = await favorites.isFavoriteInBackground(itemType: .song, itemId: selection.songID)
            guard let self, !Task.isCancelled, self.revision == token, self.selection == selection,
                  self.currentIdentity() == selection.identity else { return }
            self.isFavorite = value
        }
    }
    func setFavorite(_ desired: Bool, for expected: Selection) async throws {
        guard expected == selection, expected.identity == currentIdentity(), let previous = isFavorite,
              !isMutating else { throw CancellationError() }
        guard desired != previous else { return }
        revision &+= 1
        readTask?.cancel()
        isFavorite = desired
        isMutating = true
        do {
            if desired { try await favorites.star(itemType: .song, itemId: expected.songID) }
            else { try await favorites.unstar(itemType: .song, itemId: expected.songID) }
            guard selection == expected, currentIdentity() == expected.identity else { return }
            isMutating = false
            refresh()
        } catch {
            if selection == expected, currentIdentity() == expected.identity {
                isFavorite = previous
                isMutating = false
                refresh()
            }
            throw error
        }
    }
}
