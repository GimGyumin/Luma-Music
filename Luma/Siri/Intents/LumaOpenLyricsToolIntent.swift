import AppIntents
import Foundation

/// Which layer the player should reveal when it opens the lyrics surface.
enum LumaLyricsViewMode: String, AppEnum {
    case lyrics
    case translation
    case pronunciation

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Lyrics View")
    }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .lyrics: DisplayRepresentation(title: "Original Lyrics"),
            .translation: DisplayRepresentation(title: "Translated Lyrics"),
            .pronunciation: DisplayRepresentation(title: "Pronunciation Guide")
        ]
    }
}

/// Lightweight handoff for player-surface requests that need the UI to be
/// mounted. The intent may run while iOS is still launching the host app, so a
/// UserDefaults flag survives until MainTabView appears.
@MainActor
enum SiriPlayerRequestStore {
    private static let pendingLyricsKey = "luma.siri.pendingLyrics"
    private static let pendingLyricsModeKey = "luma.siri.pendingLyricsMode"

    static func publishLyrics(_ mode: LumaLyricsViewMode = .lyrics) {
        UserDefaults.standard.set(true, forKey: pendingLyricsKey)
        UserDefaults.standard.set(mode.rawValue, forKey: pendingLyricsModeKey)
        NotificationCenter.default.post(
            name: .lumaOpenFullPlayerLyrics,
            object: nil,
            userInfo: ["mode": mode.rawValue]
        )
    }

    /// Returns the pending mode exactly once. `nil` means no Siri request is
    /// pending (for example, the in-app Show Lyrics menu command).
    static func consumeLyrics() -> LumaLyricsViewMode? {
        guard UserDefaults.standard.bool(forKey: pendingLyricsKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingLyricsKey)
        let raw = UserDefaults.standard.string(forKey: pendingLyricsModeKey)
        UserDefaults.standard.removeObject(forKey: pendingLyricsModeKey)
        return raw.flatMap(LumaLyricsViewMode.init(rawValue:)) ?? .lyrics
    }
}

/// Opens the current track's lyrics in Luma's existing player surface without
/// duplicating lyrics data or exposing it in the Siri response.
@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct LumaOpenLyricsToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Lyrics in Luma"
    static let description = IntentDescription(
        "Opens the lyrics surface for the song currently playing in Luma, optionally revealing translated lyrics or a pronunciation guide. It does not read lyrics aloud or expose lyrics text.",
        categoryName: "Lyrics"
    )
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "View", description: "Which lyric layer to reveal.", default: .lyrics)
    var view: LumaLyricsViewMode

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        guard let player = await SiriBridge.playbackProvider?(),
              player.state.currentTrack != nil else {
            return .result(dialog: IntentDialog("Luma isn't playing a song right now."))
        }
        SiriPlayerRequestStore.publishLyrics(view)
        switch view {
        case .lyrics:
            return .result(dialog: IntentDialog("Opening lyrics for the current song."))
        case .translation:
            return .result(dialog: IntentDialog("Opening translated lyrics for the current song."))
        case .pronunciation:
            return .result(dialog: IntentDialog("Opening the pronunciation guide for the current song."))
        }
    }
}
