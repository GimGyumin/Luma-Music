import Foundation

nonisolated struct SpotlightWorkDeferred: Error {}

nonisolated struct SpotlightWorkBudget: Sendable {
    let batchSize: Int
    let pause: Duration
    static let unrestricted = Self(batchSize: 160, pause: .zero)

    static func make(active: Bool, playing: Bool, lowPower: Bool, thermal: ThermalPressure) throws -> Self {
        guard active, thermal < .serious else { throw SpotlightWorkDeferred() }
        if playing { return Self(batchSize: 24, pause: .milliseconds(200)) }
        if lowPower || thermal == .fair { return Self(batchSize: 40, pause: .milliseconds(100)) }
        return .unrestricted
    }
}
