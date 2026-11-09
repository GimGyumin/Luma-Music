import SwiftUI

/// Apple-style contextual help: a short explanation in the screen where the feature
/// is configured, followed by a normal navigation link to the full guide. Deliberately
/// lightweight so it does not compete with the primary controls.
struct ContextualGuideNote: View {
    let guide: GuideID
    var title: String? = nil
    let message: String

    private var learnMore: String {
        GuideCatalog.languageCode == "ko" ? "더 알아보기" : "Learn more"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.lumaFootnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(message)
                .font(.lumaFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink {
                GuideView(guide: guide)
            } label: {
                Text(learnMore)
                    .font(.lumaFootnote.weight(.medium))
                    .foregroundStyle(LumaColors.accent)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(GuideDefinition(id: guide).title))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
