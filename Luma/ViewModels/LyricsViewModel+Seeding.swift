// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import Combine
import OSLog
import QuartzCore
import NaturalLanguage

extension LyricsViewModel {
    /// Seeds the lyric list used by the UI. Never leave `translatedLyrics` empty while loaded.
    /// Preserves existing translations when source lines still match.
    func seedOriginalLyrics(
        from structured: StructuredLyrics,
        hideTranslations: Bool
    ) async {
        if hideTranslations {
            areTranslationsVisible = false
        }

        let pronunciationTrack = lyricsList.flatMap { LyricsLayerAligner.pronunciation(for: structured, in: $0) }
        let pronunciations = LyricsLayerAligner.align(primary: structured.line, secondary: pronunciationTrack?.line ?? [])

        // Phase D: TTML parsing + display-row adaptation run OFF the MainActor —
        // synchronous SAX + row building is CPU-bound and blocks SwiftUI ticks.
        let ttmlData = rawTTMLData
        documentBuildGeneration &+= 1
        let generation = documentBuildGeneration
        let parseTrace = DiagnosticsCenter.shared.begin(.lyricsParse)
        var parseResult = DiagnosticsResult.failure
        defer { parseTrace.finish(Task.isCancelled ? .cancelled : parseResult) }
        let preferredLanguages = [LyricsTranslationSettings.shared.targetLanguage] + Locale.preferredLanguages
        let wantsKoreanPronunciation = AppLanguage.current == .korean
            || LyricsTranslationSettings.normalizedLanguageCode(
                LyricsTranslationSettings.shared.targetLanguage
            ) == "ko"
        let buildTask = Task.detached(priority: .userInitiated) { () -> (
            document: LyricDocument?, rows: [LyricDisplayRow], readings: [[LyricDisplayWord]],
            pairs: [[LyricPronunciationPair]], fallback: [String?], englishOnly: Bool
        ) in
            var document = LyricDocumentBuilder.build(preferringTTML: ttmlData, structured: structured)
            document?.selectTranslation(preferredLanguages: preferredLanguages)
            document?.preferredPronunciationLanguages = preferredLanguages
            let rows = document.map { LyricDisplayBuilder.rows(from: $0) } ?? []
            let documentLines = document?.allLines ?? []
            let serverReadingRows = pronunciationTrack.flatMap { track in
                track.cueLine.isEmpty ? nil : LyricDisplayBuilder.rows(from: track)
            } ?? []
            let readings = rows.enumerated().map { index, row -> [LyricDisplayWord] in
                guard !Task.isCancelled else { return [] }
                if documentLines.indices.contains(index),
                   let pronunciation = document?.pronunciation(for: documentLines[index]),
                   !pronunciation.words.isEmpty {
                    return pronunciation.words.map {
                        LyricDisplayWord(text: $0.text, startMs: LyricTime.milliseconds(fromSeconds: $0.begin),
                            endMs: LyricTime.milliseconds(fromSeconds: $0.end), role: $0.role, preservesSourceSpacing: true)
                    }
                }
                return Self.serverReadingWords(for: row, in: serverReadingRows)
            }
            let pairs = rows.enumerated().map { index, row in
                guard document?.timing == .word, !Task.isCancelled else { return [LyricPronunciationPair]() }
                return LyricPronunciationPair.matching(original: row.words, reading: readings[index])
            }
            let texts = rows.map(\.text)
            let sample = texts.lazy.filter { !$0.isEmpty }.prefix(12).joined(separator: "\n")
            let rawLanguage = (document?.language ?? structured.lang ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let unknownLanguage = ["", "und", "xxx", "unknown", "auto", "null"].contains(rawLanguage)
            let englishTag = rawLanguage == "en" || rawLanguage == "eng" || rawLanguage.hasPrefix("en-")
            let detectedLanguage = sample.isEmpty ? nil : NLLanguageRecognizer.dominantLanguage(for: sample)
            let isEnglishLyrics = englishTag || (unknownLanguage && detectedLanguage == .english)
            let metadata = LyricsLanguage.normalizedLanguageCode(document?.language ?? structured.lang)
            let englishOnly = !sample.isEmpty && !LyricsLanguage.needsTranslation(lines: texts, targetCode: "en")
                && (metadata == "en" || detectedLanguage == .english)

            var cached: [String: String] = [:]
            let fallback = rows.enumerated().map { index, row -> String? in
                guard !Task.isCancelled, !row.isSecondaryAgent else { return nil }
                if pronunciations.indices.contains(row.sourceLineIndex),
                   !pronunciations[row.sourceLineIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                if readings[index].contains(where: { !$0.isBackground && !$0.text.allSatisfy(\.isWhitespace) }) { return nil }
                if let value = cached[row.text] { return value.isEmpty ? nil : value }
                let value = LyricPronunciationFallback.text(
                    row.text,
                    language: document?.language ?? structured.lang,
                    allowEnglish: isEnglishLyrics && wantsKoreanPronunciation
                )
                cached[row.text] = value ?? ""
                return value
            }
            return (document, rows, readings, pairs, fallback, englishOnly)
        }
        let parsed = await withTaskCancellationHandler {
            await buildTask.value
        } onCancel: {
            buildTask.cancel()
        }

        guard generation == documentBuildGeneration, !Task.isCancelled else { return }
        parseResult = .success
        lyricDocument = parsed.document
        hasEnglishOnlyLyrics = parsed.englishOnly
        displayRows = parsed.rows
        let documentLines = parsed.document?.allLines ?? []
        pronunciationRows = parsed.readings
        pronunciationPairs = parsed.pairs
        rebuildInstrumentalGapCache()

        var serverTranslations: [String] = Array(repeating: "", count: structured.line.count)
        if let lang = selectedServerTranslationLang,
           let list = lyricsList,
           let track = LyricsLayerAligner.translationTracks(in: list)
            .first(where: { LyricsLayerAligner.normalize($0.lang) == lang }) {
            serverTranslations = LyricsLayerAligner.align(primary: structured.line, secondary: track.line)
        }

        let ttmlTranslations = lyricDocument?.translatedLines ?? []
        let hasTtmlTranslation = !ttmlTranslations.isEmpty
        if hasTtmlTranslation {
            Logger.lyrics.debug("Loaded embedded translation lines: \(ttmlTranslations.filter { !$0.isEmpty }.count)")
        }

        var generated: Set<Int> = []
        let results = displayRows.enumerated().map { displayIndex, row -> TranslatedLyric in
            let sourceIndex = row.sourceLineIndex
            let existing = displayIndex < translatedLyrics.count ? translatedLyrics[displayIndex] : nil
            let serverText = sourceIndex < serverTranslations.count ? serverTranslations[sourceIndex] : ""
            // Require: `<text for="L15">` maps ONLY to `<p itunes:key="L15">`.
            // Display rows track the same document order as `lyricDocument.allLines`,
            // so the key lookup at displayIndex is the line's own key — never a neighbor's.
            let lineKey = displayIndex < documentLines.count
                ? documentLines[displayIndex].key
                : nil
            let ttmlTranslation = lineKey.flatMap { lyricDocument?.translations[$0] }
            // The parser separates x-bg structurally — main and background are never merged.
            let ttmlText = ttmlTranslation?.main ?? ""
            let rawTtmlBg = ttmlTranslation?.background ?? ""
            let ttmlBg = Self.normalizedChorusTranslation(rawTtmlBg)
            let ttmlBgBegin: TimeInterval? = ttmlTranslation?.backgroundBegin
            let ttmlBgEnd: TimeInterval? = ttmlTranslation?.backgroundEnd
            // Secondary agents (chorus) keep their own text — don't paste lead translations.
            let keepClient = !row.isSecondaryAgent && existing?.originalText == row.text
                ? (existing?.translatedText ?? "")
                : ""
            // Server translation may have chorus text in parentheses.
            // Split it out so the chorus translation renders BELOW the main
            // translation (like TTML x-bg) instead of being merged into one string.
            let rawServerText = serverText
            let serverSplit = Self.extractParenthesizedChorus(from: rawServerText)
            let strippedServerText = serverSplit.main
            let serverChorusText = serverSplit.chorus
            let translated = row.isSecondaryAgent
                ? ""
                : (!ttmlText.isEmpty ? ttmlText : (!strippedServerText.isEmpty ? strippedServerText : keepClient))
            // TTML translation: use parsed x-bg. Server translation: use extracted parenthesized chorus.
            let bg: String
            if !ttmlText.isEmpty {
                bg = row.isSecondaryAgent ? "" : ttmlBg
            } else {
                bg = row.isSecondaryAgent ? "" : serverChorusText
            }
            let embeddedPronunciation = documentLines.indices.contains(displayIndex)
                ? lyricDocument?.pronunciation(for: documentLines[displayIndex]) : nil
            let providedText = embeddedPronunciation.map { row.isSecondaryAgent ? $0.background : $0.main }
            let serverWords = parsed.readings[displayIndex].filter { $0.isBackground == row.isSecondaryAgent }
            let timedText = LyricKaraokeSpacing.sourceTexts(serverWords, secondary: row.isSecondaryAgent)
                .joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let plainText = (!row.isSecondaryAgent && sourceIndex < pronunciations.count) ? pronunciations[sourceIndex] : ""
            let suppliedPronunciation = providedText ?? (timedText.isEmpty ? plainText : timedText)
            let fallback = parsed.fallback.indices.contains(displayIndex) ? parsed.fallback[displayIndex] : nil
            let usesFallback = suppliedPronunciation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fallback != nil
            let pronunciation = usesFallback ? fallback! : suppliedPronunciation
            if usesFallback || embeddedPronunciation?.automaticallyCreated == true { generated.insert(displayIndex) }
            let source: TranslationSource = !ttmlText.isEmpty ? .ttml
                : (!serverText.isEmpty ? .server : existing?.translationSource ?? .none)
            // Secondary background-only rows have empty `row.text` (mainWords == "").
            // Use background words as the display text so the chorus shows.
            let text = row.isSecondaryAgent && row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !row.backgroundWords.isEmpty
                ? LyricKaraokeText.chorusText(from: row.backgroundWords)
                : row.text

            return makeTranslatedLyric(
                at: displayIndex,
                text: text,
                startMs: row.startMs,
                translatedText: translated,
                backgroundTranslation: bg,
                backgroundBegin: ttmlBgBegin,
                backgroundEnd: ttmlBgEnd,
                pronunciationText: pronunciation,
                translationSource: source
            )
        }
        generatedPronunciationIndices = generated
        // IDs are preserved by makeTranslatedLyric. Compare the entire payload: a
        // server-language switch can change only translatedText or translation timing.
        if results != translatedLyrics {
            replaceTranslatedLyrics(results)
        }

        // English lyrics show their generated Korean reading by default, matching
        // the reference presentation. The player's Hide pronunciation action writes
        // this preference back so the choice survives the next song.
        let autoShowEnglish = (UserDefaults.standard.object(
            forKey: Self.englishPronunciationPreferenceKey
        ) as? Bool) ?? true
        if autoShowEnglish, parsed.englishOnly, !generated.isEmpty {
            arePronunciationsVisible = true
        }
    }

    /// Prefer a server `kind=translation` track over client machine translation.
    // MARK: Helpers

    /// OpenSubsonic can return a TTML reading as a separate pronunciation track.
    /// Use its line clock to find the corresponding row before comparing the spans.
    nonisolated private static func serverReadingWords(for row: LyricDisplayRow, in readings: [LyricDisplayRow]) -> [LyricDisplayWord] {
        guard let start = row.startMs else { return [] }
        var best: LyricDisplayRow?
        var bestDistance = 251
        for candidate in readings where candidate.isSecondaryAgent == row.isSecondaryAgent {
            guard let candidateStart = candidate.startMs,
                  candidate.words.contains(where: { $0.endMs > $0.startMs }) else { continue }
            let distance = abs(start - candidateStart)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            } else if distance == bestDistance {
                best = nil
            }
        }
        return best?.words ?? []
    }

    func applyCurrentLanguage() async {
        let syncTrace = DiagnosticsCenter.shared.begin(.lyricsSyncReady)
        var syncReady = false
        defer { syncTrace.finish(syncReady ? .success : .cancelled) }

        guard let list = lyricsList
        else {
            return
        }

        invalidateTranslationWork()
        let generation = languageGeneration

        // Track change: discard all cached translations and chorus data from the
        // previous song so they never leak into the new display rows (Bug E).
        translatedLyrics = []
        areTranslationsVisible = false

        var seen = Set<String>()


        availableLanguages =
        list.structuredLyrics
            .filter(\.isPrimaryLayer)
            .compactMap {
                $0.lang
            }
            .filter {
                seen.insert($0).inserted
            }

        availableServerTranslations = LyricsLayerAligner.translationTracks(in: list).compactMap { track in
            guard let lang = LyricsLayerAligner.normalize(track.lang) else { return nil }
            let title = Locale.current.localizedString(forLanguageCode: lang) ?? lang.uppercased()
            return (lang: lang, title: title)
        }
        // Dedupe by lang
        var seenTranslation = Set<String>()
        availableServerTranslations = availableServerTranslations.filter { seenTranslation.insert($0.lang).inserted }



        let best =
        lyricsService.selectBestLanguage(
            from: list,
            preferred: selectedLanguage
        )


        clearLineHighlight()


        state =
        best.map {
            .loaded($0)
        }
        ?? .empty



        if let structured = best {
            // Auto-select a matching server translation track if available.
            if selectedServerTranslationLang == nil {
                let targetLang = LyricsTranslationSettings.normalizedLanguageCode(LyricsTranslationSettings.shared.targetLanguage).lowercased()
                // Match exact or prefix (e.g. "ko" matches "ko-kr", "ko_kr", "ko")
                let match = availableServerTranslations.first { track in
                    let trackLang = track.lang.lowercased()
                    return trackLang == targetLang || trackLang.replacingOccurrences(of: "-", with: "_") == targetLang
                        || (trackLang.hasPrefix(targetLang) && (trackLang.dropFirst(targetLang.count).first == "-" || trackLang.dropFirst(targetLang.count).first == "_"))
                }
                if let match {
                    selectedServerTranslationLang = match.lang
                    Logger.lyrics.debug("Selected server translation: \(match.lang, privacy: .public)")
                } else {
                    Logger.lyrics.debug("No server translation for target: \(targetLang, privacy: .public)")
                }
            }
            // Always paint originals first, preserving translation visibility state.
            let wasTranslationVisible = areTranslationsVisible
            let hasExistingTranslations = translatedLyrics.contains(where: { !$0.translatedText.isEmpty && $0.translatedText != $0.originalText })
            await seedOriginalLyrics(from: structured, hideTranslations: false)
            guard generation == languageGeneration, !Task.isCancelled else { return }
            if hasTimedPlayback {
                syncReady = true
                syncTrace.finish(.success)
            }
            // Restore visibility when translations were previously shown.
            if wasTranslationVisible && hasExistingTranslations {
                areTranslationsVisible = true
            }

            let settings = LyricsTranslationSettings.shared
            guard settings.isTranslationEnabled, !hidesEnglishTranslation else {
                reconcileTracking()
                return
            }

            // Already have meaningful translations — keep current visibility, just show button.
            if selectedServerTranslationLang != nil || translatedLyrics.contains(where: { !$0.translatedText.isEmpty && $0.translatedText != $0.originalText }) {
                reconcileTracking()
                return
            }

            let resolvedSource = LyricsLanguage.resolvedSourceLanguage(from: structured.lang)
            let preferredTarget = LyricsTranslationSettings.normalizedLanguageCode(settings.targetLanguage)
            let finalTarget = preferredTarget == resolvedSource && LyricsLanguage.needsTranslation(lines: structured.line.map(\.value), targetCode: preferredTarget)
                ? preferredTarget
                : LyricsTranslationSettings.resolvedTargetLanguage(preferred: preferredTarget, source: resolvedSource)
            let originalLines = displayRows.map(\.text)

            let cached: [TranslatedLyric]? = if settings.provider == .apple {
                LyricsTranslationService.shared.cachedTranslation(
                    songID: songId,
                    sourceLanguage: resolvedSource,
                    targetLanguage: finalTarget,
                    originalLines: originalLines,
                    strategyPreference: settings.strategyPreference,
                    customPrompt: settings.appleIntelligencePrompt
                )
            } else {
                TranslationCache.shared.get(
                    songID: songId,
                    sourceLang: resolvedSource,
                    targetLang: finalTarget,
                    provider: settings.provider,
                    originalLines: originalLines
                )
            }
            if let cached {
                replaceTranslatedLyrics(cached, reveal: settings.isAutoTranslateEnabled)
                reconcileTracking()
                return
            }

            if structured.synced, settings.isAutoTranslateEnabled,
               LumaPerformance.budget.allowsAutomaticTranslation {
                Task { [weak self] in
                    guard let self, self.languageGeneration == generation, !Task.isCancelled else { return }
                    await self.translateCurrentLyrics()
                }
            }
        }


        reconcileTracking()
    }



    func networkErrorMessage(
        from error: LyricsError
    ) -> String {


        if case .networkError(let msg) = error {

            return msg
        }


        return error.localizedDescription
    }
}
