import Foundation
import simd
import Testing
@testable import BoxingCoach

@Suite("Coaching cycle review regressions round three")
struct CoachingCycleReviewRound3Tests {
    @Test("A later voice capture supersedes old guard recovery before scoring can resume")
    func latestVoiceCaptureOwnsTrainingPause() throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-00000000D301")!
        let latest = UUID(uuidString: "00000000-0000-0000-0000-00000000D302")!
        var owner = CoachVoiceCyclePauseOwner()
        var cycle = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        try advanceToBaseline(&cycle)
        cycle.beginPartialAttempt()

        apply(owner.observe(.captureBegan(first)), to: &cycle)
        #expect(cycle.isTrainingPaused)
        #expect(!cycle.hasPartialAttempt)
        #expect(owner.observe(.captureReleased(first)) == .holdTraining)
        #expect(owner.observe(.responseCompleted(first)) == .beginFreshGuardRecovery)

        apply(owner.observe(.captureBegan(latest)), to: &cycle)
        #expect(cycle.isTrainingPaused)
        #expect(owner.observe(.freshGuardRecovered(first)) == .ignore)
        #expect(owner.isTrainingPaused)
        #expect(throws: CoachingCycleError.attemptNotAdmissible) {
            try cycle.admit(makeAttempt())
        }

        #expect(owner.observe(.captureReleased(latest)) == .holdTraining)
        #expect(owner.observe(.responseCompleted(latest)) == .beginFreshGuardRecovery)
        apply(owner.observe(.freshGuardRecovered(latest)), to: &cycle)
        #expect(!cycle.isTrainingPaused)
        try cycle.admit(makeAttempt())
        #expect(cycle.baselineAttempts.count == 1)
    }

    @Test("Fresh-launch standalone Aura atomically creates local memory before reporting saved")
    @MainActor
    func standaloneAuraPersistsWithoutACompetitionParticipant() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(
            repository: repository,
            now: { Date(timeIntervalSince1970: 400) }
        )
        #expect(store.currentPlayer == nil)

        var cycle = CoachingCycleSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000D303")!,
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        try advanceToBaseline(&cycle)
        try admitRound(path: 60, into: &cycle)
        try cycle.beginCorrectiveDrill()
        try cycle.completeCorrectiveDrill()
        try admitRound(path: 68, into: &cycle)
        try cycle.continueFromProof()
        try cycle.completeTransfer(at: Date(timeIntervalSince1970: 390))
        let result = try #require(cycle.result)
        let reach = try #require(cycle.fittedReach)

        try await store.persistStandaloneCoachingCycle(result, fittedReach: reach)

        #expect(store.currentPlayer == nil)
        let participant = try #require(
            try await repository.player(
                normalizedName: CompetitionStore.standaloneAuraNormalizedName
            )
        )
        #expect(participant.name == "Local Athlete")
        #expect(participant.reach == reach)
        let saved = try #require(try await repository.coachingCycle(id: result.id))
        #expect(saved.athleteID == participant.id)
        #expect(saved.attempts.count == 6)
        #expect(try await repository.techniqueAttempts(
            athleteID: participant.id,
            techniqueID: Technique.jab.id
        ).count == 6)

        let competitionRepository = InMemoryCompetitionRepository()
        let competitionStore = CompetitionStore(
            repository: competitionRepository,
            now: { Date(timeIntervalSince1970: 500) }
        )
        await competitionStore.join(name: "Blue Corner")
        let competitionParticipant = try #require(competitionStore.currentPlayer)

        try await competitionStore.persistStandaloneCoachingCycle(
            result,
            fittedReach: reach
        )

        #expect(competitionStore.currentPlayer?.id == competitionParticipant.id)
        let localParticipant = try #require(
            try await competitionRepository.player(
                normalizedName: CompetitionStore.standaloneAuraNormalizedName
            )
        )
        #expect(localParticipant.id != competitionParticipant.id)
        #expect(try await competitionRepository.techniqueAttempts(
            athleteID: localParticipant.id,
            techniqueID: Technique.jab.id
        ).count == 6)
        #expect(try await competitionRepository.techniqueAttempts(
            athleteID: competitionParticipant.id,
            techniqueID: Technique.jab.id
        ).isEmpty)
    }

    @Test("Completing transfer does not claim durable proof before persistence")
    func completeCycleCopyWaitsForPersistence() throws {
        var cycle = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        try advanceToBaseline(&cycle)
        try admitRound(path: 60, into: &cycle)
        try cycle.beginCorrectiveDrill()
        try cycle.completeCorrectiveDrill()
        try admitRound(path: 68, into: &cycle)
        try cycle.continueFromProof()
        try cycle.completeTransfer(at: Date(timeIntervalSince1970: 390))

        #expect(cycle.presentation.instruction == "Your cycle is complete.")
        #expect(!cycle.presentation.instruction.localizedCaseInsensitiveContains("saved"))
    }

    private func apply(
        _ action: CoachVoiceCyclePauseOwner.Action,
        to cycle: inout CoachingCycleSession
    ) {
        switch action {
        case .pauseTraining:
            AuraVoiceCaptureTrainingPolicy.captureDidBegin(cycle: &cycle)
        case .resumeTraining:
            AuraVoiceCaptureTrainingPolicy.guardRecoveryDidComplete(cycle: &cycle)
        case .holdTraining, .beginFreshGuardRecovery, .ignore:
            break
        }
    }

    private func advanceToBaseline(_ cycle: inout CoachingCycleSession) throws {
        try cycle.completeFit(reach: BilateralReach(left: 0.62, right: 0.66)!)
        for _ in 0..<4 { try cycle.completeLearningStep() }
        for _ in 0..<cycle.track.guidedRehearsalCount {
            try cycle.completeGuidedRehearsal()
        }
    }

    private func admitRound(
        path: Float,
        into cycle: inout CoachingCycleSession
    ) throws {
        for _ in 0..<CoachingCycleSession.requiredAttempts {
            try cycle.admit(makeAttempt(path: path))
        }
    }

    private func makeAttempt(path: Float = 70) throws -> CoachingAttemptEvidence {
        let punch = try ValidatedPunchEvidence(
            technique: .jab,
            stance: .orthodox,
            side: .left,
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
            techniqueID: Technique.jab.id,
            overall: path,
            metrics: [
                SubMetric(
                    kind: .path,
                    score: path,
                    measured: 0.08,
                    detail: "Path deviation",
                    quality: .measured
                ),
            ],
            trackedFraction: 0.96,
            duration: 0.5
        )
        let evidence = try TechniqueAttemptEvidence(
            punch: punch,
            score: score,
            metricQuality: [.path: .measured]
        )
        let samples = [
            MotionSample(
                time: 0,
                fist: SIMD3(0, 0, 0.2),
                elbow: SIMD3(0, 0, 0.1),
                guardHand: SIMD3(0, 0.2, 0.1),
                isTracked: true
            ),
            MotionSample(
                time: 0.2,
                fist: SIMD3(0, 0, 0.9),
                elbow: SIMD3(0, 0, 0.5),
                guardHand: SIMD3(0, 0.2, 0.1),
                isTracked: true
            ),
        ]
        return try CoachingAttemptEvidence(
            evidence: evidence,
            actualSamples: samples,
            referenceSamples: samples
        )
    }
}
