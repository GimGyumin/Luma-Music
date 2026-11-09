// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import Testing
@testable import Luma

@MainActor
@Suite("Album navigation route")
struct AlbumZoomRouteTests {
    @Test func albumLinkUsesStandardPush() {
        let namespace = Namespace().wrappedValue
        let album = AlbumID3(id: "album-1", name: "Album", songCount: 1, duration: 120)
        let destination = HomeDestination.album(album).albumZoom(sourceID: "albums:album-1", namespace: namespace)
        #expect(destination == .album(album))
    }

    @Test func unsupportedDestinationKeepsStandardPush() {
        let namespace = Namespace().wrappedValue
        let destination = HomeDestination.libraryAlbums.albumZoom(sourceID: "albums", namespace: namespace)
        #expect(destination == .libraryAlbums)
    }

    @Test func routeIdentityIgnoresMetadataAndAttemptButKeepsSourceIdentity() throws {
        let namespace = Namespace().wrappedValue
        let first = AlbumID3(id: "album-1", name: "First name", songCount: 1, duration: 120)
        let refreshed = AlbumID3(id: "album-1", name: "Refreshed name", songCount: 2, duration: 240)
        let firstRoute = try #require(AlbumZoomDestination(destination: .album(first),
                                                          sourceID: "grid:album-1", namespace: namespace))
        let refreshedRoute = try #require(AlbumZoomDestination(destination: .album(refreshed),
                                                              sourceID: "grid:album-1", namespace: namespace))
        #expect(firstRoute == refreshedRoute)
        #expect(firstRoute.attemptID != refreshedRoute.attemptID)
        #expect(firstRoute.album?.name == "First name")
        #expect(refreshedRoute.album?.name == "Refreshed name")
    }

    @Test func sourceRegistryTracksLivenessAndDuplicates() {
        let namespace = Namespace().wrappedValue
        let id = "registry-test-\(UUID().uuidString)"
        let registry = AlbumZoomSourceRegistry.shared
        #expect(registry.sourceCount(id: id, namespace: namespace) == 0)
        registry.register(id: id, namespace: namespace)
        #expect(registry.sourceCount(id: id, namespace: namespace) == 1)
        registry.register(id: id, namespace: namespace)
        #expect(registry.sourceCount(id: id, namespace: namespace) == 2)
        registry.unregister(.init(id: id, namespace: namespace))
        #expect(registry.sourceCount(id: id, namespace: namespace) == 1)
        registry.unregister(.init(id: id, namespace: namespace))
        #expect(registry.sourceCount(id: id, namespace: namespace) == 0)
    }
}
