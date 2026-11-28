// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Drop-in replacement for `AsyncImage` that routes external cover URLs through
/// `ExternalArtworkCache` (memory → disk → network) instead of hitting the network
/// on every render. Use inside a fixed-size container; the image fills its parent.
struct ExternalCoverView<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.appContainer) private var container
    @State private var loaded: (url: URL, image: PlatformImage)?

    var body: some View {
        let image = loaded?.url == url ? loaded?.image : nil
        ZStack {
            if image == nil {
                placeholder()
            }
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .lumaContentReveal(isReady: image != nil)
        .task(id: "\(url?.absoluteString ?? ""):\(container?.serverState.isCellularConnection == true):\(container?.serverState.artworkNetworkRevision ?? 0)") {
            guard let url, loaded?.url != url else { return }
            let allowed = ArtworkNetworkPolicy.allowsDownload(isOnline: container?.serverState.isOnline ?? true,
                                                             isCellular: container?.serverState.isCellularConnection ?? false)
            guard let image = await container?.externalArtworkCache.image(for: url, allowNetwork: allowed),
                  !Task.isCancelled else { return }
            loaded = (url, image)
        }
    }
}
