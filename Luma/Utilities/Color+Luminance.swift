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

extension Color {
    /// Mixes two colours in device RGB. Used by the player's translucent
    /// controls so their tracks pick up the current artwork's atmosphere
    /// instead of reading as a neutral gray.
    func blended(with other: Color, amount: Double) -> Color {
        let t = max(0, min(1, amount))
        #if canImport(UIKit)
        let first = UIColor(self)
        let second = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard first.getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              second.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return self }
        return Color(uiColor: UIColor(
            red: r1 + (r2 - r1) * CGFloat(t),
            green: g1 + (g2 - g1) * CGFloat(t),
            blue: b1 + (b2 - b1) * CGFloat(t),
            alpha: a1 + (a2 - a1) * CGFloat(t)
        ))
        #elseif canImport(AppKit)
        guard let first = NSColor(self).usingColorSpace(.deviceRGB),
              let second = NSColor(other).usingColorSpace(.deviceRGB) else { return self }
        return Color(nsColor: NSColor(
            red: first.redComponent + (second.redComponent - first.redComponent) * CGFloat(t),
            green: first.greenComponent + (second.greenComponent - first.greenComponent) * CGFloat(t),
            blue: first.blueComponent + (second.blueComponent - first.blueComponent) * CGFloat(t),
            alpha: first.alphaComponent + (second.alphaComponent - first.alphaComponent) * CGFloat(t)
        ))
        #else
        return self
        #endif
    }

    /// Perceived luminance using ITU-R BT.601 coefficients.
    /// Values > 0.6 indicate a light background that needs dark content.
    ///
    /// Uses UIKit/AppKit bridges — SwiftUI `cgColor?.components` is unreliable for asset /
    /// Display-P3 colours and previously mis-classified dark covers as light (black text on black).
    var luminance: Double {
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        return 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
        #elseif canImport(AppKit)
        guard let ns = NSColor(self).usingColorSpace(.deviceRGB) else { return 0 }
        return 0.299 * Double(ns.redComponent)
            + 0.587 * Double(ns.greenComponent)
            + 0.114 * Double(ns.blueComponent)
        #else
        return 0
        #endif
    }
}
