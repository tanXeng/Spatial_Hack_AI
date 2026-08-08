//
//  DefenseEngineTests.swift
//  TestTests
//

import Foundation
import Testing
import simd
@testable import Test

@MainActor
struct DefenseEngineTests {
    @Test
    func visualAndAudioBasisRemainUserRelativeAfterYaw() {
        let basis = DefenseSpatialBasis(
            rightDirection: SIMD3<Float>(0, 0, 1)
        )
        let slipLeft = basis.cuePosition(
            neutral: .zero,
            movement: .slipLeft,
            forwardDistance: 0.55,
            lateralMagnitude: 0.28
        )
        let slipRight = basis.cuePosition(
            neutral: .zero,
            movement: .slipRight,
            forwardDistance: 0.55,
            lateralMagnitude: 0.28
        )

        #expect(simd_distance(basis.forward, SIMD3<Float>(1, 0, 0)) < 0.0001)
        #expect(simd_distance(basis.right, SIMD3<Float>(0, 0, 1)) < 0.0001)
        #expect(simd_distance(slipLeft, SIMD3<Float>(0.55, 0, 0.28)) < 0.0001)
        #expect(simd_distance(slipRight, SIMD3<Float>(0.55, 0, -0.28)) < 0.0001)
    }

    @Test
    func neutralCalibrationAveragesOnlyFiniteStationaryPositionsForOneSecond() throws {
        var configuration = testConfiguration()
        configuration.minimumNeutralSamples = 3
        configuration.maximumNeutralSampleInterval = 0.60
        let engine = DefenseEngine(
            selectedDrill: .mixed,
            configuration: configuration
        )

        engine.beginNeutralCalibration(at: 0)
        engine.ingestDevicePosition(
            SIMD3<Float>(-0.01, 1.60, -0.20),
            capturedAt: 0
        )
        engine.ingestDevicePosition(
            SIMD3<Float>(repeating: .nan),
            capturedAt: 0.25
        )
        engine.ingestDevicePosition(
            SIMD3<Float>(0, 1.60, -0.20),
            capturedAt: 0.50
        )
        engine.ingestDevicePosition(
            SIMD3<Float>(0.01, 1.60, -0.20),
            capturedAt: 1.0
        )

        let calibrated = try #require(engine.neutralPosition)
        #expect(engine.phase == .ready)
        #expect(abs(calibrated.x) < 0.0001)
        #expect(abs(calibrated.y - 1.60) < 0.0001)
        #expect(abs(calibrated.z + 0.20) < 0.0001)
        #expect(engine.instruction.contains("head movement only"))
    }

    @Test
    func selectedDifficultyChangesCuePaceButNotMovementThresholds() throws {
        let configuration = testConfiguration()
        let engine = DefenseEngine(
            selectedDrill: .slipLeft,
            configuration: configuration
        )
        calibrate(engine)
        engine.start(at: 1, difficulty: .guided)
        engine.tick(at: 1)

        let cue = try #require(engine.currentCue)
        #expect(engine.activeDifficulty == .guided)
        #expect(abs((cue.expiresAt - cue.presentedAt) - 1.5) < 0.0001)
        #expect(engine.configuration.movementThreshold == configuration.movementThreshold)
        #expect(
            engine.configuration.maximumMovementDisplacement
                == configuration.maximumMovementDisplacement
        )
    }

    @Test
    func neutralCalibrationRestartsAfterGapOrLargeHeadMotion() {
        var configuration = testConfiguration()
        configuration.neutralCalibrationDuration = 0.20
        configuration.maximumNeutralSampleInterval = 0.10
        configuration.maximumNeutralDeviation = 0.03
        configuration.minimumNeutralSamples = 3

        let gapEngine = DefenseEngine(configuration: configuration)
        gapEngine.beginNeutralCalibration(at: 0)
        gapEngine.ingestDevicePosition(neutral, capturedAt: 0)
        gapEngine.ingestDevicePosition(neutral, capturedAt: 0.20)

        #expect(!gapEngine.isCalibrated)
        #expect(gapEngine.phase == .calibratingNeutral(progress: 0))
        #expect(gapEngine.instruction.contains("restarted"))

        let motionEngine = DefenseEngine(configuration: configuration)
        motionEngine.beginNeutralCalibration(at: 0)
        motionEngine.ingestDevicePosition(neutral, capturedAt: 0)
        motionEngine.ingestDevicePosition(
            neutral + SIMD3<Float>(0.08, 0, 0),
            capturedAt: 0.05
        )

        #expect(!motionEngine.isCalibrated)
        #expect(motionEngine.phase == .calibratingNeutral(progress: 0))
        #expect(motionEngine.instruction.contains("still"))
    }

    @Test
    func calibratedHeadsetRightAxisMakesSlipDirectionsUserRelative() throws {
        var configuration = testConfiguration()
        configuration.neutralCalibrationDuration = 0.10
        configuration.maximumNeutralSampleInterval = 0.10
        configuration.minimumNeutralSamples = 3
        let engine = DefenseEngine(
            selectedDrill: .slipLeft,
            configuration: configuration
        )
        let worldZIsUserRight = SIMD3<Float>(0, 0, 1)

        engine.beginNeutralCalibration(at: 0)
        engine.ingestDevicePosition(
            neutral,
            rightDirection: worldZIsUserRight,
            capturedAt: 0
        )
        engine.ingestDevicePosition(
            neutral,
            rightDirection: worldZIsUserRight,
            capturedAt: 0.05
        )
        engine.ingestDevicePosition(
            neutral,
            rightDirection: worldZIsUserRight,
            capturedAt: 0.10
        )
        engine.start(at: 0.10)
        engine.tick(at: 0.10)
        let cue = try #require(engine.currentCue)

        engine.ingestDevicePosition(
            neutral + SIMD3<Float>(0, 0, -0.15),
            capturedAt: cue.presentedAt + 0.10
        )
        engine.ingestDevicePosition(
            neutral,
            capturedAt: cue.presentedAt + 0.20
        )

        #expect(engine.attempts.first?.outcome == .success)
    }

    @Test
    func oversizedHeadMotionCancelsCueAndRequiresNeutralFreshCountdown() throws {
        let engine = activeEngine(drill: .slipRight)
        let cancelledCue = try #require(engine.currentCue)

        engine.ingestDevicePosition(
            neutral + SIMD3<Float>(0.60, 0, 0),
            capturedAt: cancelledCue.presentedAt + 0.10
        )

        #expect(engine.phase == .paused(reason: .excessiveMovement))
        #expect(engine.currentCue == nil)
        #expect(engine.attempts.isEmpty)
        #expect(engine.cancelledCueCount == 1)
        #expect(engine.trackingInterruptionCount == 0)
        #expect(engine.safetyBoundaryInterruptionCount == 1)
        #expect(engine.instruction.contains("return to neutral"))

        engine.ingestDevicePosition(
            movementPosition(for: .slipRight),
            capturedAt: cancelledCue.presentedAt + 0.20
        )
        engine.resume(at: cancelledCue.presentedAt + 0.20)

        #expect(engine.phase == .paused(reason: .excessiveMovement))
        #expect(engine.currentCue == nil)
        #expect(engine.attempts.isEmpty)

        engine.ingestDevicePosition(
            neutral,
            capturedAt: cancelledCue.presentedAt + 0.30
        )

        #expect(engine.phase == .paused(reason: .excessiveMovement))
        #expect(engine.attempts.isEmpty)

        engine.resume(at: cancelledCue.presentedAt + 0.30)

        #expect(engine.phase == .countdown(seconds: 0))
        #expect(engine.currentCue == nil)

        engine.tick(at: cancelledCue.presentedAt + 0.30)
        let freshCue = try #require(engine.currentCue)

        #expect(engine.phase == .active)
        #expect(freshCue.id != cancelledCue.id)
        #expect(engine.attempts.isEmpty)

        engine.ingestDevicePosition(
            movementPosition(for: .slipRight),
            capturedAt: freshCue.presentedAt + 0.10
        )
        engine.ingestDevicePosition(
            neutral,
            capturedAt: freshCue.presentedAt + 0.20
        )

        #expect(engine.attempts.count == 1)
        #expect(engine.attempts.first?.cue.id == freshCue.id)
        #expect(engine.attempts.first?.outcome == .success)

        var lastResolvedAt = freshCue.presentedAt + 0.20
        for _ in 1..<DefenseEngine.cueGoal {
            engine.tick(
                at: lastResolvedAt
                    + engine.configuration.interCueDelay
                    + 0.01
            )
            let cue = try #require(engine.currentCue)
            engine.ingestDevicePosition(
                movementPosition(for: .slipRight),
                capturedAt: cue.presentedAt + 0.10
            )
            engine.ingestDevicePosition(
                neutral,
                capturedAt: cue.presentedAt + 0.20
            )
            lastResolvedAt = cue.presentedAt + 0.20
        }

        let summary = try #require(engine.summary)
        #expect(summary.successfulAvoidances == DefenseEngine.cueGoal)
        #expect(summary.cancelledCues == 1)
        #expect(summary.trackingInterruptions == 0)
        #expect(summary.safetyBoundaryInterruptions == 1)

        let recommendation = TrainingIntensityAdvisor.recommendation(
            from: TrainingSetEvidence(
                kind: .defense,
                difficulty: summary.difficulty,
                completedOpportunities: summary.completedAttempts,
                minimumOpportunities: summary.cueGoal,
                primaryScore: 1,
                controlScore: nil,
                responseTimeRatio: 0.10,
                trackingInterruptions: summary.adaptiveEvidenceInterruptions
            )
        )
        #expect(recommendation.reason == .trackingInterrupted)
        #expect(!recommendation.proposesChange)
    }

    @Test
    func oversizedMovementBetweenCuesAlsoRequiresFreshCountdown() throws {
        let engine = activeEngine(drill: .slipRight)
        let firstCue = try #require(engine.currentCue)

        engine.ingestDevicePosition(
            movementPosition(for: .slipRight),
            capturedAt: firstCue.presentedAt + 0.10
        )
        engine.ingestDevicePosition(
            neutral,
            capturedAt: firstCue.presentedAt + 0.20
        )
        #expect(engine.attempts.count == 1)
        #expect(engine.currentCue == nil)

        engine.ingestDevicePosition(
            neutral + SIMD3<Float>(0.60, 0, 0),
            capturedAt: firstCue.presentedAt + 0.21
        )

        #expect(engine.phase == .paused(reason: .excessiveMovement))
        #expect(engine.currentCue == nil)
        #expect(engine.safetyBoundaryInterruptionCount == 1)
        #expect(engine.cancelledCueCount == 0)

        engine.ingestDevicePosition(
            neutral,
            capturedAt: firstCue.presentedAt + 0.30
        )
        engine.resume(at: firstCue.presentedAt + 0.30)
        #expect(engine.phase == .countdown(seconds: 0))

        engine.tick(at: firstCue.presentedAt + 0.30)
        #expect(engine.phase == .active)
        #expect(engine.currentCue != nil)
        #expect(engine.attempts.count == 1)
    }

    @Test
    func delayedPositionAndTimeReversedResumeAreRejected() throws {
        let engine = activeEngine(drill: .slipLeft)
        let cue = try #require(engine.currentCue)

        engine.tick(at: cue.presentedAt + 0.20)
        engine.ingestDevicePosition(
            movementPosition(for: .slipLeft),
            capturedAt: cue.presentedAt + 0.10
        )

        #expect(engine.attempts.isEmpty)
        #expect(engine.feedback == .cue(.slipLeft))

        engine.pause(reason: .userRequested, at: cue.presentedAt + 0.30)
        engine.resume(at: cue.presentedAt + 0.25)
        #expect(engine.phase == .paused(reason: .userRequested))
    }

    @Test
    func lateTimeoutTicksAccrueOnlyThroughCueDeadlines() throws {
        var configuration = testConfiguration()
        configuration.cueDuration = 0.50
        configuration.interCueDelay = 0
        let engine = activeEngine(
            drill: .slipLeft,
            configuration: configuration
        )

        for _ in 0..<DefenseEngine.cueGoal {
            let cue = try #require(engine.currentCue)
            engine.tick(at: max(cue.expiresAt + 1, cue.presentedAt + 1))
        }

        let summary = try #require(engine.summary)
        #expect(engine.phase == .completed)
        #expect(abs(summary.activeDuration - 3.0) < 0.0001)
    }

    @Test
    func leftRightAndDuckRequireReturnToNeutralBeforeScoring() throws {
        for drill in [
            DefenseDrill.slipLeft,
            DefenseDrill.slipRight,
            DefenseDrill.duck,
        ] {
            let engine = activeEngine(drill: drill)
            let cue = try #require(engine.currentCue)

            #expect(cue.expectedMovement == drill)
            #expect(engine.instruction.contains(drill.title))

            engine.ingestDevicePosition(
                movementPosition(for: drill),
                capturedAt: cue.presentedAt + 0.10
            )

            #expect(engine.attempts.isEmpty)
            #expect(engine.feedback == .returnToNeutral)

            engine.ingestDevicePosition(
                neutral,
                capturedAt: cue.presentedAt + 0.20
            )

            #expect(engine.attempts.count == 1)
            #expect(engine.attempts.first?.outcome == .success)
            #expect(engine.feedback.text == "\(drill.title) complete")
            #expect(abs(engine.progress - (1.0 / 6.0)) < 0.0001)
        }
    }

    @Test
    func wrongDirectionIsRecordedOnlyAfterNeutralReturn() throws {
        let engine = activeEngine(drill: .slipLeft)
        let cue = try #require(engine.currentCue)

        engine.ingestDevicePosition(
            movementPosition(for: .slipRight),
            capturedAt: cue.presentedAt + 0.10
        )

        #expect(engine.attempts.isEmpty)
        #expect(engine.feedback == .wrongDirection(
            expected: .slipLeft,
            detected: .slipRight
        ))
        #expect(engine.instruction.contains("Return your head to neutral"))

        engine.ingestDevicePosition(
            neutral,
            capturedAt: cue.presentedAt + 0.20
        )

        #expect(engine.attempts.count == 1)
        #expect(engine.attempts.first?.outcome == .wrongDirection(
            detected: .slipRight
        ))
        #expect(engine.feedback.text == "Move slip left")
    }

    @Test
    func missingNeutralReturnResolvesSeparatelyAndBlocksNextCue() throws {
        let engine = activeEngine(drill: .duck)
        let cue = try #require(engine.currentCue)

        engine.ingestDevicePosition(
            movementPosition(for: .duck),
            capturedAt: cue.presentedAt + 0.10
        )
        engine.tick(at: cue.expiresAt)

        #expect(engine.attempts.count == 1)
        #expect(engine.attempts.first?.outcome == .didNotReturn)
        #expect(engine.currentCue == nil)

        engine.tick(at: cue.expiresAt + 0.20)

        #expect(engine.currentCue == nil)
        #expect(engine.instruction.contains("neutral before the next cue"))

        engine.ingestDevicePosition(
            neutral,
            capturedAt: cue.expiresAt + 0.30
        )

        #expect(engine.currentCue != nil)
        #expect(engine.currentCue?.presentedAt == cue.expiresAt + 0.30)
    }

    @Test
    func stalePositionCancelsCueAndPausesWithoutMiss() {
        var configuration = testConfiguration()
        configuration.stalePositionInterval = 0.25
        let engine = activeEngine(
            drill: .mixed,
            configuration: configuration
        )

        #expect(engine.currentCue != nil)
        engine.tick(at: 1.26)

        #expect(engine.phase == .paused(reason: .staleDevicePosition))
        #expect(engine.currentCue == nil)
        #expect(engine.attempts.isEmpty)
        #expect(engine.cancelledCueCount == 1)
        #expect(engine.trackingInterruptionCount == 1)
        #expect(engine.progress == 0)

        engine.ingestDevicePosition(neutral, capturedAt: 1.27)
        engine.resume(at: 1.27)
        engine.tick(at: 1.27)

        #expect(engine.phase == .active)
        #expect(engine.currentCue != nil)
        #expect(engine.attempts.isEmpty)
        #expect(engine.cancelledCueCount == 1)
        #expect(engine.trackingInterruptionCount == 1)
    }

    @Test
    func trackingInterruptionDuringCountdownInvalidatesAdviceWithoutCancellingCue() throws {
        var configuration = testConfiguration()
        configuration.countdownDuration = 0.50
        let engine = DefenseEngine(
            selectedDrill: .slipLeft,
            configuration: configuration
        )
        calibrate(engine)
        engine.start(at: 1.0)

        engine.pause(reason: .systemInterruption, at: 1.10)

        #expect(engine.phase == .paused(reason: .systemInterruption))
        #expect(engine.cancelledCueCount == 0)
        #expect(engine.trackingInterruptionCount == 1)

        engine.ingestDevicePosition(neutral, capturedAt: 1.20)
        engine.resume(at: 1.20)
        engine.tick(at: 1.70)

        for index in 0..<DefenseEngine.cueGoal {
            let cue = try #require(engine.currentCue)
            engine.ingestDevicePosition(
                movementPosition(for: .slipLeft),
                capturedAt: cue.presentedAt + 0.10
            )
            engine.ingestDevicePosition(
                neutral,
                capturedAt: cue.presentedAt + 0.20
            )
            if index < DefenseEngine.cueGoal - 1 {
                engine.tick(
                    at: cue.presentedAt
                        + 0.20
                        + configuration.interCueDelay
                        + 0.01
                )
            }
        }

        let summary = try #require(engine.summary)
        #expect(summary.trackingInterruptions == 1)
        #expect(summary.cancelledCues == 0)
    }

    @Test
    func mixedSequenceAndCompletionSummaryAreDeterministic() throws {
        let engine = activeEngine(drill: .mixed)
        var observed: [DefenseDrill] = []

        for index in 0..<DefenseEngine.cueGoal {
            let cue = try #require(engine.currentCue)
            observed.append(cue.expectedMovement)

            engine.ingestDevicePosition(
                movementPosition(for: cue.expectedMovement),
                capturedAt: cue.presentedAt + 0.10
            )
            engine.ingestDevicePosition(
                neutral,
                capturedAt: cue.presentedAt + 0.20
            )

            if index < DefenseEngine.cueGoal - 1 {
                engine.tick(
                    at: cue.presentedAt
                        + 0.20
                        + engine.configuration.interCueDelay
                        + 0.01
                )
            }
        }

        #expect(observed == [
            .slipLeft,
            .slipRight,
            .duck,
            .slipRight,
            .slipLeft,
            .duck,
        ])
        #expect(engine.phase == .completed)
        #expect(engine.progress == 1)

        let summary = try #require(engine.summary)
        #expect(summary.completedAttempts == 6)
        #expect(summary.successfulAvoidances == 6)
        #expect(summary.wrongDirections == 0)
        #expect(summary.missedReturns == 0)
        #expect(summary.timeouts == 0)
        #expect(summary.cancelledCues == 0)
        #expect(summary.trackingInterruptions == 0)
        #expect(abs((summary.averageSuccessfulResponseTime ?? 0) - 0.10) < 0.0001)
        #expect(summary.activeDuration > 0)
        #expect(summary.metricScopeLabel == "Head movement only")
    }

    @Test
    func completedResultsSurviveImmersiveExitWhileNeutralCalibrationDoesNot() throws {
        let engine = activeEngine(drill: .slipLeft)

        for index in 0..<DefenseEngine.cueGoal {
            let cue = try #require(engine.currentCue)
            engine.ingestDevicePosition(
                movementPosition(for: .slipLeft),
                capturedAt: cue.presentedAt + 0.10
            )
            engine.ingestDevicePosition(
                neutral,
                capturedAt: cue.presentedAt + 0.20
            )

            if index < DefenseEngine.cueGoal - 1 {
                engine.tick(
                    at: cue.presentedAt
                        + 0.20
                        + engine.configuration.interCueDelay
                        + 0.01
                )
            }
        }

        let completedAttempts = engine.attempts
        let completedSummary = try #require(engine.summary)
        #expect(engine.phase == .completed)
        #expect(engine.isCalibrated)

        engine.stop()
        #expect(engine.phase == .completed)
        #expect(engine.summary == completedSummary)

        engine.leaveImmersiveSpace()

        #expect(engine.phase == .completed)
        #expect(!engine.isCalibrated)
        #expect(engine.attempts == completedAttempts)
        #expect(engine.summary == completedSummary)
        #expect(engine.progress == 1)
        #expect(engine.instruction.contains("Review head-movement metrics"))
    }

    private var neutral: SIMD3<Float> {
        SIMD3<Float>(0, 1.60, -0.20)
    }

    private func testConfiguration() -> DefenseConfiguration {
        var configuration = DefenseConfiguration.provisional
        configuration.countdownDuration = 0
        configuration.cueDuration = 1.0
        configuration.interCueDelay = 0.10
        configuration.movementThreshold = 0.10
        configuration.neutralReturnRadius = 0.04
        configuration.stalePositionInterval = 10.0
        return configuration
    }

    private func activeEngine(
        drill: DefenseDrill,
        configuration: DefenseConfiguration? = nil
    ) -> DefenseEngine {
        let engine = DefenseEngine(
            selectedDrill: drill,
            configuration: configuration ?? testConfiguration()
        )
        calibrate(engine)
        engine.start(at: 1.0)
        engine.tick(at: 1.0)
        #expect(engine.phase == .active)
        #expect(engine.currentCue != nil)
        return engine
    }

    private func calibrate(_ engine: DefenseEngine) {
        engine.beginNeutralCalibration(at: 0)
        for index in 0...20 {
            engine.ingestDevicePosition(
                neutral,
                capturedAt: Double(index) * 0.05
            )
        }
        #expect(engine.phase == .ready)
        #expect(engine.isCalibrated)
    }

    private func movementPosition(for drill: DefenseDrill) -> SIMD3<Float> {
        switch drill {
        case .slipLeft:
            neutral + SIMD3<Float>(-0.15, 0, 0)
        case .slipRight:
            neutral + SIMD3<Float>(0.15, 0, 0)
        case .duck:
            neutral + SIMD3<Float>(0, -0.15, 0)
        case .mixed:
            neutral
        }
    }
}
