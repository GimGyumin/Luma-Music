// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import SwiftUI
import Observation
import UIKit

/// Native tab labels extract an Image, not an arbitrary asynchronous cover view.
/// Load through the shared artwork cache outside the label, then hand UIKit a
/// small, original-color image with its crop and corners already applied.
@MainActor @Observable
final class SidebarArtworkStore {
    struct Entry: Hashable {
        let coverArtID: String
        var playlistID: String? = nil
        var isArtist = false
    }

    struct Scope: Equatable {
        let serverID: UUID?
        let accountRevision: UInt64
        let coverVersion: Int
        let displayScale: CGFloat
    }

    struct Request: Equatable {
        let scope: Scope
        let entries: [Entry]
        let networkRevision: UInt64
    }

    private var scope: Scope?
    private var images: [Entry: UIImage] = [:]

    func image(for entry: Entry, scope: Scope) -> UIImage? {
        self.scope == scope ? images[entry] : nil
    }

    func load(_ request: Request?, container: AppContainer?) async {
        guard let request, let container,
              let serverID = request.scope.serverID,
              let identity = try? container.serverState.requestIdentity(for: serverID) else {
            scope = nil
            images = [:]
            return
        }
        if scope != request.scope {
            scope = request.scope
            images = [:]
        }
        let wanted = Set(request.entries)
        images = images.filter { wanted.contains($0.key) }
        for entry in request.entries where images[entry] == nil {
            guard !Task.isCancelled, container.serverState.requestIsCurrent(identity) else { return }
            // User-picked playlist covers are cached under the playlist id,
            // even when the server still reports an older coverArt id.
            var image: UIImage?
            if let playlistID = entry.playlistID {
                image = await container.artworkImageCache.load(coverArtId: playlistID, allowNetwork: false)
            }
            if image == nil {
                image = await container.artworkImageCache.load(coverArtId: entry.coverArtID,
                    allowNetwork: container.serverState.isOnline)
            }
            guard !Task.isCancelled, scope == request.scope,
                  container.serverState.requestIsCurrent(identity) else { return }
            if let image {
                images[entry] = Self.thumbnail(image, isArtist: entry.isArtist, scale: request.scope.displayScale)
            }
        }
    }

    private static func renderer(scale: CGFloat) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30), format: format)
    }

    private static func thumbnail(_ image: UIImage, isArtist: Bool, scale: CGFloat) -> UIImage {
        renderer(scale: scale).image { _ in
            let bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
            let path = isArtist ? UIBezierPath(ovalIn: bounds) : UIBezierPath(roundedRect: bounds, cornerRadius: 3)
            path.addClip()
            guard image.size.width > 0, image.size.height > 0 else { return }
            let factor = max(30 / image.size.width, 30 / image.size.height)
            let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
            image.draw(in: CGRect(x: (30 - size.width) / 2, y: (30 - size.height) / 2,
                                  width: size.width, height: size.height))
        }
        .withRenderingMode(.alwaysOriginal)
    }

}
#endif
