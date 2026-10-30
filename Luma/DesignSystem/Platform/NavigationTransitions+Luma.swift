// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

extension View {
    /// Applies a zoom navigation transition (iOS 18+). No-op on macOS where the API is unavailable.
    @ViewBuilder
    func lumaZoomTransition(sourceID: String?, in namespace: Namespace.ID?) -> some View {
        modifier(LumaZoomTransition(sourceID: sourceID, namespace: namespace))
    }

    /// Marks this view as the matched transition source for a zoom navigation (iOS 18+).
    /// No-op when either parameter is nil or on macOS.
    @ViewBuilder
    func lumaMatchedTransitionSource(id: String?, in namespace: Namespace.ID?) -> some View {
        #if os(iOS)
        if let id, let namespace {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }

}

private struct LumaZoomTransition: ViewModifier {
    let sourceID: String?
    let namespace: Namespace.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        #if os(iOS)
        if !reduceMotion, let sourceID, let namespace {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
        #else
        content
        #endif
    }
}
