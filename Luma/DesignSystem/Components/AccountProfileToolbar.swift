// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Trailing profile control that opens the Luma Account sheet (iOS).
/// App preferences live in Luma's in-app settings screen.
///
/// Uses `.inlineLarge` so the root tab title (Home / Discover / …) sits on the same
/// horizontal band as the account button — matching Apple Music’s Library chrome.
struct AccountProfileToolbarModifier: ViewModifier {
    var isVisible: Bool = true
    var opensSettings: Bool = false
    var usesInlineTitle: Bool = false
    @State private var showAccountSheet = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.tabBarPlacement) private var tabBarPlacement
    #endif

    /// On a regular-width iPad the account lives in the sidebar footer, so a
    /// second profile control in the content toolbar is redundant. If the user
    /// switches back to the top tab bar, the toolbar button returns.
    private var showsToolbarButton: Bool {
        #if os(iOS)
        guard isVisible else { return false }
        guard horizontalSizeClass == .regular, UIDevice.current.userInterfaceIdiom == .pad else {
            return true
        }
        return tabBarPlacement != .sidebar
        #else
        return isVisible
        #endif
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbarTitleDisplayMode(usesInlineTitle ? .inline : .inlineLarge)
            .lumaSoftTopScrollEdge()
            .toolbar {
                if horizontalSizeClass == .regular,
                   UIDevice.current.userInterfaceIdiom == .pad,
                   tabBarPlacement != .sidebar {
                    ToolbarItem(placement: .topBarLeading) {
                        LumaSidebarToggleButton()
                    }
                }
                if showsToolbarButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAccountSheet = true
                        } label: {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.primary)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(opensSettings ? String(localized: "Settings", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                }
            }
            .sheet(isPresented: $showAccountSheet) {
                Group {
                    if opensSettings { NavigationStack { SettingsView() } }
                    else { AccountSheetView() }
                }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        #else
        content
        #endif
    }
}

/// Scroll-edge hysteresis for the shared root header.
///
/// A single 0-point threshold chatters during the top bounce; a small band keeps the
/// header stable while the user drags and makes the restoration boundary explicit.
enum RootHeaderScrollPolicy {
    static let hideThreshold: CGFloat = 8

    /// Returns the new scrolled state, or `nil` when the current state should be kept.
    static func nextState(isScrolled: Bool, offset: CGFloat) -> Bool? {
        if isScrolled {
            return offset <= 0 ? false : nil
        }
        return offset > hideThreshold ? true : nil
    }
}

/// Keep the navigation container and its safe area alive while removing only root chrome.
/// The same scroll state controls the title and the root's toolbar items, including their glass.
///
/// The restore side is intentionally debounced. Inserting the profile/action toolbar
/// items back into the navigation bar during an upward drag forces a bar relayout
/// right before the user reaches the top, which reads as the scroll “catching”.
/// Hiding on the way down stays immediate; restoring waits until the gesture settles.
private struct RootHeaderScrollModifier: ViewModifier {
    @Binding var isScrolled: Bool
    let enabled: Bool
    @State private var restoreTask: Task<Void, Never>?

    private static let restoreDelay = Duration.milliseconds(120)

    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                guard enabled else { return }
                if offset > RootHeaderScrollPolicy.hideThreshold {
                    restoreTask?.cancel()
                    restoreTask = nil
                }
                guard let next = RootHeaderScrollPolicy.nextState(isScrolled: isScrolled, offset: offset) else {
                    return
                }
                if next {
                    isScrolled = true
                } else {
                    scheduleRestore()
                }
            }
            .onChange(of: enabled) { _, enabled in
                if !enabled {
                    restoreTask?.cancel()
                    restoreTask = nil
                    isScrolled = false
                }
            }
            .onDisappear {
                // A pending restore means the last sampled offset was at the scroll
                // edge. Finish it now so a tab switch cannot leave the header hidden.
                guard restoreTask != nil else { return }
                restoreTask?.cancel()
                restoreTask = nil
                isScrolled = false
            }
            .toolbar(removing: enabled && isScrolled ? .title : nil)
            .toolbarBackgroundVisibility(enabled && isScrolled ? .hidden : .automatic, for: .navigationBar)
        #else
        content
        #endif
    }

    private func scheduleRestore() {
        guard isScrolled else { return }
        // Restart the settle window on every edge sample so a decelerating bounce
        // cannot restore the bar mid-gesture.
        restoreTask?.cancel()
        restoreTask = Task { @MainActor in
            try? await Task.sleep(for: Self.restoreDelay)
            guard !Task.isCancelled else { return }
            guard enabled else {
                restoreTask = nil
                return
            }
            isScrolled = false
            restoreTask = nil
        }
    }
}

extension View {
    func lumaScrollingRootHeader(isScrolled: Binding<Bool>, enabled: Bool = true) -> some View {
        modifier(RootHeaderScrollModifier(isScrolled: isScrolled, enabled: enabled))
    }

    /// Places the account/profile button in the navigation bar trailing slot,
    /// aligned with an inline-large root title. Opens as a sheet (not a push).
    func lumaAccountProfileToolbar(isVisible: Bool = true, opensSettings: Bool = false, usesInlineTitle: Bool = false) -> some View {
        modifier(AccountProfileToolbarModifier(isVisible: isVisible, opensSettings: opensSettings, usesInlineTitle: usesInlineTitle))
    }

    /// Root tab title + trailing actions on one row (Library’s custom toolbar).
    func lumaRootTabTitleAlignment() -> some View {
        #if os(iOS)
        toolbarTitleDisplayMode(.inlineLarge)
            .lumaSoftTopScrollEdge()
        #else
        self
        #endif
    }
}
