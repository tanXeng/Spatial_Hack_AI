import Foundation
import simd
import Testing
@testable import BoxingCoach

@Suite("Task 4 review regressions")
struct Task4ReviewRegressionTests {
    @Test("A selected reactive punch with a lost required hand discards without scoring")
    func selectedReactiveRequiredHandLossDiscardsWithoutScoring() {
        let interruptedInputs = [
            (required: false, other: true, device: true),
            (required: true, other: false, device: true),
            (required: true, other: true, device: false)
        ]

        for input in interruptedInputs {
            let decision = ReactiveTargetTrackingPolicy.decision(
                selectedSide: .left,
                requiredHandAvailable: input.required,
                otherHandAvailable: input.other,
                devicePoseAvailable: input.device
            )

            #expect(decision == .discardAndRetry)
            #expect(decision.recordsMetric == false)
            #expect(decision.flashesTarget == false)
            #expect(decision.isRankable == false)
        }
    }

    @Test("A short competition tracking outage pauses the target deadline")
    func shortCompetitionOutageCompensatesDeadline() {
        #expect(
            CompetitionTrackingOutagePolicy.decision(
                trackingAvailable: false,
                lossDuration: 0.349
            ) == .wait
        )
        #expect(
            CompetitionTrackingOutagePolicy.decision(
                trackingAvailable: false,
                lossDuration: 0.350
            ) == .recover
        )
        #expect(
            CompetitionTrackingOutagePolicy.decision(
                trackingAvailable: true,
                lossDuration: 0.349
            ) == .resume(pausedDuration: 0.349)
        )
        #expect(
            CompetitionTrackingOutagePolicy.decision(
                trackingAvailable: true,
                lossDuration: 0.350
            ) == .recover
        )
        #expect(
            CompetitionTrackingOutagePolicy.decision(
                trackingAvailable: true,
                lossDuration: 0.351
            ) == .recover
        )

        let deadline = Date(timeIntervalSinceReferenceDate: 20)
        let resumed = CompetitionTrackingOutagePolicy.compensatedDeadline(
            deadline,
            pausedDuration: 0.349
        )
        #expect(resumed.timeIntervalSinceReferenceDate == 20.349)
    }

    @Test("Competition elapsed time counts each tracking outage exactly once")
    func competitionElapsedTimeExcludesCompleteOutagesWithoutDoubleCounting() {
        var clock = CompetitionElapsedClock()

        clock.beginPause(at: 1.000)
        clock.beginPause(at: 1.100) // Repeated missing polls do not restart the outage.
        #expect(abs(clock.endPause(at: 1.349) - 0.349) < 0.000_001)
        #expect(clock.endPause(at: 1.500) == 0) // The same short outage cannot count twice.

        clock.beginPause(at: 2.000)
        clock.beginPause(at: 2.350) // Entering stable recovery keeps the original loss origin.
        #expect(abs(clock.endPause(at: 2.700) - 0.700) < 0.000_001)
        #expect(abs(clock.pausedDuration - 1.049) < 0.000_001)
        #expect(
            abs(clock.activeElapsed(startedAt: 0, endedAt: 5) - 3.951) < 0.000_001
        )
    }

    @Test("Ranked target setup opens elapsed pause before a missing body-frame wait")
    func rankedBodyFrameWaitRetainsFirstMissingTimestampThroughRecovery() {
        var clock = CompetitionElapsedClock()

        let genericWaitAccountsPause = clock.beginBodyFrameWaitIfNeeded(
            frameAvailable: false,
            rankedRoundActive: true,
            at: 1.000
        )
        #expect(genericWaitAccountsPause)
        let combinationWaitRetainsPause = clock.beginBodyFrameWaitIfNeeded(
            frameAvailable: false,
            rankedRoundActive: true,
            at: 2.500
        )
        #expect(combinationWaitRetainsPause)
        clock.beginPause(at: 2.750) // Stable recovery must not restart the missing-frame pause.
        #expect(abs(clock.endPause(at: 3.000) - 2.000) < 0.000_001)
        #expect(abs(clock.activeElapsed(startedAt: 0, endedAt: 5) - 3.000) < 0.000_001)

        var ordinaryClock = CompetitionElapsedClock()
        let ordinaryWaitAccountsPause = ordinaryClock.beginBodyFrameWaitIfNeeded(
            frameAvailable: false,
            rankedRoundActive: false,
            at: 1.000
        )
        #expect(ordinaryWaitAccountsPause == false)
        #expect(ordinaryClock.endPause(at: 2.000) == 0)
    }

    @Test("A generic evidence retry retains the exact target position and entity")
    func genericRetryRetainsPhysicalTarget() {
        let position = SIMD3<Float>(0.12, 1.34, -0.56)
        var plan = ReactiveTargetRetryPlan(targetPosition: position)

        plan.record(.retry)
        #expect(plan.targetPosition == position)
        plan.record(.retry)
        #expect(plan.targetPosition == position)

        let targets = TargetController()
        let firstEntity = targets.spawnTarget(at: position, radius: 0.08)
        let retryEntity = targets.spawnTarget(at: position, radius: 0.08)
        #expect(firstEntity === retryEntity)
        #expect(targets.activeTargetPosition == position)

        plan.record(.completed)
        #expect(plan.targetPosition == nil)
    }

    @Test(
        "Aura scored either-hand punches alternate physical sides by stance",
        arguments: [
            (Stance.orthodox, [BodySide.left, .right, .left, .right]),
            (Stance.southpaw, [BodySide.right, .left, .right, .left])
        ]
    )
    func auraScoredEitherHandAlternates(
        stance: Stance,
        expectedSides: [BodySide]
    ) {
        let scoredSides = (1...4).map {
            AuraPunchSideSequence.side(
                forRepetition: $0,
                technique: .uppercut,
                stance: stance
            )
        }

        #expect(scoredSides == expectedSides)
        #expect(
            AuraPunchSideSequence.side(
                forRepetition: 2,
                technique: .jab,
                stance: stance
            ) == stance.leadSide
        )
        #expect(
            AuraPunchSideSequence.side(
                forRepetition: 2,
                technique: .cross,
                stance: stance
            ) == stance.rearSide
        )
    }
}
