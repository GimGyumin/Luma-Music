// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Primary action button — tinted-glass capsule with play icon. Used in album and playlist headers.
struct PlayButton: View {
    let action: () -> Void
    var label: String = "Play"
    var isDisabled: Bool = false
    var accentColor: Color = LumaColors.accent
    var height: CGFloat? = nil
    /// Label/glyph color. Default adaptive `lumaAccentText` (white/black) preserves existing callers; the hero
    /// passes the cover-derived tint (or B/W fallback) on a black/white capsule.
    var labelColor: Color = Color.lumaAccentText

    var body: some View {
        Button {
            HapticFeedback.medium.trigger()
            action()
        } label: {
            Label(label, systemImage: "play.fill")
                .font(.lumaCellTitle)
                .foregroundStyle(labelColor)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .padding(.vertical, height == nil ? LumaSpacing.m : 0)
                .background {
                    Capsule(style: .continuous)
                        .fill(accentColor.opacity(isDisabled ? 0.45 : 1))
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

#Preview {
    VStack(spacing: LumaSpacing.l) {
        PlayButton(action: {})
        PlayButton(action: {}, label: "Shuffle", isDisabled: true)
    }
    .padding()
}
