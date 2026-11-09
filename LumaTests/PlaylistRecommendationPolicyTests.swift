import Foundation
import Testing
import SwiftSonic
@testable import Luma

@Suite("Playlist recommendation priority")
struct PlaylistRecommendationPolicyTests {
    private func mix(_ kind: PersonalMixKind, tracks: Int = 2) -> PersonalMix {
        PersonalMix(
            kind: kind,
            tracks: (0..<tracks).map { DisplayableSong(from: Song(id: "\(kind.rawValue)-\($0)", title: "Track", duration: 180)) },
            artistNames: ["Artist"]
        )
    }

    @Test func focalMixesAppearInStableOrder() {
        let ordered = PlaylistRecommendationPolicy.ordered([
            mix(.newMusic), mix(.essentials), mix(.heavyRotation), mix(.getUp), mix(.chill), mix(.focus)
        ])
        #expect(ordered.map(\.kind) == [.getUp, .heavyRotation, .essentials, .newMusic, .chill, .focus])
    }

    @Test func emptyAndDuplicateMixesDoNotShiftTheShelf() {
        let ordered = PlaylistRecommendationPolicy.ordered([
            mix(.getUp, tracks: 0),
            mix(.heavyRotation),
            mix(.heavyRotation),
            mix(.newMusic)
        ])
        #expect(ordered.map(\.kind) == [.heavyRotation, .newMusic])
    }

    @Test func everyGeneratedMixKindHasANonZeroStablePosition() {
        let ordered = PlaylistRecommendationPolicy.ordered([
            mix(.focus), mix(.chill), mix(.essentials)
        ])
        #expect(ordered.map(\.kind) == [.essentials, .chill, .focus])
    }
}
