import Foundation
import Testing
@testable import Luma

struct LyricAdaptiveScrollTests {
    @Test func adaptsToUpcomingTimeRemainingAndMeasuredDistance() {
        let slow = LyricScrollCadence(previousStart: 0, currentStart: 1_200, nextStart: 3_000, playbackTime: 1_200)
        let rapid = LyricScrollCadence(previousStart: 0, currentStart: 1_200, nextStart: 1_450, playbackTime: 1_200)
        let late = LyricScrollCadence(previousStart: 0, currentStart: 1_200, nextStart: 1_450, playbackTime: 1_410)
        #expect(late.travelTime < rapid.travelTime)
        #expect(rapid.travelTime < slow.travelTime)
        let start = LyricScrollTrajectory.Sample(offset: 0, velocity: 0)
        let short = LyricScrollTrajectory.response(from: start, to: 75, cadence: rapid)
        let wrapped = LyricScrollTrajectory.response(from: start, to: 530, cadence: rapid)
        #expect(wrapped < short)
    }

    @Test(arguments: [60.0, 120.0])
    func sixRapidWrappedRowsPreserveOffsetAndVelocity(_ refreshRate: Double) {
        let starts = [0, 115, 220, 340, 485, 610, 735, 895]
        let offsets = [0.0, 75, 150, 307, 381, 462, 538]
        var state = LyricScrollTrajectory.Sample(offset: 0, velocity: 0)
        for i in 1..<offsets.count {
            let interval = Double(starts[i + 1] - starts[i]) / 1_000
            let cadence = LyricScrollCadence(previousStart: starts[i - 1], currentStart: starts[i],
                nextStart: starts[i + 1], playbackTime: starts[i])
            let trajectory = LyricScrollTrajectory(start: state, target: offsets[i],
                response: LyricScrollTrajectory.response(from: state, to: offsets[i], cadence: cadence))
            #expect(abs(trajectory.sample(at: 0).offset - state.offset) < 0.0001)
            #expect(abs(trajectory.sample(at: 0).velocity - state.velocity) < 0.0001)
            if i > 1 { #expect(state.velocity > 0) }
            var last = state
            for frame in 1...Int(interval * refreshRate) {
                let next = trajectory.sample(at: Double(frame) / refreshRate)
                #expect(next.offset >= last.offset)
                #expect(next.offset - last.offset < 2_500 / refreshRate)
                last = next
            }
            state = trajectory.sample(at: interval)
            #expect(offsets[i] - state.offset < 65)
        }
    }

    @Test func forwardRetargetBrakesWithoutPassingItsDestination() {
        let cadence = LyricScrollCadence(previousStart: 0, currentStart: 100, nextStart: 200, playbackTime: 100)
        let start = LyricScrollTrajectory.Sample(offset: 100, velocity: 2_000)
        let motion = LyricScrollTrajectory.forward(from: start, to: 103, cadence: cadence)
        var last = start.offset
        for frame in 1...120 {
            let offset = motion.sample(at: Double(frame) / 120).offset
            #expect(offset >= last && offset <= 103)
            last = offset
        }
        let behind = LyricScrollTrajectory.forward(from: start, to: 99, cadence: cadence)
        #expect(behind.sample(at: 0.2).offset == start.offset)
    }

    @Test func duplicateTimestampsRemainSimultaneousAndNearbyBoundariesWakeTracking() {
        let rows = [1_000, 1_000, 1_110, 1_215].enumerated().map { index, time in
            LyricDisplayRow(sourceLineIndex: index, text: "Line", startMs: time, endMs: time + 100,
                cueLine: nil, isSecondaryAgent: index == 1, speakerSide: .leading)
        }
        let timeline = LyricPlaybackTimeline(rows: rows)
        #expect(timeline.activeRows(for: 1_000).indices == [0, 1])
        #expect(timeline.activeRows(for: 1_000).primary == 0)
        #expect(timeline.activeRows(for: 1_111).primary == 2)
        #expect(timeline.activeRows(for: 1_220).primary == 3)
        #expect(timeline.activeRows(for: 1_010).primary == 0) // backward seek
        #expect(timeline.latestStartedLead(at: 999) == nil)
        #expect(timeline.latestStartedLead(at: 1_000) == 0)
        #expect(timeline.latestStartedLead(at: 1_109) == 0)
        #expect(timeline.latestStartedLead(at: 1_110) == 2)
        #expect(timeline.nextStart(after: 1_000) == 1_110)
        #expect(timeline.nextStart(after: 1_215) == nil)
        #expect(LyricScrollCadence.trackingDelay(budget: 150_000_000,
            milliseconds: 1_000, nextStart: 1_110) == 110_000_000)
        #expect(LyricScrollCadence.trackingDelay(budget: 100_000_000,
            milliseconds: 1_000, nextStart: 1_001) == 8_000_000)
    }

    @Test func userScrollSuspensionAndResumeKeepTheirExistingOwnership() {
        for state: LyricsFollowState in [.userDragging, .userReading, .suspended] {
            #expect(!state.allowsAutomaticScroll)
        }
        for state: LyricsFollowState in [.reacquiringFollow, .followingPlayback, .seeking] {
            #expect(state.allowsAutomaticScroll)
        }
    }
}
