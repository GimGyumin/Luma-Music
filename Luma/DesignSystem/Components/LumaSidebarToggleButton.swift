// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import SwiftUI
import UIKit

/// Sidebar switch that lives in the TabView sidebar's own top bar.
///
/// `contentToolbar(for: .tabViewSidebar)` can host SwiftUI toolbar items in the
/// sidebar chrome, but SwiftUI has no public action for collapsing that sidebar.
/// UIKit exposes the resolved `UITabBarController.sidebar.isHidden`, so a tiny
/// representable performs the toggle in the same hierarchy. This keeps the
/// control inside the sidebar instead of above it in a separate bar.
struct LumaSidebarToggleButton: View {
    @State private var toggleToken = 0

    var body: some View {
        Button {
            toggleToken &+= 1
        } label: {
            Image(systemName: "sidebar.left")
                .font(.body.weight(.medium))
        }
        .accessibilityLabel(Text("Sidebar"))
        .background {
            SidebarVisibilityToggler(token: toggleToken)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

private struct SidebarVisibilityToggler: UIViewControllerRepresentable {
    let token: Int

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {
        guard context.coordinator.lastToken != token else { return }
        context.coordinator.lastToken = token
        guard let tabBarController = resolvedTabBarController(from: viewController) else { return }
        tabBarController.sidebar.isHidden.toggle()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastToken = 0
    }

    private func resolvedTabBarController(from viewController: UIViewController) -> UITabBarController? {
        if let tabBarController = viewController.tabBarController { return tabBarController }
        var parent = viewController.parent
        while let current = parent {
            if let tabBarController = current as? UITabBarController { return tabBarController }
            if let tabBarController = current.tabBarController { return tabBarController }
            parent = current.parent
        }
        return nil
    }
}
#endif
