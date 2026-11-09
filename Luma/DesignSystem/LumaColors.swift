// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

// MARK: - Luma Design Tokens v2.0
// Brand: Luma Blue (#377EEC light / #499EF8 dark)
// All colors are adaptive (light/dark) via Asset Catalog Color Sets.
// Asset Catalog entries must be created alongside this file (see spec below).

public enum LumaColors {
    
    // MARK: — Accent
    /// Primary brand color. CTA, active icons, progress bars.
    /// Light #377EEC / Dark #499EF8 (see LumaAccent.colorset)
    public static let accent = Color("LumaAccent")
    
    /// Tinted background for badges, pills, active states.
    public static let accentBackground = Color("LumaAccentBackground")
    
    /// Text/icon color on top of accentBackground.
    public static let accentForeground = Color("LumaAccentForeground")

    /// Neutral system-control accent for generic menus, checkmarks, disclosure actions and
    /// toolbar buttons. Brand blue stays opt-in through `accent`/`lumaAccent`; destructive
    /// roles keep the system red.
    public static var controlAccent: Color { .primary }
    
    // MARK: — Backgrounds
    public static let backgroundPrimary = Color("LumaBackgroundPrimary")
    public static let backgroundSecondary = Color("LumaBackgroundSecondary")
    public static let backgroundTertiary = Color("LumaBackgroundTertiary")
    
    // MARK: — Text (Apple semantic labels — readable in light/dark; not brand accent)
    public static var textPrimary: Color { SemanticLabel.primary }
    public static var textSecondary: Color { SemanticLabel.secondary }
    public static var textTertiary: Color { SemanticLabel.tertiary }

    /// Secondary album metadata stays consistent across words and quality marks.
    public static func albumMetadataInk(on background: Color, increasedContrast: Bool) -> Color {
        let ink: Color = prefersLightControl(on: background) ? .white : .black
        return increasedContrast ? ink : ink.opacity(0.70)
    }

    /// System label / status colors for descriptions, guidance, and warnings.
    public enum SemanticLabel {
        public static var primary: Color {
            #if os(iOS)
            Color(uiColor: .label)
            #elseif os(macOS)
            Color(nsColor: .labelColor)
            #else
            Color.primary
            #endif
        }

        public static var secondary: Color {
            #if os(iOS)
            Color(uiColor: .secondaryLabel)
            #elseif os(macOS)
            Color(nsColor: .secondaryLabelColor)
            #else
            Color.secondary
            #endif
        }

        public static var tertiary: Color {
            #if os(iOS)
            Color(uiColor: .tertiaryLabel)
            #elseif os(macOS)
            Color(nsColor: .tertiaryLabelColor)
            #else
            Color.secondary.opacity(0.8)
            #endif
        }

        public static var warning: Color {
            #if os(iOS)
            Color(uiColor: .systemOrange)
            #elseif os(macOS)
            Color(nsColor: .systemOrange)
            #else
            .orange
            #endif
        }

        public static var destructive: Color {
            #if os(iOS)
            Color(uiColor: .systemRed)
            #elseif os(macOS)
            Color(nsColor: .systemRed)
            #else
            .red
            #endif
        }
    }
    
    // MARK: — Structure
    public static let separator = Color("LumaSeparator")
    public static let border = Color("LumaBorder")
    
    // MARK: — Brand ramp (Luma Blue — use for active chips / gradients)
    public enum Blue {
        public static let v50  = Color(hex: "#EAF1FD")
        public static let v100 = Color(hex: "#D3E3FB")
        public static let v200 = Color(hex: "#A7C6F7")
        public static let v300 = Color(hex: "#7FA8F5")
        public static let v400 = Color(hex: "#5A93F2")
        public static let v500 = Color(hex: "#377EEC") // base accent
        public static let v600 = Color(hex: "#2A63C4")
        public static let v700 = Color(hex: "#214C99")
        public static let v800 = Color(hex: "#16346B")
        public static let v900 = Color(hex: "#0C1E3E")
    }
}

// MARK: - Color(hex:) helper
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/*
 ┌─────────────────────────────────────────────────────────────────────────┐
 │  ASSET CATALOG SPEC — Colors.xcassets                                   │
 │  Create one Color Set per token. Set "Appearances" to "Any, Dark".      │
 ├──────────────────────────────────┬──────────────────┬───────────────────┤
 │  Color Set Name                  │  Light (Any)     │  Dark             │
 ├──────────────────────────────────┼──────────────────┼───────────────────┤
 │  LumaAccent                  │  #377EEC         │  #499EF8          │
 │  LumaAccentBackground        │  #EAF1FD         │  #0E1A30          │
 │  LumaAccentForeground        │  #1B55B8         │  #8FC0FF          │
 │  LumaAccentSecondary         │  #7FA8F5         │  #78B4FF          │
 │  LumaAccentText              │  #FFFFFF         │  #000000          │
 │  LumaBackgroundPrimary       │  #F5F7FF         │  #0F1420          │
 │  LumaBackgroundSecondary     │  #ECF0FB         │  #141B2A          │
 │  LumaBackgroundTertiary      │  #FFFFFF         │  #1B2335          │
 │  LumaTextPrimary/Secondary/Tertiary  │  (unused assets — code uses UIColor.label family) │
 │  LumaSeparator               │  #377EEC @ 12%   │  #499EF8 @ 15%    │
 │  LumaBorder                  │  #377EEC @ 18%   │  #499EF8 @ 22%    │
 └──────────────────────────────────┴──────────────────┴───────────────────┘
 
 NOTE — LumaAccent (Asset Catalog) is the app AccentColor for in-app chrome
 (tabs, toggles, CTAs). System alerts/action sheets must NOT inherit that blue tint —
 system alert actions retain their semantic cancellation and destructive roles.
 
 WindowGroup { ... }
 .tint(LumaColors.accent)
 
 Replace any legacy hard-coded brand literals (#E22134, #6C47F5, #FF7F3F) with
 the tokens above. Destructive actions keep the system red; artwork-derived
 colors and status colors are content, not brand, and may stay varied.
 */
