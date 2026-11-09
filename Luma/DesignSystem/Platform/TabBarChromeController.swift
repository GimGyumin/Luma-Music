// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import SwiftUI
import UIKit

/// Pushes the gated chrome style into the UIKit tab bar without re-evaluating the
/// SwiftUI TabView. The controller is mounted in the root background and survives
/// tab/page changes, so it can update only the bar's trait style when the artwork
/// scheme actually changes.
struct TabBarChromeBridge: UIViewControllerRepresentable {
    let desiredScheme: ColorScheme?
    let systemScheme: ColorScheme

    func makeUIViewController(context: Context) -> TabBarChromeController {
        TabBarChromeController()
    }

    func updateUIViewController(_ controller: TabBarChromeController, context: Context) {
        controller.apply(desiredScheme: desiredScheme, systemScheme: systemScheme)
    }

    static func dismantleUIViewController(_ controller: TabBarChromeController, coordinator: ()) {
        controller.release()
    }
}

@MainActor
final class TabBarChromeController: UIViewController {
    private weak var tabBar: UITabBar?
    private var desiredScheme: ColorScheme?
    private var systemScheme: ColorScheme = .dark
    private var lastApplied: (identity: ObjectIdentifier, style: UIUserInterfaceStyle)?
    private var isActive = false

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isActive = true
        applyIfNeeded(forceLookup: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isActive = false
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // SwiftUI can rebuild the tab bar during rotation or a TabView identity
        // change. The identity/style cache makes this a no-op on normal layouts;
        // we never force a layout pass ourselves.
        applyIfNeeded()
    }

    func apply(desiredScheme: ColorScheme?, systemScheme: ColorScheme) {
        self.desiredScheme = desiredScheme
        self.systemScheme = systemScheme
        applyIfNeeded()
    }

    /// Applies the artwork override only when it differs from the system style and
    /// the target bar or desired style changed. This is the idempotence boundary
    /// that previous UIKit bridges lacked: repeated SwiftUI updates must not keep
    /// writing `overrideUserInterfaceStyle` while the zoom transition is on screen.
    private func applyIfNeeded(forceLookup: Bool = false) {
        guard isActive || view.window != nil else { return }
        if forceLookup || tabBar?.window == nil {
            tabBar = findTabBar()
        }
        guard let tabBar else { return }

        let style: UIUserInterfaceStyle
        if let desiredScheme, desiredScheme != systemScheme {
            style = desiredScheme == .dark ? .dark : .light
        } else {
            style = .unspecified
        }

        let identity = ObjectIdentifier(tabBar)
        if !forceLookup,
           let lastApplied,
           lastApplied.identity == identity,
           lastApplied.style == style {
            return
        }

        if tabBar.overrideUserInterfaceStyle != style {
            tabBar.overrideUserInterfaceStyle = style
        }
        lastApplied = (identity, style)
    }

    private func findTabBar() -> UITabBar? {
        if let cached = tabBar, cached.window != nil { return cached }
        guard let rootView = view.window?.rootViewController?.view else { return nil }
        return Self.tabBar(in: rootView)
    }

    private static func tabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar { return tabBar }
        for subview in view.subviews {
            if let found = tabBar(in: subview) { return found }
        }
        return nil
    }

    func release() {
        isActive = false
        if let tabBar {
            tabBar.overrideUserInterfaceStyle = .unspecified
        }
        tabBar = nil
        lastApplied = nil
    }
}
#endif
