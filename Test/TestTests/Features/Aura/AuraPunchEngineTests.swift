//
//  AuraPunchEngineTests.swift
//  TestTests
//

import Foundation
import Testing
import simd
@testable import Test

@MainActor
struct AuraPunchEngineTests {
    @Test
    func guideProgressAnimatesOutAndBackDeterministically() throws {
        let profile = calibration()
        let engine = makeEngine()

        engine.start(using: profile, at: 10)

        #expect(engine.phase == .demonstrating)
        #expect(engine.guideProgress == 0)
        #expect(engine.expectedHand == .left)
        let startPosition = try #require(engine.currentGuidePosition)
        #expect(simd_distance(startPosition, profile.leftGuard) < 0.0001)

        engine.tick(at: 10.5)

        #expect(abs(engine.guideProgress - 0.5) < 0.0001)
        let midpoint = try #require(engine.currentGuidePosition)
        let target = profile.targetPosition(
            for: .jab,
            configuration: engine.configuration
        )
        #expect(simd_distance(midpoint, target) < 0.0001)

        let path = engine.guidePath(pointCount: 7)
        #expect(path.count == 7)
        #expect(simd_distance(path[0], profile.leftGuard) < 0.0001)
        #expect(simd_distance(path[3], target) < 0.0001)
        #expect(simd_distance(path[6], profile.leftGuard) < 0.0001)

        engine.tick(at: 11)

        #expect(engine.phase == .following)
        #expect(engine.guideProgress == 1)
        let returnedPosition = try #require(engine.currentGuidePosition)
        #expect(simd_distance(returnedPosition, profile.leftGuard) < 0.0001)
    }

    @Test
    func startRefusesAlreadyUnavailableTracking() {
        let engine = makeEngine()

        engine.start(
            using: calibration(),
            at: 10,
            trackingReady: false
        )

        #expect(engine.phase == .idle)
        #expect(engine.summary == nil)
        #expect(engine.instruction.contains("Both hands"))
    }

    @Test
    func selectedDifficultyChangesGuidePresentationAndIsCapturedInSummary() throws {
        let profile = calibration()
        let engine = makeEngine()

        engine.start(using: profile, at: 10, difficulty: .guided)
        #expect(engine.activeDifficulty == .guided)
        #expect(engine.activePathPointCount == 15)
        engine.tick(at: 11)
        #expect(engine.phase == .demonstrating)
        engine.tick(at: 11.61)
        #expect(engine.phase == .following)

        performRepetition(engine: engine, profile: profile, startingAt: 12)
        performRepetition(engine: engine, profile: profile, startingAt: 13)
        performRepetition(engine: engine, profile: profile, startingAt: 14)

        let summary = try #require(engine.summary)
        #expect(summary.difficulty == .guided)
        #expect(summary.trackingInterruptions == 0)
    }

    @Test
    func trackingPauseIsCapturedForRecommendationSafety() throws {
        let profile = calibration()
        let engine = makeEngine()
        engine.start(using: profile, at: 0, difficulty: .sharp)
        engine.pause(reason: "Tracking unavailable")
        engine.resume(at: 1)
        engine.tick(at: 1.8)
        #expect(engine.phase == .following)

        performRepetition(engine: engine, profile: profile, startingAt: 2)
        performRepetition(engine: engine, profile: profile, startingAt: 3)
        performRepetition(engine: engine, profile: profile, startingAt: 4)

        let summary = try #require(engine.summary)
        #expect(summary.difficulty == .sharp)
        #expect(summary.trackingInterruptions == 1)
    }

    @Test
    func threePerfectRepetitionsCompleteTheSet() throws {
        let profile = calibration()
        let engine = followingEngine(profile: profile)

        performRepetition(engine: engine, profile: profile, startingAt: 1)
        performRepetition(engine: engine, profile: profile, startingAt: 2)
        performRepetition(engine: engine, profile: profile, startingAt: 3)

        #expect(engine.phase == .completed)
        #expect(engine.repetitionResults.count == 3)
        #expect(engine.repetitionResults.allSatisfy { $0.overallScore > 0.99 })
        #expect(engine.repetitionResults.allSatisfy { $0.trajectoryShapeScore != nil })
        let summary = try #require(engine.summary)
        #expect(summary.completedRepetitions == 3)
        #expect(summary.repetitionGoal == 3)
        #expect(summary.averageScore > 0.99)
        #expect((summary.averageTrajectoryShapeScore ?? 0) > 0.90)
        #expect(summary.expectedHand == .left)
    }

    @Test
    func setTrajectoryDiagnosticRequiresEveryRepetition() {
        let covered = repetitionResult(
            repetition: 1,
            trajectoryShapeScore: 0.92
        )
        let missing = repetitionResult(
            repetition: 2,
            trajectoryShapeScore: nil
        )

        let partialSummary = AuraPunchSummary(
            results: [covered, missing],
            repetitionGoal: 2
        )
        let completeSummary = AuraPunchSummary(
            results: [covered, repetitionResult(
                repetition: 2,
                trajectoryShapeScore: 0.88
            )],
            repetitionGoal: 2
        )

        #expect(partialSummary.averageTrajectoryShapeScore == nil)
        #expect(abs((completeSummary.averageTrajectoryShapeScore ?? 0) - 0.90) < 0.000_001)
    }

    @Test
    func completedResultsSurviveStopThenImmersiveExit() throws {
        let profile = calibration()
        let engine = followingEngine(profile: profile)
        performRepetition(engine: engine, profile: profile, startingAt: 1)
        performRepetition(engine: engine, profile: profile, startingAt: 2)
        performRepetition(engine: engine, profile: profile, startingAt: 3)
        let completedSummary = try #require(engine.summary)

        engine.stop()
        #expect(engine.phase == .completed)
        #expect(engine.summary == completedSummary)

        engine.leaveImmersiveSpace()
        #expect(engine.phase == .completed)
        #expect(engine.summary == completedSummary)
    }

    @Test
    func offsetPathScoresLowerThanGuideAlignedPath() throws {
        let profile = calibration()
        let alignedEngine = followingEngine(profile: profile)
        let offsetEngine = followingEngine(profile: profile)

        performRepetition(
            engine: alignedEngine,
            profile: profile,
            startingAt: 1
        )
        performRepetition(
            engine: offsetEngine,
            profile: profile,
            startingAt: 1,
            pathOffset: SIMD3<Float>(0.09, 0, 0)
        )

        let aligned = try #require(alignedEngine.repetitionResults.first)
        let offset = try #require(offsetEngine.repetitionResults.first)
        #expect(offset.averagePathDeviation > aligned.averagePathDeviation)
        #expect(offset.pathScore < aligned.pathScore)
        #expect(
            (offset.trajectoryShapeScore ?? 1)
                < (aligned.trajectoryShapeScore ?? 0)
        )
        #expect(offset.overallScore < aligned.overallScore)
    }

    @Test
    func paceIsReportedButDoesNotChangeTheGuideScore() throws {
        let profile = calibration()
        let fasterEngine = followingEngine(profile: profile)
        let slowerEngine = followingEngine(profile: profile)

        performRepetition(
            engine: fasterEngine,
            profile: profile,
            startingAt: 1,
            stepInterval: 0.04
        )
        performRepetition(
            engine: slowerEngine,
            profile: profile,
            startingAt: 1,
            stepInterval: 0.16
        )

        let faster = try #require(fasterEngine.repetitionResults.first)
        let slower = try #require(slowerEngine.repetitionResults.first)
        #expect(faster.relativePeakSpeed > slower.relativePeakSpeed)
        #expect(abs(faster.overallScore - slower.overallScore) < 0.0001)
    }

    @Test
    func expectedHandsUseIndependentProjectedReferencePace() throws {
        let profile = CalibrationProfile(
            stance: .orthodox,
            leftGuard: SIMD3<Float>(-0.10, 1.30, -0.35),
            rightGuard: SIMD3<Float>(0.10, 1.30, -0.35),
            leftHand: HandCalibrationProfile(
                acceptedFunctionalReach: 0.50,
                targetPlacementReach: 0.50,
                straightPunchDirection: SIMD3<Float>(0, 0, -1),
                referenceProjectedPace: 0.50
            ),
            rightHand: HandCalibrationProfile(
                acceptedFunctionalReach: 0.50,
                targetPlacementReach: 0.50,
                straightPunchDirection: SIMD3<Float>(0, 0, -1),
                referenceProjectedPace: 2.0
            )
        )
        let jabEngine = followingEngine(
            profile: profile,
            selectedPunch: .jab
        )
        let crossEngine = followingEngine(
            profile: profile,
            selectedPunch: .cross
        )

        performRepetition(
            engine: jabEngine,
            profile: profile,
            startingAt: 1
        )
        performRepetition(
            engine: crossEngine,
            profile: profile,
            startingAt: 1
        )

        let jab = try #require(jabEngine.repetitionResults.first)
        let cross = try #require(crossEngine.repetitionResults.first)
        #expect(abs(jab.peakSpeed - cross.peakSpeed) < 0.0001)
        #expect(abs(jab.relativePeakSpeed / cross.relativePeakSpeed - 4) < 0.001)
    }

    @Test
    func overextensionSummaryPreservesRawRatioAndControlPenalty() throws {
        let profile = calibration()
        let engine = followingEngine(profile: profile)

        performRepetition(
            engine: engine,
            profile: profile,
            startingAt: 1,
            extensionScale: 1.30
        )
        performRepetition(
            engine: engine,
            profile: profile,
            startingAt: 2,
            extensionScale: 1.30
        )
        performRepetition(
            engine: engine,
            profile: profile,
            startingAt: 3,
            extensionScale: 1.30
        )

        let summary = try #require(engine.summary)
        #expect(abs(summary.averageExtensionRatio - 1.30) < 0.001)
        #expect(abs(summary.averageExtensionScore - 0.40) < 0.001)
        #expect(summary.averageExtensionScore < 1)
    }

    @Test
    func insufficientExtensionIsIgnored() {
        let profile = calibration()
        let engine = followingEngine(profile: profile)
        let hand = profile.hand(for: engine.selectedPunch)
        let guardPosition = profile.guardPosition(for: hand)
        let targetPosition = profile.targetPosition(
            for: engine.selectedPunch,
            configuration: engine.configuration
        )

        engine.ingest(sample(
            profile: profile,
            timestamp: 1,
            moving: hand,
            position: guardPosition
        ))
        for (index, fraction) in [Float(0.20), 0.40, 0.20, 0].enumerated() {
            engine.ingest(sample(
                profile: profile,
                timestamp: 1.1 + Double(index) * 0.1,
                moving: hand,
                position: interpolate(
                    from: guardPosition,
                    to: targetPosition,
                    fraction: fraction
                )
            ))
        }

        #expect(engine.phase == .following)
        #expect(engine.repetitionResults.isEmpty)
        #expect(engine.feedback?.contains("Extend farther") == true)
    }

    @Test
    func wrongHandDoesNotCountAndUnstableGuardHandLowersScore() throws {
        let profile = calibration()
        let perfectEngine = followingEngine(profile: profile)
        let unstableEngine = followingEngine(profile: profile)
        let expectedHand = try #require(unstableEngine.expectedHand)
        let otherHand: HandSide = expectedHand == .left ? .right : .left

        unstableEngine.ingest(sample(
            profile: profile,
            timestamp: 0.8,
            moving: expectedHand,
            position: profile.guardPosition(for: expectedHand)
        ))
        unstableEngine.ingest(sample(
            profile: profile,
            timestamp: 0.9,
            moving: otherHand,
            position: profile.guardPosition(for: otherHand)
                + SIMD3<Float>(0, 0, -0.28)
        ))
        #expect(unstableEngine.repetitionResults.isEmpty)

        performRepetition(
            engine: perfectEngine,
            profile: profile,
            startingAt: 1
        )
        performRepetition(
            engine: unstableEngine,
            profile: profile,
            startingAt: 1,
            otherHandOffset: SIMD3<Float>(0, 0, -0.24)
        )

        let perfect = try #require(perfectEngine.repetitionResults.first)
        let unstable = try #require(unstableEngine.repetitionResults.first)
        #expect(unstable.otherHandGuardScore < perfect.otherHandGuardScore)
        #expect(unstable.overallScore < perfect.overallScore)
    }

    @Test
    func pauseAndResumeInvalidateAPartialRepetition() {
        let profile = calibration()
        let engine = followingEngine(profile: profile)
        let hand = profile.hand(for: engine.selectedPunch)
        let guardPosition = profile.guardPosition(for: hand)
        let targetPosition = profile.targetPosition(
            for: engine.selectedPunch,
            configuration: engine.configuration
        )

        engine.ingest(sample(
            profile: profile,
            timestamp: 1,
            moving: hand,
            position: guardPosition
        ))
        engine.ingest(sample(
            profile: profile,
            timestamp: 1.1,
            moving: hand,
            position: interpolate(
                from: guardPosition,
                to: targetPosition,
                fraction: 0.5
            )
        ))
        engine.ingest(sample(
            profile: profile,
            timestamp: 1.2,
            moving: hand,
            position: targetPosition
        ))

        #expect(engine.shouldPresentGuide)
        engine.pause(reason: "Hand tracking interrupted.")
        #expect(engine.phase == .paused)
        #expect(!engine.shouldPresentGuide)
        engine.resume(at: 1.5)
        #expect(engine.phase == .following)
        #expect(engine.shouldPresentGuide)

        // The return from the pre-pause punch only establishes a fresh guard.
        engine.ingest(sample(
            profile: profile,
            timestamp: 1.6,
            moving: hand,
            position: guardPosition
        ))
        #expect(engine.repetitionResults.isEmpty)

        performRepetition(engine: engine, profile: profile, startingAt: 2)
        #expect(engine.repetitionResults.count == 1)
    }

    @Test
    func staleSampleGapClearsPartialRepetitionAndRequiresFreshGuard() {
        let profile = calibration()
        let engine = followingEngine(profile: profile)
        let hand = profile.hand(for: engine.selectedPunch)
        let guardPosition = profile.guardPosition(for: hand)
        let targetPosition = profile.targetPosition(
            for: engine.selectedPunch,
            configuration: engine.configuration
        )

        engine.ingest(sample(
            profile: profile,
            timestamp: 1.0,
            moving: hand,
            position: guardPosition
        ))
        engine.ingest(sample(
            profile: profile,
            timestamp: 1.1,
            moving: hand,
            position: targetPosition
        ))
        engine.ingest(sample(
            profile: profile,
            timestamp: 2.0,
            moving: hand,
            position: guardPosition
        ))

        #expect(engine.repetitionResults.isEmpty)
        #expect(engine.feedback?.contains("tracking gap") == true)

        performRepetition(engine: engine, profile: profile, startingAt: 3)
        #expect(engine.repetitionResults.count == 1)
    }

    @Test
    func stanceMapsJabAndCrossToTheCorrectHands() throws {
        let profile = calibration(stance: .southpaw)
        let jabEngine = followingEngine(profile: profile, selectedPunch: .jab)
        let crossEngine = followingEngine(profile: profile, selectedPunch: .cross)

        #expect(jabEngine.expectedHand == .right)
        #expect(crossEngine.expectedHand == .left)

        performRepetition(
            engine: jabEngine,
            profile: profile,
            startingAt: 1
        )
        performRepetition(
            engine: crossEngine,
            profile: profile,
            startingAt: 1
        )

        let jabResult = try #require(jabEngine.repetitionResults.first)
        let crossResult = try #require(crossEngine.repetitionResults.first)
        #expect(jabResult.expectedHand == .right)
        #expect(jabResult.punch == .jab)
        #expect(crossResult.expectedHand == .left)
        #expect(crossResult.punch == .cross)
    }

    private func makeEngine(
        selectedPunch: PunchKind = .jab
    ) -> AuraPunchEngine {
        AuraPunchEngine(
            selectedPunch: selectedPunch,
            configuration: configuration(),
            demonstrationDuration: 1
        )
    }

    private func repetitionResult(
        repetition: Int,
        trajectoryShapeScore: Double?
    ) -> AuraPunchRepetitionResult {
        AuraPunchRepetitionResult(
            repetition: repetition,
            punch: .jab,
            expectedHand: .left,
            startedAt: Double(repetition),
            completedAt: Double(repetition) + 0.5,
            averagePathDeviation: 0.01,
            pathScore: 0.90,
            extensionRatio: 1,
            extensionScore: 1,
            peakSpeed: 1,
            relativePeakSpeed: 1,
            speedScore: 1,
            otherHandGuardScore: 1,
            trajectoryShapeScore: trajectoryShapeScore,
            overallScore: 0.95
        )
    }

    private func followingEngine(
        profile: CalibrationProfile,
        selectedPunch: PunchKind = .jab
    ) -> AuraPunchEngine {
        let engine = makeEngine(selectedPunch: selectedPunch)
        engine.start(using: profile, at: 0)
        engine.tick(at: 1)
        #expect(engine.phase == .following)
        return engine
    }

    private func performRepetition(
        engine: AuraPunchEngine,
        profile: CalibrationProfile,
        startingAt: TimeInterval,
        pathOffset: SIMD3<Float> = .zero,
        otherHandOffset: SIMD3<Float> = .zero,
        stepInterval: TimeInterval = 0.08,
        extensionScale: Float = 1
    ) {
        let hand = profile.hand(for: engine.selectedPunch)
        let guardPosition = profile.guardPosition(for: hand)
        let targetPosition = profile.targetPosition(
            for: engine.selectedPunch,
            configuration: engine.configuration
        )

        engine.ingest(sample(
            profile: profile,
            timestamp: startingAt,
            moving: hand,
            position: guardPosition
        ))

        let fractions: [Float] = [
            0.15, 0.30, 0.50, 0.75, 1.00, 0.75, 0.50, 0.25, 0,
        ]
            .map { $0 * extensionScale }
        for (index, fraction) in fractions.enumerated() {
            let isEndpoint = fraction == 0
            let position = interpolate(
                from: guardPosition,
                to: targetPosition,
                fraction: fraction
            ) + (isEndpoint ? .zero : pathOffset)
            engine.ingest(sample(
                profile: profile,
                timestamp: startingAt + stepInterval * Double(index + 1),
                moving: hand,
                position: position,
                otherHandOffset: otherHandOffset
            ))
        }
    }

    private func sample(
        profile: CalibrationProfile,
        timestamp: TimeInterval,
        moving hand: HandSide,
        position: SIMD3<Float>,
        otherHandOffset: SIMD3<Float> = .zero
    ) -> HandSample {
        let otherHand: HandSide = hand == .left ? .right : .left
        var leftPosition = profile.leftGuard
        var rightPosition = profile.rightGuard

        if hand == .left {
            leftPosition = position
        } else {
            rightPosition = position
        }

        if otherHand == .left {
            leftPosition += otherHandOffset
        } else {
            rightPosition += otherHandOffset
        }

        return HandSample(
            timestamp: timestamp,
            left: pose(position: leftPosition, timestamp: timestamp),
            right: pose(position: rightPosition, timestamp: timestamp)
        )
    }

    private func pose(
        position: SIMD3<Float>,
        timestamp: TimeInterval
    ) -> HandPose {
        HandPose(
            fistCenter: position,
            wrist: nil,
            trackedKnuckleCount: 4,
            capturedAt: timestamp
        )
    }

    private func interpolate(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        fraction: Float
    ) -> SIMD3<Float> {
        start + (end - start) * fraction
    }

    private func calibration(
        stance: Stance = .orthodox
    ) -> CalibrationProfile {
        CalibrationProfile(
            stance: stance,
            leftGuard: SIMD3<Float>(-0.10, 1.30, -0.35),
            rightGuard: SIMD3<Float>(0.10, 1.30, -0.35),
            comfortableReach: 0.50,
            straightPunchDirection: SIMD3<Float>(0, 0, -1),
            referenceStraightSpeed: 1.0
        )
    }

    private func configuration() -> DrillConfiguration {
        var configuration = DrillConfiguration.provisional
        configuration.guardReturnRadius = 0.06
        configuration.minimumGuardDeparture = 0.05
        configuration.minimumPunchTravel = 0.08
        configuration.maximumSampleInterval = 0.25
        configuration.targetReachFraction = 0.80
        configuration.targetVerticalOffset = 0
        configuration.targetRadius = 0.08
        configuration.minimumReferenceSpeed = 0.50
        return configuration
    }
}
