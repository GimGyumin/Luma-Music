import CoreSpotlight
import Foundation

/// One query per debounced input. The same named index supplies system and in-app search.
@available(iOS 27.0, macOS 27.0, *)
nonisolated enum SpotlightQueryAdapter {
    struct Result: Sendable { var keys: [String]; var suggestions: [String] }
    static func search(_ text: String, scope: String, limit: Int) async throws -> Result {
        guard limit > 0 else { return Result(keys: [], suggestions: []) }
        let context = CSUserQueryContext()
        context.fetchAttributes = ["title", "contentURL"]
        let escaped = scope.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        context.filterQueries = ["domainIdentifier == \"\(escaped)\""]
        context.enableRankedResults = true
        context.disableSemanticSearch = false
        context.maxResultCount = min(limit, 240)
        context.maxSuggestionCount = 3
        let query = CSUserQuery(userQueryString: text, userQueryContext: context)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(1)); query.cancel() } catch {}
        }
        defer { timeout.cancel(); query.cancel() }
        return try await withTaskCancellationHandler {
            var items: [CSUserQuery.Item] = []
            var suggestions: [CSUserQuery.Suggestion] = []
            for try await response in query.responses {
                try Task.checkCancellation()
                switch response {
                case .item(let found) where found.item.domainIdentifier == scope:
                    items.append(found)
                case .suggestion(let suggestion): suggestions.append(suggestion)
                default: break
                }
            }
            try Task.checkCancellation()
            var seen = Set<String>()
            return Result(keys: items.sorted().compactMap {
                seen.insert($0.item.uniqueIdentifier).inserted ? $0.item.uniqueIdentifier : nil
            }, suggestions: suggestions.sorted().map { String($0.suggestion.localizedAttributedSuggestion.characters) })
        } onCancel: { query.cancel() }
    }
}
