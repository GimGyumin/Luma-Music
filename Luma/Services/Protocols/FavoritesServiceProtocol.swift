// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

protocol FavoritesServiceProtocol: AnyObject, Sendable {
    func star(itemType: FavoriteType, itemId: String) async throws
    func unstar(itemType: FavoriteType, itemId: String) async throws
    func syncFromServer() async throws
    @MainActor func isFavorite(itemType: FavoriteType, itemId: String) -> Bool
    func isFavoriteInBackground(itemType: FavoriteType, itemId: String) async -> Bool
}

extension FavoritesServiceProtocol {
    func isFavoriteInBackground(itemType: FavoriteType, itemId: String) async -> Bool {
        isFavorite(itemType: itemType, itemId: itemId)
    }
}
