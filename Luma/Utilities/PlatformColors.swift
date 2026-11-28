// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

nonisolated enum PlatformColors {
    static var secondarySystemBackground: Color {
        #if canImport(UIKit)
        Color(UIColor.secondarySystemBackground)
        #elseif canImport(AppKit)
        Color(NSColor.controlBackgroundColor)
        #else
        Color.gray.opacity(0.12)
        #endif
    }

    static var systemBackground: Color {
        #if canImport(UIKit)
        Color(UIColor.systemBackground)
        #elseif canImport(AppKit)
        Color(NSColor.windowBackgroundColor)
        #else
        Color.white
        #endif
    }
}
