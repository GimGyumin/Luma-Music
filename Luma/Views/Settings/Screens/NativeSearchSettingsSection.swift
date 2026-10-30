import SwiftUI

@available(iOS 27.0, macOS 27.0, *)
struct NativeSearchSettingsSection: View {
    @State private var enabled = LumaNativeSearch.shared.isEnabled
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Section {
            Toggle("Show Library in Spotlight", isOn: $enabled)
                .disabled(busy)
                .onChange(of: enabled) { _, value in
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            try await LumaNativeSearch.shared.setEnabled(value)
                            message = nil
                        } catch { message = String(localized: "Search index could not be updated. Try again.") }
                    }
                }
            Button("Reindex Spotlight Library") {
                Task {
                    busy = true
                    message = nil
                    defer { busy = false }
                    do {
                        try await LumaNativeSearch.shared.reindex(all: true)
                        message = String(localized: "Library submitted. Spotlight may take time to finish processing.")
                    } catch is SpotlightWorkDeferred {
                        message = String(localized: "Indexing is paused to protect playback and battery. Try again later.")
                    } catch { message = String(localized: "Search index could not be updated. Try again.") }
                }
            }
            .disabled(busy || !enabled)
            if busy { ProgressView() }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("System Search")
        } footer: {
            Text("Shares music titles, artists, albums and playlist metadata with on-device system search. Audio, lyrics, server credentials and listening history are excluded. Turning this off removes Luma’s search index.")
        }
    }
}
