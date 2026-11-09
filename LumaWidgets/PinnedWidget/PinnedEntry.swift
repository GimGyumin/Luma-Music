// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import WidgetKit

nonisolated struct PinnedEntry: TimelineEntry {
    let date: Date
    let items: [SharedPinnedItem]
    /// Keyed by coverArtFilename (e.g. "abc123.jpg").
    let coverImages: [String: PlatformImage]

    static var placeholder: PinnedEntry {
        let items = [
            SharedPinnedItem(id: "p1", kind: .artist, title: "10CM", subtitle: nil, coverArtFilename: nil),
            SharedPinnedItem(id: "p2", kind: .artist, title: "Michael Jackson", subtitle: nil, coverArtFilename: nil),
            SharedPinnedItem(id: "p3", kind: .artist, title: "불빨간사춘기", subtitle: nil, coverArtFilename: nil),
            SharedPinnedItem(id: "p4", kind: .album, title: "5.0 (Acoustic)", subtitle: "10CM", coverArtFilename: nil),
            SharedPinnedItem(id: "p5", kind: .album, title: "Thriller 40", subtitle: "Michael Jackson", coverArtFilename: nil),
            SharedPinnedItem(id: "p6", kind: .album, title: "Merry Go Round - EP", subtitle: "불빨간사춘기", coverArtFilename: nil),
        ]
        return PinnedEntry(date: Date(), items: items, coverImages: [:])
    }

    static var empty: PinnedEntry {
        PinnedEntry(date: Date(), items: [], coverImages: [:])
    }
}

struct PinnedProvider: TimelineProvider {
    func placeholder(in context: Context) -> PinnedEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (PinnedEntry) -> Void) {
        completion(context.isPreview ? .placeholder : makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PinnedEntry>) -> Void) {
        let entry = makeEntry()
        let nextUpdate = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func makeEntry() -> PinnedEntry {
        guard let data = SharedStorage.read({ $0.data(forKey: SharedStorageKey.pinnedItems.rawValue) }),
              let items = try? JSONDecoder().decode([SharedPinnedItem].self, from: data),
              !items.isEmpty else {
            return .empty
        }

        var coverImages: [String: PlatformImage] = [:]
        for item in items {
            guard let filename = item.coverArtFilename else { continue }
            let id = filename.replacingOccurrences(of: ".jpg", with: "")
            if let image = SharedWidgetData.image(forCoverArtId: id) {
                coverImages[filename] = image
            }
        }

        return PinnedEntry(date: Date(), items: items, coverImages: coverImages)
    }
}
