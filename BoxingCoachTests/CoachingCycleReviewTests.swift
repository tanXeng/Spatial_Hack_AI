import Foundation
import RealityKit
import simd
import Testing
@testable import BoxingCoach

@Suite("Coaching cycle review regressions")
struct CoachingCycleReviewTests {
    @Test("A three-attempt round preserves every original punch-score identity")
    func roundAggregateNeverForgesTechniqueAttemptEvidence() throws {
        var cycle = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        try finishFitAndLearn(&cycle)

        let attemptIDs = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
        ]
        for (index, attemptID) in attemptIDs.enumerated() {
            try cycle.admit(makeAttempt(
                attemptID: attemptID,
                overall: Float(60 + index * 3),
                path: Float(50 + index * 3)
            ))
        }

        let round = try #require(cycle.baselineRound)
        #expect(round.attempts.map(\.evidence.identity.id) == attemptIDs)
        #expect(round.score.overall == 63)
        #expect(round.score.metric(.path)?.score == 53)
    }

    @Test(
        "Proof below the selected-focus threshold keeps the correction active",
        arguments: [Float(-4), 0, 7]
    )
    func proofRequiresGenuineFocusedImprovement(delta: Float) throws {
        var cycle = CoachingCycleSession(
            track: .technicalCamp,
            technique: .jab,
            stance: .orthodox
        )
        try finishFitAndLearn(&cycle)
        try admitRound(into: &cycle, path: 60)
        let correction = try #require(cycle.correction)
        try cycle.beginCorrectiveDrill()
        try cycle.completeCorrectiveDrill()
        try admitRound(into: &cycle, path: 60 + delta)

        #expect(cycle.stage == .proof)
        #expect(!cycle.proofMeetsTarget)
        #expect(cycle.presentation.instruction == "The selected metric did not improve enough yet.")
        #expect(throws: CoachingCycleError.proofThresholdNotMet) {
            try cycle.continueFromProof()
        }
        #expect(cycle.stage == .proof)

        try cycle.retryCorrectionFromProof()

        #expect(cycle.stage == .correctiveDrill)
        #expect(cycle.correction == correction)
        #expect(cycle.retestAttempts.isEmpty)
        #expect(cycle.proof == nil)
        #expect(cycle.proofMetric == nil)
    }

    @Test("Proof at the selected-focus threshold can enter Transfer")
    func proofAtThresholdCanTransfer() throws {
        var cycle = CoachingCycleSession(
            track: .technicalCamp,
            technique: .jab,
            stance: .orthodox
        )
        try finishFitAndLearn(&cycle)
        try admitRound(into: &cycle, path: 60)
        try cycle.beginCorrectiveDrill()
        try cycle.completeCorrectiveDrill()
        try admitRound(into: &cycle, path: 68)

        #expect(cycle.proofMeetsTarget)
        try cycle.continueFromProof()
        #expect(cycle.stage == .transfer)
    }

    @Test("Correction overlay follows scored DTW pairs and never calls interpolation measured")
    func correctionOverlayIsScoreBoundAndProvenanceHonest() throws {
        var cycle = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        try finishFitAndLearn(&cycle)

        try cycle.admit(makeAttempt(overall: 62, path: 55))
        try cycle.admit(makeAttempt(
            overall: 48,
            path: 32,
            pathMeasured: 0.25,
            actualSamples: [
                Self.sample(time: 0, fist: SIMD3(0, 0, 0), tracked: true),
                Self.sample(time: 0.2, fist: SIMD3(0.5, 0, 1), tracked: false),
            ],
            referenceSamples: [
                Self.sample(time: 0, fist: SIMD3(0, 0, 0), tracked: true),
                Self.sample(time: 0.2, fist: SIMD3(0, 0, 1), tracked: true),
            ]
        ))
        try cycle.admit(makeAttempt(overall: 66, path: 58))

        let overlay = try #require(cycle.correctionOverlay)
        #expect(overlay.focus == .path)
        #expect(overlay.alignmentDistance == 0.25)
        #expect(overlay.actualSamples.map(\.provenance) == [.measured, .interpolated])
        #expect(overlay.actualLabel == "Actual path · Includes interpolated samples")
        #expect(overlay.referenceLabel == "Reference path · Estimated fit")
        #expect(overlay.actualPath == [SIMD3(0, 0, 0), SIMD3(0.5, 0, 1)])
        #expect(overlay.referencePath == [SIMD3(0, 0, 0), SIMD3(0, 0, 1)])
    }

    @Test("Fit acquiring presents the live extension instruction on screen and to accessibility")
    func fitAcquiringUsesLiveCalibrationInstruction() {
        let cycle = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )

        let instruction = AuraImmersiveInstructionPolicy.instruction(
            phase: .acquiring,
            coachingHeadline: "FIT YOUR REACH",
            coachingDetail: "Extend each closed fist comfortably and hold",
            cyclePresentation: cycle.presentation,
            trackingPaused: false,
            trainingPaused: false,
            statusMessage: "Fit · extend each arm comfortably"
        )

        #expect(instruction.stage == "FIT YOUR REACH")
        #expect(instruction.message == "Extend each closed fist comfortably and hold")
        #expect(instruction.action == "Fit your reach")
        #expect(instruction.accessibilityValue.contains("Extend each closed fist comfortably and hold"))
    }

    @Test("Guidance active time freezes until fresh tracking and guard recovery")
    func guidanceClockFreezesAcrossTrackingLoss() {
        var clock = AuraGuidanceActiveClock()

        #expect(clock.observe(at: 0, availability: .ready) == .advance)
        #expect(clock.observe(at: 1, availability: .ready) == .advance)
        #expect(clock.activeElapsed == 1)
        #expect(clock.observe(at: 4, availability: .trackingUnavailable) == .recoverTracking)
        #expect(clock.activeElapsed == 1)
        #expect(clock.observe(at: 5, availability: .guardUnavailable) == .holdForGuard)
        #expect(clock.activeElapsed == 1)
        #expect(clock.observe(at: 6, availability: .ready) == .advance)
        #expect(clock.activeElapsed == 1)
        #expect(clock.observe(at: 7, availability: .ready) == .advance)
        #expect(clock.activeElapsed == 2)
    }

    @Test("Live guidance requires body, punching hand, and guard hand before time can advance")
    func guidanceAvailabilityRequiresBothFreshHands() {
        #expect(AuraGuidanceTrackingPolicy.availability(
            bodyFrameAvailable: true,
            punchingHandAvailable: false,
            guardHandAvailable: true,
            nonPunchingGuardUp: true
        ) == .trackingUnavailable)
        #expect(AuraGuidanceTrackingPolicy.availability(
            bodyFrameAvailable: true,
            punchingHandAvailable: true,
            guardHandAvailable: false,
            nonPunchingGuardUp: nil
        ) == .trackingUnavailable)
        #expect(AuraGuidanceTrackingPolicy.availability(
            bodyFrameAvailable: true,
            punchingHandAvailable: true,
            guardHandAvailable: true,
            nonPunchingGuardUp: false
        ) == .guardUnavailable)
        #expect(AuraGuidanceTrackingPolicy.availability(
            bodyFrameAvailable: true,
            punchingHandAvailable: true,
            guardHandAvailable: true,
            nonPunchingGuardUp: true
        ) == .ready)
    }

    @Test("Every allow-listed correction dispatches aligned drill behavior")
    func selectedCorrectionDrillDispatchIsDistinct() {
        let drills = CoachCorrectiveDrill.allCases
        let plans = drills.map(CorrectiveDrillPlan.init(drill:))

        #expect(plans.map(\.drill) == drills)
        #expect(Set(plans.map(\.behaviorSignature)).count == drills.count)
        #expect(plans.allSatisfy { !$0.headline.isEmpty && !$0.instruction.isEmpty })
        #expect(CorrectiveDrillPlan(drill: .straightLine).steps == [
            .outbound, .landingHold, .returnToGuard, .guardHold,
        ])
        #expect(CorrectiveDrillPlan(drill: .snapBack).steps == [
            .landingHold, .returnToGuard, .guardHold,
        ])
        #expect(CorrectiveDrillPlan(drill: .guardAnchor).instruction.contains("spare hand"))
    }

    @Test("Transfer converts the fitted body guard instead of capturing an arbitrary live fist")
    func transferUsesCalibratedGuardContract() {
        let frame = BodyFrame(
            origin: SIMD3(1, 2, 3),
            right: SIMD3(1, 0, 0),
            up: SIMD3(0, 1, 0),
            forward: SIMD3(0, 0, -1),
            headPosition: SIMD3(1, 3, 3)
        )
        let calibratedBodyGuard = SIMD3<Float>(-0.2, 0.25, 0.18)
        let arbitraryCurrentFist = SIMD3<Float>(4, 5, 6)

        let contract = AuraTransferGuardContract(
            calibratedBodyGuard: calibratedBodyGuard,
            frame: frame
        )

        #expect(contract.worldGuard == frame.toWorld(calibratedBodyGuard))
        #expect(contract.worldGuard != arbitraryCurrentFist)
        #expect(contract.isFreshGuard(
            fistWorld: frame.toWorld(calibratedBodyGuard),
            fistState: .closed
        ))
        #expect(!contract.isFreshGuard(fistWorld: arbitraryCurrentFist, fistState: .closed))
    }

    @Test("Voice capture invalidates partial Baseline and Retest reps until guard recovery")
    func voiceCapturePausesCycleEvidence() throws {
        var cycle = CoachingCycleSession(
            track: .technicalCamp,
            technique: .jab,
            stance: .orthodox
        )
        try finishFitAndLearn(&cycle)
        cycle.beginPartialAttempt()

        AuraVoiceCaptureTrainingPolicy.captureDidBegin(cycle: &cycle)

        #expect(cycle.isTrainingPaused)
        #expect(!cycle.hasPartialAttempt)
        #expect(cycle.baselineAttempts.isEmpty)

        AuraVoiceCaptureTrainingPolicy.guardRecoveryDidComplete(cycle: &cycle)
        #expect(!cycle.isTrainingPaused)

        try admitRound(into: &cycle, path: 60)
        try cycle.beginCorrectiveDrill()
        try cycle.completeCorrectiveDrill()
        cycle.beginPartialAttempt()
        AuraVoiceCaptureTrainingPolicy.captureDidBegin(cycle: &cycle)

        #expect(cycle.isTrainingPaused)
        #expect(!cycle.hasPartialAttempt)
        #expect(cycle.retestAttempts.isEmpty)
    }

    @Test("Voice recovery replaces the active action on screen and for accessibility")
    func voiceRecoveryOwnsVisibleInstruction() {
        let cycle = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )

        let instruction = AuraImmersiveInstructionPolicy.instruction(
            phase: .guiding,
            coachingHeadline: "RETURN TO GUARD",
            coachingDetail: "Hold both closed fists in your fitted guard to resume",
            cyclePresentation: cycle.presentation,
            trackingPaused: false,
            trainingPaused: true,
            statusMessage: "Ask Coach complete · waiting for fresh guard"
        )

        #expect(instruction.stage == "RETURN TO GUARD")
        #expect(instruction.action == "Resume after guard")
        #expect(instruction.accessibilityValue.contains("fitted guard"))
    }

    @Test("Correction geometry clear removes private entities and provenance updates accessibility")
    @MainActor
    func correctionGeometryClearsForHandoff() throws {
        let entity = PunchPathOverlayEntity()
        entity.show(
            actual: [
                CorrectionPathSample(position: SIMD3(0, 0, 0), provenance: .measured),
                CorrectionPathSample(position: SIMD3(0, 0, 1), provenance: .interpolated),
            ],
            reference: [
                CorrectionPathSample(position: SIMD3(0, 0, 0), provenance: .estimated),
                CorrectionPathSample(position: SIMD3(0, 0, 1), provenance: .estimated),
            ]
        )

        #expect(entity.visiblePointCount == 4)
        let accessibility = try #require(
            entity.root.components[AccessibilityComponent.self]
        )
        #expect(accessibility.value.map { String(localized: $0).contains("interpolated") } == true)

        entity.clear()

        #expect(entity.visiblePointCount == 0)
        #expect(!entity.root.isEnabled)
    }

    @Test("Participant handoff clears reusable reach and Aura private cycle state")
    @MainActor
    func participantHandoffClearsReachReuse() throws {
        let session = ReactiveStrikeSession()
        let reach = try #require(BilateralReach(left: 0.61, right: 0.64))
        session.applyPersistedCompetitionReach(reach)
        session.auraPunch.persistedReach = BilateralReach(session.latestCalibratedReaches)

        #expect(session.hasCalibratedReach)
        #expect(session.auraPunch.persistedReach == reach)

        session.resetForParticipantHandoff()

        #expect(!session.hasCalibratedReach)
        #expect(session.latestCalibratedReaches.isEmpty)
        #expect(session.auraPunch.persistedReach == nil)
        #expect(session.auraPunch.learningStage == .fit)
        #expect(session.auraPunch.correctionOverlay == nil)
    }

    @Test("Uppercut completes the same six-attempt proof engine")
    func uppercutCompletesApprovedCycle() throws {
        var cycle = CoachingCycleSession(
            track: .technicalCamp,
            technique: .uppercut,
            stance: .orthodox
        )
        try finishFitAndLearn(&cycle)
        for (index, side) in [BodySide.left, .right, .left].enumerated() {
            try cycle.admit(makeAttempt(
                overall: Float(60 + index),
                path: 58,
                technique: .uppercut,
                side: side
            ))
        }
        try cycle.beginCorrectiveDrill()
        try cycle.completeCorrectiveDrill()
        for (index, side) in [BodySide.left, .right, .left].enumerated() {
            try cycle.admit(makeAttempt(
                overall: Float(72 + index),
                path: 68,
                technique: .uppercut,
                side: side
            ))
        }

        #expect(cycle.proofMeetsTarget)
        try cycle.continueFromProof()
        try cycle.completeTransfer(at: Date(timeIntervalSince1970: 100))

        let result = try #require(cycle.result)
        #expect(cycle.stage == .complete)
        #expect(result.technique == .uppercut)
        #expect(result.proof.baseline.attempts.count == 3)
        #expect(result.proof.retest.attempts.count == 3)
    }

    @Test("Completed coaching proof and fitted reach persist for only the active participant")
    @MainActor
    func coachingResultPersistsThroughAthleteMemory() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository, now: {
            Date(timeIntervalSince1970: 200)
        })
        await store.join(name: "Ada")
        let player = try #require(store.currentPlayer)
        var cycle = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        try finishFitAndLearn(&cycle)
        try admitRound(into: &cycle, path: 58)
        try cycle.beginCorrectiveDrill()
        try cycle.completeCorrectiveDrill()
        try admitRound(into: &cycle, path: 68)
        try cycle.continueFromProof()
        try cycle.completeTransfer(at: Date(timeIntervalSince1970: 190))
        let result = try #require(cycle.result)
        let reach = try #require(cycle.fittedReach)

        try await store.persistCoachingCycle(result, fittedReach: reach)

        let attempts = try await repository.techniqueAttempts(
            athleteID: player.id,
            techniqueID: Technique.jab.id
        )
        #expect(attempts.count == 6)
        #expect(Set(attempts.map(\.id)).count == 6)
        #expect(try await repository.player(id: player.id)?.reach == reach)
        #expect(try await repository.skillMemory(
            athleteID: player.id,
            techniqueID: Technique.jab.id
        )?.attempts.count == 6)
        #expect(try await repository.techniqueAttempts(
            athleteID: UUID(uuidString: "00000000-0000-0000-0000-00000000B0B0")!,
            techniqueID: Technique.jab.id
        ).isEmpty)
    }

    private func finishFitAndLearn(_ cycle: inout CoachingCycleSession) throws {
        try cycle.completeFit(reach: BilateralReach(left: 0.62, right: 0.66)!)
        for _ in 0..<4 { try cycle.completeLearningStep() }
        for _ in 0..<cycle.track.guidedRehearsalCount {
            try cycle.completeGuidedRehearsal()
        }
    }

    private func admitRound(
        into cycle: inout CoachingCycleSession,
        path: Float
    ) throws {
        for overall in [Float(60), 62, 64] {
            try cycle.admit(makeAttempt(overall: overall, path: path))
        }
    }

    private func makeAttempt(
        attemptID: UUID = UUID(),
        overall: Float,
        path: Float,
        technique: Technique = .jab,
        stance: Stance = .orthodox,
        side: BodySide = .left,
        pathMeasured: Float = 0,
        actualSamples: [MotionSample] = [
            Self.sample(time: 0, fist: SIMD3(0, 0, 0.2), tracked: true),
            Self.sample(time: 0.2, fist: SIMD3(0, 0, 0.9), tracked: true),
        ],
        referenceSamples: [MotionSample] = [
            Self.sample(time: 0, fist: SIMD3(0, 0, 0.2), tracked: true),
            Self.sample(time: 0.2, fist: SIMD3(0, 0, 0.9), tracked: true),
        ]
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
                    measured: pathMeasured,
                    detail: "Path deviation",
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
            metricQuality: [.path: .measured, .elbow: .inferred],
            attemptID: attemptID
        )
        return try CoachingAttemptEvidence(
            evidence: evidence,
            actualSamples: actualSamples,
            referenceSamples: referenceSamples
        )
    }

    private static func sample(
        time: TimeInterval,
        fist: SIMD3<Float>,
        tracked: Bool
    ) -> MotionSample {
        MotionSample(
            time: time,
            fist: fist,
            elbow: fist * 0.6,
            guardHand: SIMD3(0, 0.2, 0.1),
            isTracked: tracked
        )
    }
}
