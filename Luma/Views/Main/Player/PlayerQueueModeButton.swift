import SwiftUI

/// Queue modes share a 44-point tap target while their portrait capsules follow
/// the smaller visual proportions of the system player.
struct PlayerQueueModeButton: View {
    let systemImage: String
    let isActive: Bool
    let label: String
    let compact: Bool
    let contentColor: Color
    let secondaryContentColor: Color
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var portraitGlyph: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var portraitHeight: CGFloat = 38

    private var ink: Color {
        compact ? (isActive ? .black.opacity(0.72) : .white.opacity(systemImage == "circle.circle" ? 0.18 : 0.94))
            : (isActive ? .white : secondaryContentColor)
    }
    private var fill: Color {
        compact ? .white.opacity(isActive ? 0.60 : 0.12)
            : (isActive ? LumaColors.accent.opacity(0.70) : contentColor.opacity(0.14))
    }
    var body: some View {
        Button {
            HapticFeedback.light.trigger()
            action()
        } label: {
            Group {
                if compact, systemImage == "circle.circle" {
                    HStack(spacing: -7) {
                        Circle().stroke(lineWidth: 2)
                        Circle().fill(ink.opacity(0.6)).overlay(Circle().stroke(lineWidth: 2))
                    }
                    .frame(width: 24, height: 16)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: compact ? portraitGlyph : 17, weight: .semibold))
                }
            }
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity)
            .frame(height: compact ? portraitHeight : 48)
            .lumaPlainCapsule(fill: fill)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
