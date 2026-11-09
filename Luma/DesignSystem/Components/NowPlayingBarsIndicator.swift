// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

extension EnvironmentValues {
    /// A retained tab or panel can still be mounted behind another surface.
    @Entry var playbackVisualsPresented = true
}

/// Heights are published by the shared PCM analyzer. A separate, quieter playback animation bridges missing samples.
struct NowPlayingBarsIndicator: View {
    let isPlaying: Bool
    var isBuffering = false
    @Environment(\.playbackVisualsPresented) private var surfacePresented
    @State private var intersectsViewport = false
    @State private var heldLevels = Array(repeating: CGFloat.zero, count: 4)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var governor = PerformanceGovernor.shared
    @State private var isVisible = false
    @State private var isListening = false
    @State private var meter = PlaybackBeatMeter.shared

    private var wantsSamples: Bool {
        isVisible && intersectsViewport && surfacePresented && isPlaying && !reduceMotion && governor.budget.allowsBeatVisuals
    }

    var body: some View {
        let levels = wantsSamples ? (meter.visualizationFallbackActive ? meter.fallbackBands : meter.bands)
                                 : (isBuffering && !reduceMotion ? heldLevels : Self.rest)
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.white)
                    .frame(width: 2.5, height: NowPlayingBarMotion.height(sample: level))
            }
        }
        .frame(width: 16, height: 14, alignment: .center)
        .animation(wantsSamples ? .linear(duration: governor.budget.beatPublishInterval) : nil, value: levels)
        .onGeometryChange(for: Bool.self) { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            guard !bounds.isEmpty else { return false }
            return proxy.bounds(of: .scrollView).map { bounds.intersects($0) } ?? true
        } action: { intersectsViewport = $0 }
        .accessibilityLabel(isPlaying ? "Now Playing" : "Paused")
        .onAppear { isVisible = true; updateListening() }
        .onDisappear { isVisible = false; updateListening() }
        .onChange(of: wantsSamples) { _, _ in updateListening() }
    }

    private static let rest = Array(repeating: CGFloat.zero, count: 4)

    private func updateListening() {
        guard wantsSamples != isListening else { return }
        isListening = wantsSamples
        if isListening {
            meter.retainUIListening(waveform: true)
        } else {
            if isBuffering { heldLevels = meter.visualizationFallbackActive ? meter.fallbackBands : meter.bands }
            meter.releaseUIListening(waveform: true)
        }
    }
}

nonisolated enum NowPlayingBarMotion {
    static func height(sample: CGFloat) -> CGFloat {
        2.5 + 11.5 * min(1, max(0, sample))
    }
}
