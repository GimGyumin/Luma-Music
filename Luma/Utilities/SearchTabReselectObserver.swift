// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import SwiftUI
import UIKit

/// Observes re-taps on the Search tab without replacing `UITabBarController.delegate`
/// (hijacking that delegate breaks SwiftUI `TabView` selection — e.g. Library bouncing to Home).
struct SearchTabReselectObserver: UIViewControllerRepresentable {
    var isSearchSelected: Bool
    var onSearchReselect: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        context.coordinator.isSearchSelected = isSearchSelected
        context.coordinator.onSearchReselect = onSearchReselect
        context.coordinator.attachIfNeeded(from: controller)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.isSearchSelected = isSearchSelected
        context.coordinator.onSearchReselect = onSearchReselect
        context.coordinator.attachIfNeeded(from: uiViewController)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isSearchSelected = false
        private var beganOnSelectedSearch = false
        var onSearchReselect: (() -> Void)?
        private weak var tabBar: UITabBar?
        private weak var tabController: UITabBarController?
        private var tapRecognizer: UITapGestureRecognizer?

        override init() {
            super.init()
        }

        func attachIfNeeded(from host: UIViewController) {
            Task { @MainActor [weak self, weak host] in
                guard let self, let host else { return }
                guard let tab = Self.findTabBarController(from: host) else { return }
                let bar = tab.tabBar
                guard self.tabBar !== bar else { return }

                if let old = self.tapRecognizer {
                    self.tabBar?.removeGestureRecognizer(old)
                }

                let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                recognizer.cancelsTouchesInView = false
                recognizer.delegate = self
                bar.addGestureRecognizer(recognizer)

                self.tabController = tab
                self.tabBar = bar
                self.tapRecognizer = recognizer
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            beganOnSelectedSearch = isSearchSelected
            // iOS can embed the active search field in the tab bar. Typing and
            // tapping its clear/cancel controls must never request another focus.
            var view = touch.view
            while let current = view {
                if current is UITextInput || current is UISearchBar { return false }
                if current === tabBar { break }
                view = current.superview
            }
            return true
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let bar = tabBar,
                  let items = bar.items,
                  !items.isEmpty
            else { return }

            let x = recognizer.location(in: bar).x
            let width = bar.bounds.width / CGFloat(items.count)
            guard width > 0 else { return }
            let index = min(items.count - 1, max(0, Int(x / width)))

            // `Tab(..., role: .search)` is not guaranteed to be the trailing item
            // on every iOS version. Resolve the real search tab first, then fall
            // back to the title/icon and finally the historical trailing slot.
            let isSearch: Bool
            if #available(iOS 18.0, *),
               let controller = tabController,
               controller.tabs.count == items.count,
               let searchIndex = controller.tabs.firstIndex(where: { $0 is UISearchTab }) {
                isSearch = index == searchIndex
            } else {
                isSearch = Self.isSearchItem(items[index]) || index == items.count - 1
            }

            if isSearch, beganOnSelectedSearch {
                onSearchReselect?()
            }
        }

        private static func isSearchItem(_ item: UITabBarItem) -> Bool {
            let labels = [item.title, item.accessibilityLabel].compactMap { $0 }
            if labels.contains(where: {
                $0.localizedCaseInsensitiveContains("search") || $0.contains("검색")
            }) {
                return true
            }
            guard let image = item.image,
                  let symbol = UIImage(systemName: "magnifyingglass") else { return false }
            return image.pngData() == symbol.pngData()
        }

        @MainActor
        private static func findTabBarController(from host: UIViewController) -> UITabBarController? {
            var responder: UIResponder? = host
            while let current = responder {
                if let tab = current as? UITabBarController { return tab }
                responder = current.next
            }
            var parent = host.parent
            while let current = parent {
                if let tab = current as? UITabBarController { return tab }
                parent = current.parent
            }
            guard let root = host.view.window?.rootViewController else { return nil }
            return findInHierarchy(root)
        }

        @MainActor
        private static func findInHierarchy(_ root: UIViewController) -> UITabBarController? {
            if let tab = root as? UITabBarController { return tab }
            for child in root.children {
                if let found = findInHierarchy(child) { return found }
            }
            if let presented = root.presentedViewController {
                return findInHierarchy(presented)
            }
            return nil
        }
    }
}
#endif
