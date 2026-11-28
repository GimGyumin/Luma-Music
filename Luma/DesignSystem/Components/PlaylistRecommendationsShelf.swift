/// Orders the playable personal mixes in Home’s playlist shelf.
nonisolated enum PlaylistRecommendationPolicy {
    static let priority: [PersonalMixKind] = [
        .getUp, .heavyRotation, .essentials, .newMusic, .chill, .focus
    ]

    static func ordered(_ mixes: [PersonalMix]) -> [PersonalMix] {
        var byKind: [PersonalMixKind: PersonalMix] = [:]
        for mix in mixes where !mix.tracks.isEmpty {
            byKind[mix.kind] = mix
        }
        return priority.compactMap { byKind[$0] }
    }
}
