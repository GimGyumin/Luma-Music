// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData

extension View {
    /// Presents a full-screen modal on iOS; falls back to a sheet on macOS where `fullScreenCover` is unavailable.
    ///
    /// The presented hierarchy is a new hosting root. On some OS versions it does not
    /// receive the app's Observable environment objects or SwiftData container from the
    /// presenting view, even though plain sheets do. Re-applying the container-owned
    /// environment here keeps `FullPlayerView` (dominant colour, artwork, @Query) and
    /// other cover roots working without changing what they render.
    @ViewBuilder
    func lumaFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(LumaFullScreenCoverModifier(
            isPresented: isPresented,
            onDismiss: onDismiss,
            content: content
        ))
    }
}

private struct LumaFullScreenCoverModifier<Presented: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    @ViewBuilder let content: () -> Presented

    @Environment(\.appContainer) private var container

    func body(content base: Content) -> some View {
        #if os(iOS)
        base.fullScreenCover(isPresented: $isPresented, onDismiss: onDismiss) {
            presentedContent
        }
        #else
        base.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
            presentedContent
        }
        #endif
    }

    @ViewBuilder
    private var presentedContent: some View {
        if let container {
            content()
                .environment(\.appContainer, container)
                .environment(container.dominantColorExtractor)
                .environment(container.artworkImageCache)
                .modelContainer(container.modelContainer)
        } else {
            content()
        }
    }
}
