// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI

struct CarouselSection<Content: View>: View {
    let title: String
    var onSeeAll: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: LumaSpacing.s) {
            HStack {
                Text(title)
                    .font(.lumaSectionTitle)
                    .padding(.leading, LumaSpacing.m)
                Spacer()
                if let onSeeAll {
                    Button("See All", action: onSeeAll)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.lumaAccent)
                        .buttonStyle(.plain)
                        .padding(.trailing, LumaSpacing.m)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: LumaSpacing.m) {
                    content()
                }
                .scrollTargetLayout()
                .padding(.horizontal, LumaSpacing.m)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}
#endif
