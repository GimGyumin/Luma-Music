import AppIntents
import Foundation

/// Full queue editing for Siri AI. Every action drives the live
/// `PlayerService`; no second queue or playback engine is created.
@available(iOS 27.3, macOS 27.3, *)
enum LumaQueueToolAction: String, AppEnum {
    case show
    case addNext
    case addLast
    case remove
    case move
    case clearUpNext
    case clearHistory
    case clear

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Queue Action")
    }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .show: DisplayRepresentation(title: "Show Queue"),
            .addNext: DisplayRepresentation(title: "Play Next"),
            .addLast: DisplayRepresentation(title: "Add to End of Queue"),
            .remove: DisplayRepresentation(title: "Remove Queue Item"),
            .move: DisplayRepresentation(title: "Move Queue Item"),
            .clearUpNext: DisplayRepresentation(title: "Clear Up Next"),
            .clearHistory: DisplayRepresentation(title: "Clear Queue History"),
            .clear: DisplayRepresentation(title: "Clear Entire Queue")
        ]
    }
}

@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct LumaQueueToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Edit Luma Playback Queue"
    static let description = IntentDescription(
        "Shows the current playback queue and can add a song next or last, remove an item, move an item, clear upcoming tracks, clear history, or clear the whole queue. Destructive actions require confirmation.",
        categoryName: "Playback"
    )
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Action", description: "The queue operation to perform.")
    var action: LumaQueueToolAction

    @Parameter(title: "Song", description: "The song to add. Omit to search using Query.")
    var song: LumaSongEntity?

    @Parameter(title: "Query", description: "Text used to find a song to add.")
    var query: String?

    @Parameter(title: "Index", description: "One-based queue position for remove or move.")
    var index: Int?

    @Parameter(title: "To Index", description: "One-based destination position for move.")
    var toIndex: Int?

    @Parameter(title: "Confirmed", description: "Must be true for remove, clear, and clear-up-next actions.", default: false)
    var confirmed: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        guard let player = await SiriBridge.playbackProvider?() else {
            throw LumaAudioIntentError.playerUnavailable
        }
        let state = player.state

        switch action {
        case .show:
            guard !state.queue.isEmpty else {
                return .result(dialog: IntentDialog("The Luma queue is empty."))
            }
            let current = state.queue.indices.contains(state.currentIndex) ? state.queue[state.currentIndex] : nil
            let upcoming = state.queue.dropFirst(min(state.currentIndex + 1, state.queue.count)).prefix(8)
            var parts = ["The queue has \(state.queue.count) tracks."]
            if let current {
                parts.append("Playing \(current.title)\(current.artist.map { " by \($0)" } ?? "") at position \(state.currentIndex + 1).")
            }
            if !upcoming.isEmpty {
                let names = upcoming.enumerated().map { index, track in
                    "\(state.currentIndex + index + 2). \(track.title)"
                }.joined(separator: "; ")
                parts.append("Next: \(names)")
            }
            return .result(dialog: IntentDialog(stringLiteral: parts.joined(separator: " ")))
        case .addNext, .addLast:
            guard let track = await resolveSong() else {
                return .result(dialog: IntentDialog("Which song should I add to the queue?"))
            }
            if action == .addNext {
                await player.playNext(track)
                return .result(dialog: IntentDialog("Added \(track.title) next in the queue."))
            }
            await player.addToQueue(track)
            return .result(dialog: IntentDialog("Added \(track.title) to the end of the queue."))
        case .remove:
            guard let index else {
                return .result(dialog: IntentDialog("Tell me the queue position to remove."))
            }
            let zeroBased = index - 1
            guard state.queue.indices.contains(zeroBased) else {
                return .result(dialog: IntentDialog("That queue position doesn't exist."))
            }
            guard zeroBased != state.currentIndex else {
                return .result(dialog: IntentDialog("I can't remove the track that is currently playing."))
            }
            guard confirmed else {
                return .result(dialog: IntentDialog("Removing a queue item needs confirmation. Ask me again and confirm."))
            }
            let removed = state.queue[zeroBased]
            try await requestConfirmation(
                conditions: [],
                actionName: .do,
                dialog: IntentDialog("Remove \(removed.title) from the queue?")
            )
            await player.removeFromQueue(at: zeroBased)
            return .result(dialog: IntentDialog("Removed \(removed.title) from the queue."))
        case .move:
            guard let index, let toIndex else {
                return .result(dialog: IntentDialog("Tell me the current and new queue positions."))
            }
            guard state.queue.indices.contains(index - 1) else {
                return .result(dialog: IntentDialog("That starting queue position doesn't exist."))
            }
            guard (1...state.queue.count).contains(toIndex) else {
                return .result(dialog: IntentDialog("That destination queue position doesn't exist."))
            }
            let moved = state.queue[index - 1]
            await player.moveInQueue(fromIndex: index - 1, toIndex: toIndex - 1)
            return .result(dialog: IntentDialog("Moved \(moved.title) to queue position \(toIndex)."))
        case .clearUpNext:
            guard confirmed else {
                return .result(dialog: IntentDialog("Clearing upcoming tracks needs confirmation. Ask me again and confirm."))
            }
            try await requestConfirmation(
                conditions: [],
                actionName: .do,
                dialog: IntentDialog("Clear every track after the current one?")
            )
            await player.clearUpNext()
            return .result(dialog: IntentDialog("Cleared the upcoming queue."))
        case .clearHistory:
            guard confirmed else {
                return .result(dialog: IntentDialog("Clearing queue history needs confirmation. Ask me again and confirm."))
            }
            try await requestConfirmation(
                conditions: [],
                actionName: .do,
                dialog: IntentDialog("Clear the tracks before the current one?")
            )
            await player.clearQueueHistory()
            return .result(dialog: IntentDialog("Cleared the queue history."))
        case .clear:
            guard confirmed else {
                return .result(dialog: IntentDialog("Clearing the whole queue needs confirmation. Ask me again and confirm."))
            }
            try await requestConfirmation(
                conditions: [],
                actionName: .do,
                dialog: IntentDialog("Stop playback and clear the entire queue?")
            )
            await player.stop()
            return .result(dialog: IntentDialog("Stopped playback and cleared the queue."))
        }
    }

    private func resolveSong() async -> DisplayableSong? {
        guard let catalog = await SiriBridge.catalogProvider?() else { return nil }
        if let song, let id = LumaEntityID(rawValue: song.id) {
            return await catalog.playableSong(id: id)
        }
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return nil
        }
        let matches = await catalog.songs(matching: query, limit: 2)
        guard matches.count == 1, let id = LumaEntityID(rawValue: matches[0].id) else { return nil }
        return await catalog.playableSong(id: id)
    }
}
