import AppIntents
import Foundation

@available(iOS 27.3, macOS 27.3, *)
enum LumaSettingsToolAction: String, AppEnum {
    case report
    case setAutomaticDownloads
    case setAutomaticDownloadsOverCellular
    case setLyricsTranslation
    case setAutoTranslateLyrics
    case setPronunciationPriority
    case setTranslationLanguage
    case setListeningHistory
    case setAnimatedArtwork
    case setImmersiveArtwork
    case clearStreamingCache

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Settings Action")
    }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .report: DisplayRepresentation(title: "Report Settings"),
            .setAutomaticDownloads: DisplayRepresentation(title: "Set Automatic Downloads"),
            .setAutomaticDownloadsOverCellular: DisplayRepresentation(title: "Set Cellular Downloads"),
            .setLyricsTranslation: DisplayRepresentation(title: "Set Lyrics Translation"),
            .setAutoTranslateLyrics: DisplayRepresentation(title: "Set Automatic Translation"),
            .setPronunciationPriority: DisplayRepresentation(title: "Set Pronunciation Display"),
            .setTranslationLanguage: DisplayRepresentation(title: "Set Translation Language"),
            .setListeningHistory: DisplayRepresentation(title: "Set Listening History"),
            .setAnimatedArtwork: DisplayRepresentation(title: "Set Animated Artwork"),
            .setImmersiveArtwork: DisplayRepresentation(title: "Set Immersive Album Artwork"),
            .clearStreamingCache: DisplayRepresentation(title: "Clear Streaming Cache")
        ]
    }
}

/// App-wide supported preferences. Settings that need a separate account,
/// credential, or destructive data step stay out of this tool.
@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct LumaSettingsToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Change Luma Settings"
    static let description = IntentDescription(
        "Reports or changes supported Luma preferences for automatic downloads, lyrics translation, pronunciation, listening history, and artwork. Turning automatic downloads off also stops new automatic streaming-cache transfers.",
        categoryName: "Settings"
    )
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Action", description: "The setting to report or change.")
    var action: LumaSettingsToolAction

    @Parameter(title: "Enabled", description: "The new on/off value for the selected setting.")
    var enabled: Bool?

    @Parameter(title: "Language", description: "A language code for translated lyrics, such as ko, en, or ja.")
    var language: String?

    @Parameter(title: "Confirmed", description: "Must be true to clear the streaming cache.", default: false)
    var confirmed: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        let defaults = UserDefaults.standard
        let lyrics = LyricsTranslationSettings.shared

        switch action {
        case .report:
            let downloads = Self.bool(defaults, PlayerService.automaticDownloadUserDefaultsKey, default: false)
            let cellular = Self.bool(defaults, PlayerService.automaticDownloadOverCellularUserDefaultsKey, default: false)
            let history = Self.bool(defaults, "luma.history.enabled", default: true)
            let animated = Self.bool(defaults, "luma.visuals.animatedArtwork", default: true)
            let immersive = Self.bool(defaults, "luma.visuals.immersiveAlbums", default: true)
            let pronunciation = defaults.string(forKey: "luma.lyrics.largerText") == "pronunciation"
            let details = [
                "Automatic downloads are \(downloads ? "on" : "off")\(downloads && cellular ? " including cellular" : "").",
                "Automatic streaming cache is \(downloads ? "on and follows automatic downloads" : "off").",
                "Lyrics translation is \(lyrics.isTranslationEnabled ? "on" : "off") to \(lyrics.targetLanguage)\(lyrics.isAutoTranslateEnabled ? " with automatic translation" : "").",
                "Pronunciation is \(pronunciation ? "shown as the primary lyric line" : "shown as a secondary line").",
                "Listening history is \(history ? "on" : "off").",
                "Animated artwork is \(animated ? "on" : "off"); immersive album artwork is \(immersive ? "on" : "off")."
            ]
            return .result(dialog: IntentDialog(stringLiteral: details.joined(separator: " ")))
        case .setAutomaticDownloads:
            let value = enabled ?? false
            defaults.set(value, forKey: PlayerService.automaticDownloadUserDefaultsKey)
            if !value {
                defaults.set(false, forKey: PlayerService.automaticDownloadOverCellularUserDefaultsKey)
            }
            return .result(dialog: IntentDialog(value
                ? "Automatic downloads are on."
                : "Automatic downloads are off, so automatic streaming cache is off too."))
        case .setAutomaticDownloadsOverCellular:
            let value = enabled ?? false
            guard Self.bool(defaults, PlayerService.automaticDownloadUserDefaultsKey, default: false) else {
                return .result(dialog: IntentDialog("Turn automatic downloads on before enabling cellular downloads."))
            }
            defaults.set(value, forKey: PlayerService.automaticDownloadOverCellularUserDefaultsKey)
            return .result(dialog: IntentDialog(value
                ? "Automatic downloads over cellular are on."
                : "Automatic downloads over cellular are off."))
        case .setLyricsTranslation:
            let value = enabled ?? false
            lyrics.isTranslationEnabled = value
            return .result(dialog: IntentDialog(value
                ? "Lyrics translation is on."
                : "Lyrics translation is off."))
        case .setAutoTranslateLyrics:
            let value = enabled ?? false
            lyrics.isAutoTranslateEnabled = value
            return .result(dialog: IntentDialog(value
                ? "Automatic lyric translation is on."
                : "Automatic lyric translation is off."))
        case .setPronunciationPriority:
            let value = enabled ?? false
            defaults.set(value ? "pronunciation" : "lyrics", forKey: "luma.lyrics.largerText")
            return .result(dialog: IntentDialog(value
                ? "Pronunciation is now shown as the primary lyric line."
                : "Original lyrics are now shown as the primary line."))
        case .setTranslationLanguage:
            guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty else {
                return .result(dialog: IntentDialog("Tell me the language code to translate lyrics into."))
            }
            let normalized = LyricsTranslationSettings.normalizedLanguageCode(language)
            lyrics.targetLanguage = normalized
            return .result(dialog: IntentDialog("Lyrics will translate to \(normalized)."))
        case .setListeningHistory:
            let value = enabled ?? true
            defaults.set(value, forKey: "luma.history.enabled")
            return .result(dialog: IntentDialog(value
                ? "Listening history is on."
                : "Listening history is off."))
        case .setAnimatedArtwork:
            let value = enabled ?? true
            defaults.set(value, forKey: "luma.visuals.animatedArtwork")
            return .result(dialog: IntentDialog(value
                ? "Animated artwork is on."
                : "Animated artwork is off."))
        case .setImmersiveArtwork:
            let value = enabled ?? true
            defaults.set(value, forKey: "luma.visuals.immersiveAlbums")
            return .result(dialog: IntentDialog(value
                ? "Immersive album artwork is on."
                : "Immersive album artwork is off; album cards are used instead."))
        case .clearStreamingCache:
            guard confirmed else {
                return .result(dialog: IntentDialog("Clearing the streaming cache needs confirmation. Ask me again and confirm."))
            }
            guard let cache = await SiriBridge.cacheProvider?() else {
                throw LumaAudioIntentError.serviceUnavailable
            }
            let before = await cache.reclaimableBytes
            try await requestConfirmation(
                conditions: [],
                actionName: .do,
                dialog: IntentDialog("Clear automatic streaming cache? Downloads and playlists are kept.")
            )
            await cache.clearAudioTracksOnly()
            let after = await cache.reclaimableBytes
            let freed = max(0, before - after)
            let size = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
            return .result(dialog: IntentDialog("Cleared \(size) of streaming cache."))
        }
    }

    private static func bool(_ defaults: UserDefaults, _ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
}
