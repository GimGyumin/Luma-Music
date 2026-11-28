// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Combine
import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

#if canImport(UIKit)
import AVKit
import AVFoundation
#endif

// MARK: - Scrubber

struct ScrubberView: View {
    let playerState: PlayerState
    let playerService: (any PlayerServiceProtocol)?
    let contentColor: Color
    let secondaryContentColor: Color
    var isExpensiveNetwork: Bool = false
    var phoneLandscape: Bool = false
    var immersivePortrait: Bool = false
    /// Wide iPad / desktop player: Apple Music’s thinner scrubber with a
    /// bare lossless mark and a small position knob.
    var widePlayer: Bool = false
    /// Artwork-derived tint for the unfilled track. Nil keeps the neutral
    /// white-opacity track used by the other players.
    var backgroundTint: Color? = nil
    /// Phone portrait: artwork-aware resting/pressed colours for the track and
    /// time labels. Other players keep their existing palette.
    var sliderPalette: ImmersiveSliderPalette? = nil
    /// Lyric/queue transitions reset any interrupted seek visual so one surface
    /// cannot leave the other with a pressed-looking bar.
    var playerSurface: PlayerSurface? = nil

    @State private var isDragging = false
    @State private var isSeeking = false
    @State private var displayPosition: TimeInterval = 0
    @State private var seekGeneration = 0
    @State private var seekTask: Task<Void, Never>?
    @State private var draggedTrackID: String?

    private var effectiveDuration: TimeInterval {
        playerState.duration > 0 ? playerState.duration : (playerState.currentTrack?.duration ?? 1)
    }

    private var playbackQuality: AudioQualityKind? {
        PlaybackQualityPresentation.quality(
            for: playerState,
            isExpensive: isExpensiveNetwork
        )
    }

    private var positionBinding: Binding<TimeInterval> {
        Binding(
            get: { (isDragging || isSeeking) ? displayPosition : (playerState.pendingSeekPosition ?? playerState.position) },
            set: { newValue in displayPosition = newValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ProgressSlider(
                value: positionBinding,
                total: effectiveDuration,
                onEditingChanged: { editing in
                    if editing {
                        draggedTrackID = playerState.currentTrack?.id
                        if !isSeeking { displayPosition = playerState.position }
                    }
                    isDragging = editing
                    if !editing {
                        guard !playerState.isLiveStream,
                              draggedTrackID == playerState.currentTrack?.id || draggedTrackID == nil else { return }
                        seekGeneration &+= 1
                        let generation = seekGeneration
                        isSeeking = true
                        let target = max(0, min(displayPosition, effectiveDuration))
                        seekTask?.cancel()
                        seekTask = Task {
                            await playerService?.seek(to: target)
                            guard generation == seekGeneration else { return }
                            isSeeking = false
                        }
                    }
                },
                trackColor: sliderPalette?.track
                    ?? backgroundTint?.opacity(0.45)
                    ?? contentColor.opacity(0.22),
                pressedTrackColor: sliderPalette?.pressedTrack,
                fillColor: sliderPalette?.normalFill ?? contentColor.opacity(0.95),
                pressedFillColor: sliderPalette?.pressedFill,
                height: widePlayer ? 20 : (phoneLandscape || immersivePortrait ? 18 : 24),
                trackHeight: widePlayer ? 4 : 7,
                activeTrackHeight: widePlayer ? 7 : 12,
                isInteracting: isDragging || isSeeking,
                showsThumb: widePlayer,
                interactionResetToken: playerSurface
            )

            ScrubberTimeLabels(
                playerState: playerState,
                effectiveDuration: effectiveDuration,
                overridePosition: (isDragging || isSeeking) ? displayPosition : nil,
                color: isDragging
                    ? (sliderPalette?.pressedTime ?? secondaryContentColor)
                    : (sliderPalette?.normalTime ?? secondaryContentColor),
                qualityColor: phoneLandscape || widePlayer
                    ? ImmersivePlayerInk.quality
                    : (immersivePortrait ? ImmersivePlayerInk.quality : contentColor),
                quality: playbackQuality,
                showsRemainingMinus: true,
                compactQualityChip: immersivePortrait,
                plainQualityChip: phoneLandscape || widePlayer,
                // Restore the release player's tappable quality capsule. Landscape
                // stays inline without a detail sheet; portrait and wide players
                // open the existing centered quality card.
                qualityChipInteractive: !phoneLandscape,
                timeFont: widePlayer ? .system(size: 13, weight: .medium) : .lumaCaption
            )
            .animation(.easeInOut(duration: 0.18), value: isDragging)
        }
        .onChange(of: playerState.currentTrack?.id) { _, _ in
            seekTask?.cancel()
            seekGeneration &+= 1
            isDragging = false
            isSeeking = false
            displayPosition = playerState.position
            // Retain the original gesture's identity until its release is discarded.
        }
        .onChange(of: playerSurface) { _, _ in
            // A surface switch must never carry a cancelled drag's visual state
            // into lyrics or queue. The seek itself (if any) is not cancelled.
            isDragging = false
            isSeeking = false
        }
    }
}

struct ScrubberTimeLabels: View {
    let playerState: PlayerState
    let effectiveDuration: TimeInterval
    let overridePosition: TimeInterval?
    let color: Color
    let qualityColor: Color
    var quality: AudioQualityKind? = nil
    var showsRemainingMinus: Bool = false
    var compactQualityChip: Bool = false
    /// Landscape displays the format inline without a detail button.
    var plainQualityChip: Bool = false
    /// The wide player keeps the detail sheet reachable while dropping the pill fill.
    var qualityChipInteractive: Bool = true
    var timeFont: Font = .lumaCaption

    private var hasPlayableDuration: Bool {
        playerState.currentTrack != nil && effectiveDuration > 0 && !playerState.isLiveStream
    }

    var body: some View {
        let shown = overridePosition ?? playerState.pendingSeekPosition ?? playerState.position
        HStack(spacing: 8) {
            Text(hasPlayableDuration
                 ? Duration.seconds(shown).formatted(.time(pattern: .minuteSecond))
                 : "--:--")
                .font(timeFont)
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let quality {
                AudioQualityLabelView(
                    quality: quality,
                    foreground: qualityColor,
                    interactive: qualityChipInteractive,
                    usesGlass: false,
                    style: quality == .dolbyAtmos && (compactQualityChip || plainQualityChip) ? .scrubberAtmos : .pill,
                    compact: compactQualityChip,
                    showsChipBackground: !plainQualityChip
                )
            }
            Text(hasPlayableDuration
                 ? (showsRemainingMinus ? "−" : "") + Duration.seconds(max(effectiveDuration - shown, 0)).formatted(.time(pattern: .minuteSecond))
                 : "--:--")
                .font(timeFont)
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct ProgressSlider: View {
    @Binding var value: TimeInterval
    let total: TimeInterval
    let onEditingChanged: (Bool) -> Void
    var trackColor: Color = Color.white.opacity(0.2)
    var pressedTrackColor: Color? = nil
    var fillColor: Color = Color.white.opacity(0.95)
    /// Brighter fill while the finger is down. Nil keeps the resting fill.
    var pressedFillColor: Color? = nil
    var height: CGFloat = 32
    var trackHeight: CGFloat = 5
    var activeTrackHeight: CGFloat = 12
    var dragMinimumDistance: CGFloat = 0
    var isInteracting: Bool = false
    /// Small Apple Music–style position knob. The gesture remains on the full
    /// track so the knob does not shrink the touch target.
    var showsThumb: Bool = false
    /// Changing this value clears a drag that was cancelled by a surface switch.
    var interactionResetToken: AnyHashable? = nil
    /// Volume-style behaviour: pressing only shows the active (thicker) bar — the value never jumps
    /// to the touch point. It moves *relative* to the value the press started from, so a tap (or a
    /// finger wobble while holding) cannot slam the volume. Progress scrubbers keep the default
    /// (touch = seek to that position).
    var ignoresTapForValueChange: Bool = false

    /// Finger travel (points) required before a press-only control starts following the finger.
    private static let valueChangeThreshold: CGFloat = 2

    @State private var isDragging = false
    @State private var dragValue: TimeInterval?
    /// Value when the current press began — the anchor for relative (volume-style) dragging.
    @State private var dragAnchor: TimeInterval?

    var body: some View {
        GeometryReader { geo in
            let trackW = geo.size.width
            let barHeight = isDragging ? activeTrackHeight : trackHeight
            let fillWidth = progressWidth(in: trackW)
            let thumbSize: CGFloat = isDragging ? 12 : 8
            let resolvedTrack = isDragging ? (pressedTrackColor ?? trackColor) : trackColor
            let resolvedFill = isDragging ? (pressedFillColor ?? fillColor) : fillColor

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(resolvedTrack)

                Capsule()
                    .fill(resolvedFill)
                    .frame(width: fillWidth)
                    .animation(nil, value: value)

                if showsThumb {
                    Circle()
                        .fill(resolvedFill)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                        .offset(x: max(0, fillWidth - thumbSize / 2))
                        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: isDragging)
                }
            }
            .frame(height: barHeight)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isDragging)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: dragMinimumDistance)
                    .onChanged { gesture in
                        guard trackW > 0 else { return }
                        if !isDragging {
                            isDragging = true
                            dragAnchor = value
                            onEditingChanged(true)
                            HapticFeedback.light.trigger()
                        }
                        let next: TimeInterval
                        if ignoresTapForValueChange {
                            // Relative: travel, not position, decides the new value.
                            guard let anchor = dragAnchor,
                                  abs(gesture.translation.width) >= Self.valueChangeThreshold else { return }
                            next = anchor + total * Double(gesture.translation.width / trackW)
                        } else {
                            let fraction = max(0, min(1, gesture.location.x / trackW))
                            next = total * Double(fraction)
                        }
                        dragValue = max(0, min(total, next))
                        value = dragValue ?? value
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragValue = nil
                        dragAnchor = nil
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: height)
        .accessibilityLabel(String(localized: "Playback position", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .accessibilityValue(Duration.seconds(value).formatted(.time(pattern: .minuteSecond)))
        .accessibilityAdjustableAction { direction in
            let step = total * 0.05
            switch direction {
            case .increment:
                value = min(value + step, total)
                onEditingChanged(false)
            case .decrement:
                value = max(value - step, 0)
                onEditingChanged(false)
            @unknown default: break
            }
        }
        .onChange(of: interactionResetToken) { _, _ in
            isDragging = false
            dragValue = nil
            dragAnchor = nil
        }
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let displayedValue = dragValue ?? value
        return min(totalWidth, max(0, (CGFloat(displayedValue) / CGFloat(total)) * totalWidth))
    }
}

// MARK: - Playback controls

struct PlaybackControlsView: View {
    let playerState: PlayerState
    let playerService: (any PlayerServiceProtocol)?
    var isPlaybackAvailable: Bool = true
    let contentColor: Color
    let secondaryContentColor: Color
    var showsShuffleRepeat: Bool = false
    var compactLayout: Bool = false
    var spreadsTransport: Bool = false
    /// Wide iPad / desktop player: slightly larger primary glyphs and a wider
    /// shuffle–transport–repeat rhythm under the album column.
    var widePlayer: Bool = false
    /// Phone portrait Music.app rhythm: tighter row, slightly smaller glyphs,
    /// while keeping the 64/88pt hit targets.
    var phonePortraitControls: Bool = false
    /// Landscape Now Playing: a 56pt transport row with Apple Music's larger
    /// spacing, using the same playback-engine actions as every other surface.
    var phoneLandscape: Bool = false

    private var previousNextIconSize: CGFloat {
        if compactLayout { return 32 }
        if widePlayer { return 38 }
        if phonePortraitControls && spreadsTransport { return ImmersivePlayerMetrics.transportSkipGlyph }
        return phonePortraitControls ? 30 : 36
    }

    private var playIconSize: CGFloat {
        if compactLayout { return 40 }
        if widePlayer { return 46 }
        return phonePortraitControls ? ImmersivePlayerMetrics.transportPlayGlyph : 44
    }

    private var controlsSpacing: CGFloat {
        if compactLayout { return 12 }
        if showsShuffleRepeat { return widePlayer ? LumaSpacing.xxl : LumaSpacing.xl }
        return phonePortraitControls ? LumaSpacing.xxl : LumaSpacing.xxxxl
    }

    var body: some View {
        HStack(spacing: controlsSpacing) {
            if showsShuffleRepeat, !playerState.isLiveStream {
                Button {
                    HapticFeedback.light.trigger()
                    Task { await playerService?.toggleShuffle() }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(playerState.isShuffled ? Color.lumaAccent : secondaryContentColor)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .disabled(!isPlaybackAvailable)
                .accessibilityLabel(String(localized: "Shuffle", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }

            if !playerState.isLiveStream {
                Button {
                    HapticFeedback.transport.trigger()
                    Task { try? await playerService?.skipToPrevious() }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: previousNextIconSize, weight: .semibold, design: .default))
                        .foregroundStyle(Color.white)
                        .frame(width: phoneLandscape ? 48 : (compactLayout ? 44 : 64),
                               height: phoneLandscape ? 48 : (compactLayout ? 44 : 64))
                }
                .disabled(!isPlaybackAvailable)
                .accessibilityLabel("Skip to previous")
                .frame(maxWidth: spreadsTransport ? .infinity : nil)
            }

            Button {
                HapticFeedback.transport.trigger()
                Task { await playerService?.togglePlayPause() }
            } label: {
                Image(systemName: playerState.playbackState.controlAppearance.systemImage)
                    .font(.system(size: playIconSize, weight: .semibold, design: .default))
                    .foregroundStyle(Color.white)
                    .frame(
                        minWidth: phoneLandscape ? 56 : (compactLayout ? 64 : (showsShuffleRepeat ? 72 : 88)),
                        minHeight: phoneLandscape ? 56 : (compactLayout ? 64 : (showsShuffleRepeat ? 72 : 88))
                    )
                    .contentShape(Rectangle())
            }
            .disabled(playerState.currentTrack == nil)
            .accessibilityLabel(playerState.playbackState.controlAppearance == .play ? "Play" : "Pause")
            .frame(maxWidth: spreadsTransport ? .infinity : nil)

            if !playerState.isLiveStream {
                Button {
                    HapticFeedback.transport.trigger()
                    Task { try? await playerService?.skipToNext() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: previousNextIconSize, weight: .semibold, design: .default))
                        .foregroundStyle(Color.white)
                        .frame(width: phoneLandscape ? 48 : (compactLayout ? 44 : 64),
                               height: phoneLandscape ? 48 : (compactLayout ? 44 : 64))
                }
                .disabled(!isPlaybackAvailable)
                .accessibilityLabel("Skip to next")
                .frame(maxWidth: spreadsTransport ? .infinity : nil)
            }

            if showsShuffleRepeat, !playerState.isLiveStream {
                Button {
                    HapticFeedback.light.trigger()
                    Task { await playerService?.setRepeatMode(playerState.repeatMode.next) }
                } label: {
                    Image(systemName: playerState.repeatMode.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(playerState.repeatMode != .off ? Color.lumaAccent : secondaryContentColor)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .disabled(!isPlaybackAvailable)
                .accessibilityLabel(String(localized: "Repeat", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }
        }
    }
}
