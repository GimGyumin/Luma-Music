// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
#if os(iOS)
import UIKit
import CoreHaptics
import AVFAudio
import OSLog
#elseif os(macOS)
import AppKit
#endif

/// Centralized haptic feedback catalog.
///
/// Usage: `HapticFeedback.medium.trigger()`
///
/// Catalog:
/// - `.light`     — navigation, skip prev/next, toggle shuffle/repeat, secondary toggles
/// - `.medium`    — play/pause, swipe MiniPlayer, play album/playlist, QueueView skip
/// - `.heavy`     — destructive confirmations (trash download, remove all)
/// - `.selection` — continuous selection change (alphabet jump bar drag, pickers)
/// - `.success`   — download complete, pin to home
/// - `.warning`   — limit reached (max pinned, offline action)
/// - `.error`     — download failed, sync failed, playback failed
@MainActor
enum HapticFeedback {
    case transport
    case lyricTap
    case light
    case medium
    case heavy
    case selection
    case success
    case warning
    case error

    static func prepareLyricTap() {
        #if os(iOS)
        LyricTapHaptics.shared.prepare()
        #endif
    }

    func trigger() {
        #if os(iOS)
        switch self {
        case .transport, .lyricTap:
            LyricTapHaptics.shared.play()
        case .light:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        #elseif os(macOS)
        if self == .transport { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        #endif
    }
}

#if os(iOS)
/// Retain the haptic player across seeks and lyric row replacements.
@MainActor
private final class LyricTapHaptics {
    static let shared = LyricTapHaptics()
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?
    private let fallback = UIImpactFeedbackGenerator(style: .medium)
    private var reportedCapabilities = false

    func prepare() {
        fallback.prepare()
        let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        if !reportedCapabilities {
            Logger.lyrics.notice("[LYRIC-HAPTIC] hardware supported=\(supported)")
            reportedCapabilities = true
        }
        guard supported, engine == nil else { return }
        do {
            let engine = try CHHapticEngine(audioSession: AVAudioSession.sharedInstance())
            engine.playsHapticsOnly = true
            engine.isMutedForAudio = true
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.player = nil
                    self?.engine = nil
                }
            }
            engine.stoppedHandler = { reason in
                Logger.lyrics.debug("[LYRIC-HAPTIC] engine stopped reason=\(reason.rawValue)")
            }
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.55)
            ], relativeTime: 0)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            try engine.start()
            player = try engine.makePlayer(with: pattern)
            self.engine = engine
        } catch {
            Logger.lyrics.error("[LYRIC-HAPTIC] preparation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func play() {
        prepare()
        guard let engine, let player else {
            fallback.impactOccurred(intensity: 1)
            fallback.prepare()
            return
        }
        do {
            try engine.start()
            try player.start(atTime: CHHapticTimeImmediate)
            Logger.lyrics.debug("[LYRIC-HAPTIC] transient submitted")
        } catch {
            self.player = nil
            self.engine = nil
            Logger.lyrics.error("[LYRIC-HAPTIC] playback failed: \(error.localizedDescription, privacy: .public)")
            fallback.impactOccurred(intensity: 1)
        }
    }
}
#endif
