import SwiftUI
import WidgetKit

nonisolated struct RecentEntry: TimelineEntry {
    let date: Date
    let items: [SharedTrackInfo]
    let coverImages: [String: PlatformImage]
    let dominantColor: Color
    /// The track currently loaded in the player, when Luma has published one.
    let nowPlaying: SharedTrackInfo?
    let isPlaying: Bool
    let nowPlayingImage: PlatformImage?
    /// Dominant color for the current track (used by the interactive widget
    /// background); falls back to the first recent item when no player state exists.
    var nowPlayingDominantColor: Color = .clear

    var featuredDominantColor: Color {
        nowPlaying != nil ? nowPlayingDominantColor : dominantColor
    }

    static var placeholder: RecentEntry {
        let items = [
            SharedTrackInfo(id: "r1", title: "October Archive", artist: "불빨간사춘기", albumID: nil, coverArtFilename: nil, serverID: nil, coverArtId: nil),
            SharedTrackInfo(id: "r2", title: "ICN > YVR", artist: "BIG Naughty", albumID: nil, coverArtFilename: nil, serverID: nil, coverArtId: nil),
            SharedTrackInfo(id: "r3", title: "노스탤지어 - Single", artist: "BIG Naughty", albumID: nil, coverArtFilename: nil, serverID: nil, coverArtId: nil),
            SharedTrackInfo(id: "r4", title: "여름이잖아 (feat. 마크) - Single", artist: "BIG Naughty", albumID: nil, coverArtFilename: nil, serverID: nil, coverArtId: nil)
        ]
        return RecentEntry(
            date: Date(),
            items: items,
            coverImages: [:],
            dominantColor: Color("LumaAccent"),
            nowPlaying: items.first,
            isPlaying: true,
            nowPlayingImage: nil,
            nowPlayingDominantColor: Color("LumaAccent")
        )
    }

    static var empty: RecentEntry {
        RecentEntry(
            date: Date(),
            items: [],
            coverImages: [:],
            dominantColor: Color("LumaAccent"),
            nowPlaying: nil,
            isPlaying: false,
            nowPlayingImage: nil
        )
    }

    func image(for item: SharedTrackInfo) -> PlatformImage? {
        guard let filename = item.coverArtFilename else { return nil }
        return coverImages[filename]
    }

    /// The item the hero area presents: the current track when available, otherwise
    /// the most recent play.
    var featured: SharedTrackInfo? {
        nowPlaying ?? items.first
    }

    var featuredImage: PlatformImage? {
        if let nowPlaying {
            if let image = nowPlayingImage { return image }
            if let match = items.first(where: { $0.id == nowPlaying.id }),
               let image = image(for: match) {
                return image
            }
        }
        guard let featured else { return nil }
        return image(for: featured)
    }

    var featuredLabel: String {
        nowPlaying == nil ? WidgetChrome.recentlyPlayed : WidgetChrome.nowPlaying
    }

    /// Rows shown below the hero. The current track is not repeated in the list.
    func recentItems(limit: Int) -> [SharedTrackInfo] {
        items
            .filter { item in
                guard let featured else { return true }
                return item.id != featured.id
            }
            .prefix(limit)
            .map { $0 }
    }
}

struct RecentProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (RecentEntry) -> Void) {
        completion(context.isPreview ? .placeholder : makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentEntry>) -> Void) {
        let entry = makeEntry()
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func makeEntry() -> RecentEntry {
        let items = SharedWidgetData.recentlyPlayed()
        let nowPlayingState = SharedWidgetData.nowPlayingState()
        let nowPlaying = nowPlayingState?.track

        var covers: [String: PlatformImage] = [:]
        for item in items {
            guard let filename = item.coverArtFilename else { continue }
            let id = filename.replacingOccurrences(of: ".jpg", with: "")
            if let image = SharedWidgetData.image(forCoverArtId: id) { covers[filename] = image }
        }

        let nowPlayingImage: PlatformImage? = {
            guard let track = nowPlaying else { return nil }
            if let filename = track.coverArtFilename,
               let image = covers[filename] {
                return image
            }
            guard let coverArtId = track.coverArtFilename?.replacingOccurrences(of: ".jpg", with: "") else {
                return nil
            }
            return SharedWidgetData.image(forCoverArtId: coverArtId)
        }()

        guard !items.isEmpty || nowPlaying != nil else { return .empty }

        let firstCoverId = items.first?.coverArtFilename?.replacingOccurrences(of: ".jpg", with: "")
        let nowPlayingCoverId = nowPlaying?.coverArtFilename?.replacingOccurrences(of: ".jpg", with: "")
            ?? nowPlaying?.coverArtId
        let nowPlayingDominantColor = nowPlaying == nil
            ? .clear
            : SharedWidgetData.dominantColor(forCoverArtId: nowPlayingCoverId)
        return RecentEntry(
            date: Date(),
            items: items,
            coverImages: covers,
            dominantColor: SharedWidgetData.dominantColor(forCoverArtId: firstCoverId),
            nowPlaying: nowPlaying,
            isPlaying: nowPlayingState?.isPlaying ?? false,
            nowPlayingImage: nowPlayingImage,
            nowPlayingDominantColor: nowPlayingDominantColor
        )
    }
}
