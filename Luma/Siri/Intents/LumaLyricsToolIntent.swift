import AppIntents
import Foundation
import SwiftSonic

@available(iOS 27.3, macOS 27.3, *)
enum LumaLyricsToolAction: String, AppEnum {
    case availability
    case seekToLine

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Lyrics Action")
    }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .availability: DisplayRepresentation(title: "Check Lyrics"),
            .seekToLine: DisplayRepresentation(title: "Find a Lyric Line")
        ]
    }
}

/// Read-only lyrics checks plus timed line seeking. It reuses Luma's existing
/// `LyricsService` and player, and deliberately never reads lyric text aloud.
@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct LumaLyricsToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Work with Luma Lyrics"
    static let description = IntentDescription(
        "Checks whether the current track has lyrics, translation, or pronunciation data, or finds a lyric line by its text and seeks playback to that line. It never reads lyrics aloud.",
        categoryName: "Lyrics"
    )
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Action", description: "Check the current track's lyrics or seek to a matching line.")
    var action: LumaLyricsToolAction

    @Parameter(title: "Line Text", description: "Words to find in the lyric line for the seek action.")
    var lineText: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        guard let player = await SiriBridge.playbackProvider?(),
              let track = player.state.currentTrack else {
            return .result(dialog: IntentDialog("Luma isn't playing a song right now."))
        }
        guard let identity = await SiriBridge.catalogIdentityProvider?(),
              let lyricsService = await SiriBridge.lyricsProvider?() else {
            throw LumaAudioIntentError.serviceUnavailable
        }
        let list: LyricsList
        do {
            list = try await lyricsService.fetchLyrics(
                forSongId: track.id,
                serverId: identity.serverID,
                match: LyricsMatchInfo(song: track)
            )
        } catch {
            switch action {
            case .availability:
                return .result(dialog: IntentDialog("I couldn't find lyrics for \(track.title)."))
            case .seekToLine:
                return .result(dialog: IntentDialog("I couldn't load lyrics for \(track.title), so I can't seek by lyric line."))
            }
        }
        let primary = list.structuredLyrics.filter(\.isPrimaryLayer)
        let hasLyrics = primary.contains { layer in
            layer.line.contains { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        switch action {
        case .availability:
            guard hasLyrics else {
                return .result(dialog: IntentDialog("Luma doesn't have lyrics for \(track.title)."))
            }
            let synced = primary.contains(where: \.synced)
            let hasTranslation = list.structuredLyrics.contains { $0.kind == .translation }
            let hasPronunciation = list.structuredLyrics.contains { $0.kind == .pronunciation }
            var details = ["\(track.title) has \(synced ? "time-synced" : "plain") lyrics."]
            if hasTranslation { details.append("The server provides a translation layer.") }
            if hasPronunciation { details.append("The server provides a pronunciation layer.") }
            details.append("Lyrics can be translated on this device from the lyrics screen.")
            return .result(dialog: IntentDialog(stringLiteral: details.joined(separator: " ")))
        case .seekToLine:
            guard let query = lineText?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                return .result(dialog: IntentDialog("Tell me words from the lyric line you want to find."))
            }
            let timed = primary.flatMap { layer -> [(line: Line, offsetMs: Int)] in
                layer.line.compactMap { line -> (line: Line, offsetMs: Int)? in
                    guard line.start != nil else { return nil }
                    return (line, layer.offset)
                }
            }.sorted { ($0.line.start ?? 0) < ($1.line.start ?? 0) }
            guard !timed.isEmpty else {
                return .result(dialog: IntentDialog("The lyrics for \(track.title) aren't time-synced, so I can't seek by line."))
            }
            let matches = timed.filter {
                $0.line.value.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
                ) != nil
            }
            guard let first = matches.first, let start = first.line.start else {
                return .result(dialog: IntentDialog("I couldn't find that lyric line in \(track.title)."))
            }
            let seconds = max(0, TimeInterval(start + first.offsetMs) / 1000)
            await player.seek(to: seconds)
            let time = Self.time(seconds)
            if matches.count > 1 {
                return .result(dialog: IntentDialog("Moved to the first matching lyric line at \(time). There were \(matches.count) matches."))
            }
            return .result(dialog: IntentDialog("Moved to the matching lyric line at \(time)."))
        }
    }

    private static func time(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
