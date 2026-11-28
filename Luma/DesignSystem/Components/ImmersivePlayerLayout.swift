// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Full-viewport proportions measured from the supplied Music player reference.
/// Geometry comes from the presenting window, including its actual safe areas.
struct ImmersivePlayerMetrics {
    let size: CGSize
    let topInset: CGFloat
    var bottomInset: CGFloat = 0
    var artworkTop: CGFloat { topInset + LumaSpacing.s }
    var infoTop: CGFloat { min(size.height * 0.548, scrubberTop - 56) }
    var scrubberTop: CGFloat { min(size.height * 0.632, transportCenter - 92) }
    var transportCenter: CGFloat { min(size.height * 0.7465, volumeCenter - 70) }
    var volumeCenter: CGFloat { min(size.height * 0.852, footerCenter - 46) }
    var footerCenter: CGFloat { min(size.height * 0.912, size.height - bottomInset - 32) }
    var contentWidth: CGFloat { max(0, size.width - 2 * LumaSpacing.xxxl) }
    var infoWidth: CGFloat { max(0, size.width - LumaSpacing.xxxl - 26) }
    var footerWidth: CGFloat { max(0, size.width - 2 * Self.footerInset) }
    /// Reference artwork is square, with the same side insets as the seek bar.
    /// Keep the cover above the title on short phones; never center it in the lyrics slot.
    var standardArtworkFrame: CGRect {
        let top = max(topInset + Self.panelTopGap, size.height * 0.109)
        let side = max(0, min(size.width - 2 * Self.standardArtworkHorizontalInset,
                              infoTop - LumaSpacing.xl - top))
        return CGRect(x: (size.width - side) / 2, y: top, width: side, height: side)
    }
    static let standardArtworkHorizontalInset: CGFloat = 32
    static let standardArtworkCornerRadius: CGFloat = 10
    static let footerInset: CGFloat = 30
    static let gripWidth: CGFloat = 60
    static let favoriteGlyph: CGFloat = 24
    static let menuGlyph: CGFloat = 20
    static let transportSkipGlyph: CGFloat = 30
    static let transportPlayGlyph: CGFloat = 46
    static let blendStart: CGFloat = 0.72
    /// Height of the edge strips sampled from the sleeve for the Release player backdrop.
    static let edgeBand: CGFloat = 0.04
    static let footerHeight: CGFloat = 54
    static let footerGlyph: CGFloat = 20
    static let footerSelectionDiameter: CGFloat = 38
    static let flowingFooterReservation: CGFloat = 66
    static let panelTopGap: CGFloat = 34
    /// Raises the lyrics/queue panel a few points so its header sits closer to
    /// the top chrome without changing the player or footer geometry.
    static let panelHeaderLift: CGFloat = 6
    static let panelHeaderSide: CGFloat = 72
    static let upperArtworkBlend: CGFloat = 0.06
    static let dismissTapWidth: CGFloat = 160
    static let dismissTapHeight: CGFloat = 44
    static let landscapeTranslationGap: CGFloat = 12
}

/// Five stable slots: track info, seek controls, transport, volume, output toolbar.
/// Keeping their coordinates independent prevents title/quality changes moving rows.
struct ImmersivePlayerControlsLayout: Layout {
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var expandedPanel = false
    var showsStandardArtwork = false
    var panelBottomSpacing: CGFloat = LumaSpacing.l
    /// Lifts only the lyrics/queue panel; the player and footer stay put.
    var panelTopLift: CGFloat = 0
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = ImmersivePlayerMetrics(size: bounds.size, topInset: topInset, bottomInset: bottomInset)
        let artwork = metrics.standardArtworkFrame
        let panelTop = (showsStandardArtwork ? artwork.minY : topInset + ImmersivePlayerMetrics.panelTopGap)
            - panelTopLift
        let panelBottom = showsStandardArtwork ? artwork.maxY
            : (expandedPanel ? bounds.height
                : metrics.scrubberTop - panelBottomSpacing)
        let slots: [(CGFloat, CGFloat, CGFloat, UnitPoint)] = [
            (metrics.infoTop, metrics.infoWidth, 48, .top),
            (metrics.scrubberTop, metrics.contentWidth, 40, .top),
            (metrics.transportCenter, bounds.width * 0.73, 88, .center),
            (metrics.volumeCenter, metrics.contentWidth, 36, .center),
            (metrics.footerCenter, metrics.footerWidth, ImmersivePlayerMetrics.footerHeight, .center),
            (panelTop, bounds.width, max(0, panelBottom - panelTop), .top)
        ]
        for (index, subview) in subviews.enumerated() where index < slots.count {
            let (y, width, height, anchor) = slots[index]
            let x = index == 0 ? bounds.minX + LumaSpacing.xxxl + width / 2 : bounds.midX
            subview.place(at: CGPoint(x: x, y: bounds.minY + y), anchor: anchor,
                          proposal: ProposedViewSize(width: width, height: height))
        }
    }
}

enum ImmersivePlayerInk {
    static let primary = Color.white
    static let artist = Color.white.opacity(0.70)
    static let timing = Color.white.opacity(0.62)
    static let quality = Color.white.opacity(0.72)
    static let controls = Color.white.opacity(0.88)
}

/// Artwork-derived colours for the two player sliders. The hue comes from the
/// existing atmosphere tint; target brightness comes from the background
/// luminance, so a slider reads as part of the sleeve instead of a fixed white
/// track. The pressed state is deliberately much brighter than the resting state.
struct ImmersiveSliderPalette: Equatable {
    let normalFill: Color
    /// The volume slider sits lower than the progress bar and Music renders it a
    /// touch brighter. Its inactive track is correspondingly a touch deeper.
    let volumeFill: Color
    let pressedFill: Color
    let track: Color
    let pressedTrack: Color
    let volumeTrack: Color
    let normalTime: Color
    let pressedTime: Color
    let icon: Color
    /// Bottom-toolbar selection: a translucent artwork wash with a bright glyph.
    let activeControlFill: Color
    let activeControlIcon: Color

    static func make(tint: Color, background: Color) -> ImmersiveSliderPalette {
        let tintHSB = tint.hsbComponents ?? (hue: 0.58, saturation: 0.05, brightness: 0.72)
        let backgroundHSB = background.hsbComponents ?? (hue: 0.58, saturation: 0.05, brightness: 0.20)
        let backgroundLuminance = max(0, min(1, background.luminance))
        // The atmosphere wash carries the sleeve's hue even when the lightened
        // control tint has collapsed toward gray. This is what keeps a teal
        // sleeve teal without hardcoding teal anywhere.
        let hue = backgroundHSB.saturation > 0.04 ? backgroundHSB.hue : tintHSB.hue
        let chroma = max(backgroundHSB.saturation, tintHSB.saturation)
        let fillSaturation = min(0.09, max(0.012, chroma * 0.22))
        let volumeFillSaturation = min(0.075, max(0.010, chroma * 0.18))
        let trackSaturation = min(0.20, max(0.02, chroma * 0.62))
        let volumeTrackSaturation = min(0.18, max(0.02, chroma * 0.56))
        let timeSaturation = min(0.07, max(0.008, chroma * 0.20))
        let iconSaturation = min(0.08, max(0.008, chroma * 0.24))

        // The phone player is forced dark, but keep a legible dark-ink branch for
        // any bright surface that might host this palette in the future.
        if backgroundLuminance > 0.62 {
            let normal = Color(hue: hue, saturation: fillSaturation, brightness: 0.30)
            let volume = Color(hue: hue, saturation: volumeFillSaturation, brightness: 0.36)
            let track = Color(hue: hue, saturation: trackSaturation, brightness: 0.62)
                .opacity(0.50)
            let pressedTrack = Color(hue: hue, saturation: min(trackSaturation * 0.7, 0.18), brightness: 0.75)
                .opacity(0.48)
            let volumeTrack = Color(hue: hue, saturation: volumeTrackSaturation, brightness: 0.54)
                .opacity(0.46)
            let time = Color(hue: hue, saturation: timeSaturation, brightness: 0.28)
                .opacity(0.72)
            return ImmersiveSliderPalette(
                normalFill: normal,
                volumeFill: volume,
                pressedFill: Color.black.opacity(0.84),
                track: track,
                pressedTrack: pressedTrack,
                volumeTrack: volumeTrack,
                normalTime: time,
                pressedTime: Color.black.opacity(0.90),
                icon: Color(hue: hue, saturation: iconSaturation, brightness: 0.32),
                activeControlFill: Color.white.opacity(0.58),
                activeControlIcon: Color.black.opacity(0.70)
            )
        }

        let fillBrightness = min(0.75, max(0.59, 0.66 + (0.30 - backgroundLuminance) * 0.14))
        let volumeFillBrightness = min(0.80, fillBrightness + 0.055)
        let normalFill = Color(
            hue: hue,
            saturation: fillSaturation,
            brightness: fillBrightness
        ).opacity(0.94)
        let volumeFill = Color(
            hue: hue,
            saturation: volumeFillSaturation,
            brightness: volumeFillBrightness
        ).opacity(0.94)
        let trackBrightness = min(0.52, max(0.36, 0.46 + (0.25 - backgroundLuminance) * 0.12))
        let track = Color(
            hue: hue,
            saturation: trackSaturation,
            brightness: trackBrightness
        ).opacity(0.82)
        let pressedTrack = Color(
            hue: hue,
            saturation: min(trackSaturation * 0.72, 0.18),
            brightness: min(0.82, trackBrightness + 0.20)
        ).opacity(0.56)
        let volumeTrack = Color(
            hue: hue,
            saturation: volumeTrackSaturation,
            brightness: max(0.32, trackBrightness - 0.04)
        ).opacity(0.74)
        let normalTime = Color(
            hue: hue,
            saturation: timeSaturation,
            brightness: min(0.88, max(0.78, 0.82 + (0.25 - backgroundLuminance) * 0.06))
        ).opacity(0.78)
        let icon = Color(
            hue: hue,
            saturation: iconSaturation,
            brightness: 0.82
        )
        return ImmersiveSliderPalette(
            normalFill: normalFill,
            volumeFill: volumeFill,
            pressedFill: .white,
            track: track,
            pressedTrack: pressedTrack,
            volumeTrack: volumeTrack,
            normalTime: normalTime,
            pressedTime: Color.white.opacity(0.96),
            icon: icon,
            activeControlFill: Color.white.opacity(0.58),
            activeControlIcon: Color.black.opacity(0.70)
        )
    }
}

/// A surface-independent footer in window coordinates. Safe-area insets are
/// measured by the caller; lyrics/queue content never participates in placement.
struct PortraitPlayerFooterLayout: Layout {
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let fullSize = CGSize(width: bounds.width, height: bounds.height + topInset + bottomInset)
        let metrics = ImmersivePlayerMetrics(size: fullSize, topInset: topInset, bottomInset: bottomInset)
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY + metrics.footerCenter - topInset),
                          anchor: .center, proposal: ProposedViewSize(
                            width: metrics.footerWidth,
                            height: ImmersivePlayerMetrics.footerHeight))
        }
    }
}

/// Identical geometry on every player surface; no shadow or stretched capsule.
struct PlayerDismissHandle: View {
    let contentColor: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(contentColor.opacity(0.65))
                .frame(width: ImmersivePlayerMetrics.gripWidth, height: LumaSpacing.xs)
                .frame(width: ImmersivePlayerMetrics.dismissTapWidth,
                       height: ImmersivePlayerMetrics.dismissTapHeight, alignment: .top)
                .padding(.top, LumaSpacing.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Close player", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }
}

/// Keep artwork layout stable while transport state animates its visual bounds.
struct PlayerArtworkPlaybackModifier: ViewModifier {
    let isPlaying: Bool
    let reduceMotion: Bool
    /// The standard portrait card sits directly above the track title. Its
    /// bottom shadow edge was visible as a faint horizontal line across that gap;
    /// the artwork border already provides enough separation.
    var showsShadow: Bool = true
    // 378px / 518px in the supplied paused/playing references.
    static let pausedScale: CGFloat = 0.73

    func body(content: Content) -> some View {
        content
            .shadow(color: showsShadow ? .black.opacity(isPlaying ? 0.32 : 0.16) : .clear,
                    radius: isPlaying ? 24 : 12, y: isPlaying ? 12 : 6)
            .scaleEffect(isPlaying ? 1 : Self.pausedScale)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: isPlaying)
    }
}

/// Uses the exact square-height slot proposed by the portrait layout. Visual scale
/// never changes the slot or moves the track info, scrubber, or transport controls.
struct StandardPlayerArtworkSlot<Artwork: View>: View {
    let isPlaying: Bool
    let reduceMotion: Bool
    @ViewBuilder var artwork: (CGFloat) -> Artwork

    var body: some View {
        GeometryReader { geometry in
            let side = max(0, min(geometry.size.width - 2 * ImmersivePlayerMetrics.standardArtworkHorizontalInset,
                                  geometry.size.height))
            artwork(side)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: ImmersivePlayerMetrics.standardArtworkCornerRadius,
                                            style: .continuous))
                .modifier(PlayerArtworkPlaybackModifier(
                    isPlaying: isPlaying,
                    reduceMotion: reduceMotion,
                    showsShadow: false
                ))
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
    }
}
