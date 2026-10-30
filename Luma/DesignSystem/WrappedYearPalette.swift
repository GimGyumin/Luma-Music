// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

nonisolated enum WrappedYearPalette {
    /// Returns 3 deterministic colors derived from the given year, cycling every 8 years.
    /// The identity palette is anchored on Luma Blue (#377EEC); the other themes stay varied.
    static func colors(for year: Int) -> [Color] {
        switch year % 8 {
        case 0: // warm sunset
            return [
                Color(red: 1.000, green: 0.549, blue: 0.259), // #FF8C42 warm orange
                Color(red: 0.910, green: 0.365, blue: 0.298), // #E85D4C coral red
                Color(red: 0.976, green: 0.659, blue: 0.145), // #F9A825 golden yellow
            ]
        case 1: // rose dusk
            return [
                Color(red: 0.945, green: 0.271, blue: 0.310), // #F1454F bright red
                Color(red: 0.914, green: 0.118, blue: 0.388), // #E91E63 rose
                Color(red: 0.690, green: 0.063, blue: 0.125), // #B01020 deep red
            ]
        case 2: // Luma identity (current brand)
            return [
                Color(red: 0.216, green: 0.494, blue: 0.925), // #377EEC Luma Blue
                Color(red: 0.129, green: 0.298, blue: 0.600), // #214C99 deep blue
                Color(red: 0.561, green: 0.753, blue: 1.000), // #8FC0FF soft blue
            ]
        case 3: // oceanic
            return [
                Color(red: 0.000, green: 0.737, blue: 0.831), // #00BCD4 cyan
                Color(red: 0.000, green: 0.588, blue: 0.533), // #009688 teal
                Color(red: 0.161, green: 0.475, blue: 1.000), // #2979FF electric blue
            ]
        case 4: // botanical
            return [
                Color(red: 0.180, green: 0.490, blue: 0.196), // #2E7D32 forest green
                Color(red: 0.976, green: 0.659, blue: 0.145), // #F9A825 sunny yellow
                Color(red: 0.502, green: 0.796, blue: 0.769), // #80CBC4 mint
            ]
        case 5: // midnight blue
            return [
                Color(red: 0.129, green: 0.298, blue: 0.600), // #214C99 deep blue
                Color(red: 0.216, green: 0.494, blue: 0.925), // #377EEC Luma Blue
                Color(red: 0.047, green: 0.118, blue: 0.243), // #0C1E3E near-black blue
            ]
        case 6: // flamingo
            return [
                Color(red: 1.000, green: 0.420, blue: 0.420), // #FF6B6B coral pink
                Color(red: 0.914, green: 0.118, blue: 0.388), // #E91E63 rose red
                Color(red: 1.000, green: 0.439, blue: 0.263), // #FF7043 sunset orange
            ]
        case 7: // storm with blue spark
            return [
                Color(red: 0.376, green: 0.490, blue: 0.545), // #607D8B stone gray
                Color(red: 0.216, green: 0.494, blue: 0.925), // #377EEC Luma Blue
                Color(red: 0.290, green: 0.365, blue: 0.420), // slate
            ]
        default:
            return [
                Color(red: 0.216, green: 0.494, blue: 0.925),
                Color(red: 0.129, green: 0.298, blue: 0.600),
                Color(red: 0.561, green: 0.753, blue: 1.000),
            ]
        }
    }

    // MARK: - Medal colors

    static let medalGold   = Color(red: 1.0,  green: 0.84, blue: 0.0)
    static let medalSilver = Color(red: 0.75, green: 0.75, blue: 0.75)
    static let medalBronze = Color(red: 0.80, green: 0.50, blue: 0.20)
}
