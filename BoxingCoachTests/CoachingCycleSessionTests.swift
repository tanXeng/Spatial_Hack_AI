import Foundation
import RealityKit
import simd
import Testing
@testable import BoxingCoach

@Suite("Coaching cycle session")
struct CoachingCycleSessionTests {
    @Test("Jab completes Fit, Learn, three-plus-three proof, Transfer, and Complete")
    func jabCompletesApprovedCycle() throws {
        var cycle = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )

        #expect(cycle.stage == .fit)
        try finishFitAndLearn(&cycle)
        #expect(cycle.stage == .baseline)

        try admitRound(into: &cycle, scores: [58, 62, 66], pathScores: [52, 56, 60])

        #expect(cycle.stage == .correction)
        #expect(cycle.baselineAttempts.count == 3)
        #expect(cycle.correction?.kind == .metric(.path))
        let selectedCorrection = try #require(cycle.correction)

        try cycle.beginCorrectiveDrill()
        #expect(cycle.stage == .correctiveDrill)
        try cycle.completeCorrectiveDrill()
        #expect(cycle.stage == .retest)

        try admitRound(into: &cycle, scores: [74, 78, 82], pathScores: [68, 72, 76])

        #expect(cycle.stage == .proof)
        #expect(cycle.retestAttempts.count == 3)
        #expect(cycle.correction == selectedCorrection)
        let proofBeforeTransfer = try #require(cycle.proofMetric)
        #expect(proofBeforeTransfer.kind == .path)
        #expect(proofBeforeTransfer.baseline == 56)
        #expect(proofBeforeTransfer.retest == 72)
        #expect(proofBeforeTransfer.delta == 16)
        #expect(proofBeforeTransfer.sourceBadge == "Measured locally · Offline coach")

        try cycle.continueFromProof()
        #expect(cycle.stage == .transfer)
        try cycle.completeTransfer(at: Date(timeIntervalSince1970: 100))

        #expect(cycle.stage == .complete)
        #expect(cycle.proofMetric == proofBeforeTransfer)
        #expect(cycle.result?.proof.metricDelta(for: .path) == 16)
        #expect(cycle.completedStages == LearningStage.allCases)
    }

    @Test("Only admitted evidence consumes the three baseline and retest slots")
    func invalidAndInterruptedAttemptsDoNotConsumeSlots() throws {
        var cycle = CoachingCycleSession(
            track: .technicalCamp,
            technique: .jab,
            stance: .orthodox
        )
        try finishFitAndLearn(&cycle)

        cycle.beginPartialAttempt()
        cycle.rejectPartialAttempt(.invalidEvidence)
        #expect(cycle.baselineAttempts.isEmpty)
        #expect(!cycle.hasPartialAttempt)

        cycle.beginPartialAttempt()
        cycle.trackingDidPause()
        #expect(cycle.isTrackingPaused)
        #expect(!cycle.hasPartialAttempt)
        #expect(cycle.baselineAttempts.isEmpty)
        cycle.trackingDidResume()

        cycle.beginPartialAttempt()
        cycle.trainingDidPause()
        #expect(cycle.isTrainingPaused)
        #expect(!cycle.hasPartialAttempt)
        #expect(cycle.baselineAttempts.isEmpty)
        cycle.trainingDidResume()

        try cycle.admit(makeAttempt(overall: 60, path: 50))
        try cycle.admit(makeAttempt(overall: 62, path: 52))
        #expect(cycle.stage == .baseline)
        #expect(cycle.baselineAttempts.count == 2)

        try cycle.admit(makeAttempt(overall: 64, path: 54))
        #expect(cycle.stage == .correction)
        #expect(cycle.baselineAttempts.count == 3)
    }

    @Test("Reset clears participant-private cycle state and returns to Fit")
    func resetClearsCycleState() throws {
        var cycle = CoachingCycleSession(
            track: .technicalCamp,
            technique: .jab,
            stance: .southpaw
        )
        try finishFitAndLearn(&cycle, reach: BilateralReach(left: 0.61, right: 0.64)!)
        try admitRound(
            into: &cycle,
            scores: [60, 61, 62],
            pathScores: [50, 51, 52],
            stance: .southpaw,
            side: .right
        )
        cycle.beginPartialAttempt()
        cycle.trackingDidPause()

        cycle.reset()

        #expect(cycle.stage == .fit)
        #expect(cycle.fittedReach == nil)
        #expect(cycle.baselineAttempts.isEmpty)
        #expect(cycle.retestAttempts.isEmpty)
        #expect(cycle.correction == nil)
        #expect(cycle.proof == nil)
        #expect(cycle.proofMetric == nil)
        #expect(cycle.result == nil)
        #expect(!cycle.hasPartialAttempt)
        #expect(!cycle.isTrackingPaused)
        #expect(!cycle.isTrainingPaused)
        #expect(cycle.completedStages.isEmpty)
    }

    @Test("First Round and Technical Camp change coaching, never scoring")
    func tracksChangePacingAndCopyOnly() {
        let beginner = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        let athlete = CoachingCycleSession(
            track: .technicalCamp,
            technique: .jab,
            stance: .orthodox
        )

        #expect(beginner.track.guidedRehearsalCount == 3)
        #expect(beginner.track.demonstrationRate == 0.65)
        #expect(!beginner.track.usesTimerPressure)
        #expect(athlete.track.guidedRehearsalCount == 5)
        #expect(athlete.track.demonstrationRate == 0.85)
        #expect(beginner.track.scoringPolicy == athlete.track.scoringPolicy)
        #expect(beginner.presentation.instruction != athlete.presentation.instruction)
        #expect(beginner.presentation.timer == nil)
    }

    @Test("Uppercut uses the same engine with alternating admitted hands")
    func uppercutUsesTheSameEngine() throws {
        var cycle = CoachingCycleSession(
            track: .technicalCamp,
            technique: .uppercut,
            stance: .orthodox
        )
        try finishFitAndLearn(&cycle)

        try cycle.admit(makeAttempt(
            overall: 65,
            path: 58,
            technique: .uppercut,
            side: .left
        ))
        try cycle.admit(makeAttempt(
            overall: 67,
            path: 60,
            technique: .uppercut,
            side: .right
        ))
        try cycle.admit(makeAttempt(
            overall: 69,
            path: 62,
            technique: .uppercut,
            side: .left
        ))

        #expect(cycle.stage == .correction)
        #expect(cycle.baselineAttempts.map(\.evidence.side) == [.left, .right, .left])
        #expect(cycle.correction?.kind == .metric(.path))
    }

    @Test("The correction overlay selects the worst path segment with honest labels")
    func correctionOverlayUsesWorstSegment() throws {
        var cycle = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        try finishFitAndLearn(&cycle)
        try cycle.admit(makeAttempt(overall: 64, path: 60))
        try cycle.admit(makeAttempt(
            overall: 55,
            path: 40,
            actualPath: [SIMD3(0, 0, 0), SIMD3(0.5, 0.4, 0.5), SIMD3(0, 0, 1)],
            referencePath: [SIMD3(0, 0, 0), SIMD3(0, 0, 0.5), SIMD3(0, 0, 1)]
        ))
        try cycle.admit(makeAttempt(overall: 68, path: 64))

        let overlay = try #require(cycle.correctionOverlay)
        #expect(overlay.actualLabel == "Actual path · Measured")
        #expect(overlay.referenceLabel == "Reference path · Estimated fit")
        #expect(overlay.actualColorName == "Coral")
        #expect(overlay.referenceColorName == "Cyan")
        #expect(overlay.sourceBadge == "Measured locally · Offline coach")
        #expect(overlay.actualPath.count == overlay.referencePath.count)
        #expect(overlay.actualPath.contains(SIMD3(0.5, 0.4, 0.5)))
    }

    @Test("The correction path entity exposes an accessible measured-versus-estimated summary")
    @MainActor
    func correctionPathEntityIsAccessible() throws {
        let overlay = PunchPathOverlayEntity()
        let accessibility = try #require(
            overlay.root.components[AccessibilityComponent.self]
        )

        #expect(accessibility.isAccessibilityElement)
        #expect(accessibility.label != nil)
        #expect(accessibility.value != nil)
    }

    @Test("Jab and Uppercut references fit at or inside conservative calibrated reach")
    func heroReferencesFitConservativeReach() {
        let reach: Float = 0.54

        for technique in [Technique.jab, .uppercut] {
            let fitted = ReferencePunchLibrary.punch(
                for: technique,
                stance: .orthodox,
                measurements: .averageAdult,
                side: .left,
                conservativeReach: reach
            )
            let unfitted = ReferencePunchLibrary.punch(
                for: technique,
                stance: .orthodox,
                measurements: .averageAdult,
                side: .left
            )

            #expect(fitted.samples.map(\.reachFraction).max()! <= reach / BodyMeasurements.averageAdult.armReach + 0.001)
            #expect(fitted.peakReach <= unfitted.peakReach)
        }
    }

    private func finishFitAndLearn(
        _ cycle: inout CoachingCycleSession,
        reach: BilateralReach = BilateralReach(left: 0.62, right: 0.66)!
    ) throws {
        try cycle.completeFit(reach: reach)
        #expect(cycle.stage == .learnWatch)

        try cycle.completeLearningStep()
        #expect(cycle.stage == .learnOutbound)
        try cycle.completeLearningStep()
        #expect(cycle.stage == .learnLanding)
        try cycle.completeLearningStep()
        #expect(cycle.stage == .learnReturn)
        try cycle.completeLearningStep()
        #expect(cycle.stage == .guidedRehearsal)

        for repetition in 1...cycle.track.guidedRehearsalCount {
            try cycle.completeGuidedRehearsal()
            #expect(cycle.guidedRehearsalsCompleted == repetition)
        }
    }

    private func admitRound(
        into cycle: inout CoachingCycleSession,
        scores: [Float],
        pathScores: [Float],
        stance: Stance = .orthodox,
        side: BodySide = .left
    ) throws {
        for (overall, path) in zip(scores, pathScores) {
            try cycle.admit(makeAttempt(
                overall: overall,
                path: path,
                technique: cycle.technique,
                stance: stance,
                side: side
            ))
        }
    }

    private func makeAttempt(
        overall: Float,
        path: Float,
        technique: Technique = .jab,
        stance: Stance = .orthodox,
        side: BodySide = .left,
        actualPath: [SIMD3<Float>] = [SIMD3(0, 0, 0.2), SIMD3(0, 0, 0.9)],
        referencePath: [SIMD3<Float>] = [SIMD3(0, 0, 0.2), SIMD3(0, 0, 0.9)]
    ) throws -> CoachingAttemptEvidence {
        let punch = try ValidatedPunchEvidence(
            technique: technique,
            stance: stance,
            side: side,
            generation: 7,
            startedAt: 10,
            landedAt: 10.2,
            returnedAt: 10.5,
            outboundTravel: 0.5,
            landingError: 0.03,
            returnError: 0.04,
            trackedFraction: 0.96,
            quality: .measured
        )
        let score = TechniqueScore(
            techniqueID: technique.id,
            overall: overall,
            metrics: [
                SubMetric(
                    kind: .path,
                    score: path,
                    measured: 0.18,
                    detail: "18% normalized path error",
                    quality: .measured
                ),
                SubMetric(
                    kind: .elbow,
                    score: 90,
                    measured: 0.08,
                    detail: "Estimated elbow alignment",
                    quality: .inferred
                ),
            ],
            trackedFraction: 0.96,
            duration: 0.5
        )
        let evidence = try TechniqueAttemptEvidence(
            punch: punch,
            score: score,
            metricQuality: [.path: .measured, .elbow: .inferred]
        )
        return try CoachingAttemptEvidence(
            evidence: evidence,
            actualPath: actualPath,
            referencePath: referencePath
        )
    }
}
