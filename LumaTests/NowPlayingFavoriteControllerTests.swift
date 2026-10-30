import Foundation
import Testing
@testable import Luma

@MainActor
private final class SystemFavoriteStub: FavoritesServiceProtocol {
    var values = Set<String>()
    var calls: [(String, Bool)] = []
    var waitForMutation = false
    var pending: CheckedContinuation<Void, Error>?
    func star(itemType: FavoriteType, itemId: String) async throws { try await change(itemId, true) }
    func unstar(itemType: FavoriteType, itemId: String) async throws { try await change(itemId, false) }
    private func change(_ id: String, _ desired: Bool) async throws {
        calls.append((id, desired))
        if waitForMutation { try await withCheckedThrowingContinuation { pending = $0 } }
        if desired { values.insert(id) } else { values.remove(id) }
    }
    func syncFromServer() async throws {}
    func isFavorite(itemType: FavoriteType, itemId: String) -> Bool { values.contains(itemId) }
    func isFavoriteInBackground(itemType: FavoriteType, itemId: String) async -> Bool { values.contains(itemId) }
}

@MainActor @Suite("System favorite state", .serialized)
struct NowPlayingFavoriteControllerTests {
    private func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(condition())
    }
    @Test func toggleUpdatesOptimisticallyAndConfirmsBothDirections() async throws {
        let service = SystemFavoriteStub()
        let identity = ServerRequestIdentity(serverID: UUID(), revision: 1)
        let controller = NowPlayingFavoriteController(favorites: service, currentIdentity: { identity })
        controller.select(songID: "one", identity: identity)
        await waitFor { controller.isFavorite != nil }
        let selection = try #require(controller.selection)
        service.waitForMutation = true
        let task = Task { try await controller.setFavorite(true, for: selection) }
        await waitFor { service.pending != nil }
        #expect(controller.isFavorite == true && controller.isMutating)
        service.pending?.resume(); service.pending = nil
        try await task.value
        #expect(!controller.isMutating)
        #expect(service.values.contains("one"))
        service.waitForMutation = false
        try await controller.setFavorite(false, for: selection)
        #expect(controller.isFavorite == false)
        #expect(!service.values.contains("one"))
    }
    @Test func networkFailureRollsBackOptimisticStar() async throws {
        let service = SystemFavoriteStub()
        let identity = ServerRequestIdentity(serverID: UUID(), revision: 1)
        let controller = NowPlayingFavoriteController(favorites: service, currentIdentity: { identity })
        controller.select(songID: "one", identity: identity)
        await waitFor { controller.isFavorite != nil }
        let selection = try #require(controller.selection)
        service.waitForMutation = true
        let task = Task { try await controller.setFavorite(true, for: selection) }
        await waitFor { service.pending != nil }
        service.pending?.resume(throwing: URLError(.notConnectedToInternet)); service.pending = nil
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(controller.isFavorite == false && !controller.isMutating)
        #expect(!service.values.contains("one"))
    }
    @Test func trackChangeRejectsOldButtonAndLateCompletion() async throws {
        let service = SystemFavoriteStub()
        let identity = ServerRequestIdentity(serverID: UUID(), revision: 1)
        let controller = NowPlayingFavoriteController(favorites: service, currentIdentity: { identity })
        controller.select(songID: "one", identity: identity)
        await waitFor { controller.isFavorite != nil }
        let old = try #require(controller.selection)
        service.waitForMutation = true
        let task = Task { try await controller.setFavorite(true, for: old) }
        await waitFor { service.pending != nil }
        controller.select(songID: "two", identity: identity)
        await waitFor { controller.isFavorite != nil }
        service.pending?.resume(); service.pending = nil
        try await task.value
        #expect(controller.selection?.songID == "two")
        #expect(controller.isFavorite == false)
        await #expect(throws: CancellationError.self) { try await controller.setFavorite(false, for: old) }
        #expect(service.calls.count == 1)
    }
    @Test func appFavoriteChangeRefreshesSystemStateWithoutMutation() async {
        let service = SystemFavoriteStub()
        let identity = ServerRequestIdentity(serverID: UUID(), revision: 1)
        let controller = NowPlayingFavoriteController(favorites: service, currentIdentity: { identity })
        controller.select(songID: "one", identity: identity)
        await waitFor { controller.isFavorite == false }
        service.values.insert("one")
        controller.refresh()
        await waitFor { controller.isFavorite == true }
        #expect(service.calls.isEmpty)
        controller.select(songID: nil, identity: nil)
        #expect(controller.isFavorite == nil && controller.selection == nil)
    }
    @Test func accountRevisionChangeCannotMutateNewAccount() async throws {
        let service = SystemFavoriteStub()
        var identity: ServerRequestIdentity? = .init(serverID: UUID(), revision: 1)
        let controller = NowPlayingFavoriteController(favorites: service, currentIdentity: { identity })
        controller.select(songID: "one", identity: identity)
        await waitFor { controller.isFavorite != nil }
        let old = try #require(controller.selection)
        identity = .init(serverID: old.identity.serverID, revision: 2)
        await #expect(throws: CancellationError.self) { try await controller.setFavorite(true, for: old) }
        #expect(service.calls.isEmpty)
    }
    @Test func duplicateTapDuringMutationDoesNotSendAnotherRequest() async throws {
        let service = SystemFavoriteStub()
        let identity = ServerRequestIdentity(serverID: UUID(), revision: 1)
        let controller = NowPlayingFavoriteController(favorites: service, currentIdentity: { identity })
        controller.select(songID: "one", identity: identity)
        await waitFor { controller.isFavorite != nil }
        let selection = try #require(controller.selection)
        service.waitForMutation = true
        let first = Task { try await controller.setFavorite(true, for: selection) }
        await waitFor { service.pending != nil }
        await #expect(throws: CancellationError.self) { try await controller.setFavorite(true, for: selection) }
        #expect(service.calls.count == 1)
        service.pending?.resume(); service.pending = nil
        try await first.value
    }
}
