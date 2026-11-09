import Foundation
import Observation

/// UI-facing session state. The stream carries only changed snapshots; a 500 ms
/// debounce caps SwiftUI updates while traces are completing rapidly.
@MainActor @Observable
final class DiagnosticsStatusModel {
    static let shared = DiagnosticsStatusModel()
    private let center: DiagnosticsCenter
    private(set) var session: DiagnosticsSessionSnapshot
    private(set) var collection: DiagnosticsCollectionSnapshot
    private var streamTask: Task<Void, Never>?
    private var pendingRefresh: Task<Void, Never>?
    private var isObserving = false

    init(center: DiagnosticsCenter = .shared) {
        self.center = center
        session = center.sessionSnapshot()
        collection = center.collectionSnapshot(consent: false)
    }

    isolated deinit {
        streamTask?.cancel()
        pendingRefresh?.cancel()
    }

    /// Starts the in-memory snapshot stream only while the settings screen is
    /// visible. No timer or polling runs when the screen is off-screen.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        streamTask = Task { [weak self, center] in
            for await _ in center.sessionStream() {
                guard let self else { return }
                self.scheduleSessionRefresh()
            }
        }
    }

    func stopObserving() {
        isObserving = false
        streamTask?.cancel()
        streamTask = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    /// Called on appear, after a consent change, after a probe, or when the app
    /// returns to the foreground. It never polls.
    func refresh(consent: Bool) {
        session = center.sessionSnapshot()
        collection = center.collectionSnapshot(consent: consent)
    }

    private func scheduleSessionRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.session = self.center.sessionSnapshot()
        }
    }
}

nonisolated enum DiagnosticsLinks {
    static let performanceDashboard = URL(
        string: "https://console.firebase.google.com/project/luma-music-df4a4/performance"
    )!
}
