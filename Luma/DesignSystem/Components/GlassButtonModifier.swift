// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

private enum LumaGlassStyle {
    /// Adaptive frosted tint that stays visible in dark mode (near-black chrome) and light mode.
    /// Uses `.primary` so it inverts with the color scheme — white frost on dark, dark frost on light.
    static var defaultTint: Color { Color.primary.opacity(0.20) }
    /// Brand blue glass for primary CTAs (OK / Play / prominent actions).
    static var accentTint: Color { LumaColors.accent.opacity(0.72) }
}

extension View {
    /// Circular control (HIG-sized tap target). Uses Liquid Glass only when
    /// `LumaPerformance.preferCheapChrome` is false — otherwise a flat fill so
    /// compositor work cannot starve AudioStreaming.
    @ViewBuilder
    func lumaGlassButton(size: CGFloat = 44, tint: Color? = nil) -> some View {
        let resolved = tint ?? LumaGlassStyle.defaultTint
        let usesExplicitTint = tint != nil
        if !LumaPerformance.preferCheapChrome,
           #available(macOS 26.0, iOS 26.0, *) {
            self
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassEffect(
                    usesExplicitTint ? Glass.clear.tint(resolved) : Glass.regular,
                    in: .circle
                )
        } else {
            self
                .frame(width: size, height: size)
                .contentShape(Circle())
                .background {
                    Circle()
                        .fill(resolved)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
                }
        }
    }

    /// Capsule control. Same cheap-chrome gate as `lumaGlassButton`.
    @ViewBuilder
    func lumaGlassCapsule(tint: Color? = nil) -> some View {
        let resolved = tint ?? LumaGlassStyle.defaultTint
        let usesExplicitTint = tint != nil
        if !LumaPerformance.preferCheapChrome,
           #available(macOS 26.0, iOS 26.0, *) {
            self
                .contentShape(Capsule())
                .glassEffect(
                    usesExplicitTint ? Glass.clear.tint(resolved) : Glass.regular,
                    in: .capsule
                )
        } else {
            self.background {
                Capsule()
                    .fill(resolved)
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
            }
        }
    }

    /// Primary CTA capsule with Luma Blue tint.
    func lumaAccentGlassCapsule(disabled: Bool = false) -> some View {
        lumaGlassCapsule(tint: LumaColors.accent.opacity(disabled ? 0.35 : 0.72))
    }
}

extension View {
    @ViewBuilder
    func lumaAccentGlassButton(disabled: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(.lumaAccent).disabled(disabled)
        } else {
            self.buttonStyle(.borderedProminent).tint(.lumaAccent).disabled(disabled)
        }
    }

    /// Soft panel for cards / accessory chrome. Cheap path uses material, not Liquid Glass.
    @ViewBuilder
    func lumaGlassPanel(cornerRadius: CGFloat = 16) -> some View {
        if !LumaPerformance.preferCheapChrome,
           #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffect(Glass.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }
        }
    }

    /// Over-cover HERO round button: transparent tap area + soft shadow for glyph legibility.
    func lumaHeroButton(size: CGFloat = 44) -> some View {
        self
            .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
            .frame(width: size, height: size)
            .contentShape(Circle())
    }

    /// Circular control without Liquid Glass — soft fill for over-cover chrome (player star / more).
    func lumaPlainCircleButton(size: CGFloat = 44, fill: Color) -> some View {
        self
            .frame(width: size, height: size)
            .contentShape(Circle())
            .background {
                Circle()
                    .fill(fill)
            }
    }

    /// Capsule control without Liquid Glass (queue shuffle / repeat / auto-extend pills).
    func lumaPlainCapsule(fill: Color) -> some View {
        self
            .contentShape(Capsule())
            .background {
                Capsule()
                    .fill(fill)
            }
    }
}
