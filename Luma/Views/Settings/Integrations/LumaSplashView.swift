// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import SwiftUI

/// Compact, accessible introduction shared by onboarding and optional services.
struct LumaSplashView: View {
    struct Feature: Identifiable {
        let icon: String
        let title: String
        let detail: String
        var id: String { icon }
    }

    let title: String
    let summary: String
    let icon: String
    let accent: Color
    var appIconName: String? = nil
    let features: [Feature]
    let footnote: String?
    let buttonTitle: String
    let buttonIdentifier: String
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let appIconName {
                        Image(appIconName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 104, height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 46, weight: .medium))
                            .foregroundStyle(accent)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
                .padding(.top, 50)

                Text(title)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 34)

                Text(summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 26) {
                    ForEach(features) { feature in
                        HStack(alignment: .top, spacing: 18) {
                            Image(systemName: feature.icon)
                                .font(.system(size: 27, weight: .regular))
                                .foregroundStyle(accent)
                                .frame(width: 34)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(feature.title)
                                    .font(.body.weight(.semibold))
                                Text(feature.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 31)

                if let footnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 36)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .background(PlatformColors.secondarySystemBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: onContinue) {
                Text(buttonTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(buttonIdentifier)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
            .background(PlatformColors.secondarySystemBackground)
        }
    }
}
