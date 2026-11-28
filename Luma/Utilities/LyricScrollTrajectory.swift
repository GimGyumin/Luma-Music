// Luma — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.

import Foundation

/// Presentation only. A new target starts from the last displayed position and velocity.
nonisolated struct LyricScrollTrajectory {
    struct Sample: Equatable {
        let offset: Double
        let velocity: Double
    }

    let start: Sample
    let target: Double
    let response: Double

    func sample(at elapsed: Double) -> Sample {
        let t = max(0, elapsed)
        let displacement = start.offset - target
        let slope = start.velocity + response * displacement
        let decay = exp(-response * t)
        return Sample(
            offset: target + (displacement + slope * t) * decay,
            velocity: (start.velocity - response * slope * t) * decay
        )
    }

    static func forward(from start: Sample, to proposedTarget: Double, cadence: LyricScrollCadence) -> Self {
        let target = max(start.offset, proposedTarget)
        let response = response(from: start, to: target, cadence: cadence)
        // A critically damped trajectory stays on this side of the target when
        // its incoming speed is at most response × distance.
        let velocity = min(max(0, start.velocity), response * (target - start.offset))
        return Self(start: Sample(offset: start.offset, velocity: velocity), target: target, response: response)
    }

    static func response(from start: Sample, to target: Double, cadence: LyricScrollCadence) -> Double {
        let distance = abs(target - start.offset)
        // A critical spring traverses about 90% of its distance in four time constants.
        let desired = 4 / cadence.travelTime
        // From rest, a critical spring peaks at distance * response / e.
        let distanceLimit = 2_400 * exp(1.0) / max(1, distance)
        let base = max(5, min(desired, distanceLimit))
        let towardsTarget = start.velocity * (target >= start.offset ? 1 : -1)
        // Keep a same-direction retarget monotonic when there is room to brake.
        // A nearby layout correction still preserves the incoming velocity.
        return max(base, min(48, towardsTarget / max(1, distance)))
    }
}

nonisolated struct LyricScrollCadence {
    let previousStart: Int?
    let currentStart: Int?
    let nextStart: Int?
    let playbackTime: Int

    var travelTime: Double {
        let previousGap = Self.seconds(from: previousStart, to: currentStart)
        let nextGap = Self.seconds(from: currentStart, to: nextStart)
        let remaining = nextStart.map { max(0, Double($0) - Double(playbackTime)) / 1_000 }
        // Let the upcoming line shorten the response, even after a long verse.
        // Ignore zero-length timestamp groups; they are still selected by the lyric timeline.
        let window = [previousGap, nextGap, remaining].compactMap { $0 }.min() ?? 0.8
        return min(0.48, max(0.11, sqrt(window) * 0.43))
    }

    static func trackingDelay(budget: UInt64, milliseconds: Int, nextStart: Int?) -> UInt64 {
        guard let nextStart, nextStart > milliseconds else { return budget }
        let nanos = (Double(nextStart) - Double(milliseconds)) * 1_000_000
        guard nanos < Double(budget) else { return budget }
        // Bound the work for malformed clusters without lowering the normal tracking cadence.
        return min(budget, max(8_000_000, UInt64(nanos)))
    }

    private static func seconds(from first: Int?, to second: Int?) -> Double? {
        guard let first, let second, second > first else { return nil }
        return (Double(second) - Double(first)) / 1_000
    }
}
