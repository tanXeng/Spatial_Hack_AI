import Foundation
import simd
import Testing
@testable import BoxingCoach

@Suite("Coaching cycle review regressions round four")
struct CoachingCycleReviewRound4Tests {
    @Test("SwiftData startup fallback reports session-only memory and relaunch loses it")
    @MainActor
    func fallbackPersistenceIsTruthfulAcrossRelaunch() async throws {
        let firstSession = InMemoryCompetitionRepository()
        let store = CompetitionStore.live(
            makePersistentRepository: { throw ForcedSwiftDataInitializationError() },
            makeSessionRepository: { firstSession }
        )
        #expect(store.coachingCyclePersistenceScope == .sessionOnly)

        let completed = try completedCycle()
        let receipt = try await store.persistStandaloneCoachingCycle(
            completed.result,
            fittedReach: completed.reach
        )

        #expect(receipt == .sessionOnly)
        #expect(try await firstSession.coachingCycle(id: completed.result.id) != nil)
        #expect(store.currentPlayer?.name == "Local Athlete")

        let relaunchedSession = InMemoryCompetitionRepository()
        let relaunched = CompetitionStore.live(
            makePersistentRepository: { throw ForcedSwiftDataInitializationError() },
            makeSessionRepository: { relaunchedSession }
        )
        #expect(relaunched.coachingCyclePersistenceScope == .sessionOnly)
        #expect(relaunched.currentPlayer == nil)
        #expect(try await relaunchedSession.coachingCycle(id: completed.result.id) == nil)
    }

    @Test("Session-only completion copy is visible and accessibility truthful")
    func sessionOnlyCompletionCopyIsTruthful() {
        let detail = AuraCyclePersistencePresentation.detail(for: .sessionOnly)
        #expect(detail.localizedCaseInsensitiveContains("this session only"))
        #expect(!detail.localizedCaseInsensitiveContains("saved locally"))

        let instruction = AuraImmersiveInstructionPolicy.instruction(
            phase: .results,
            coachingHeadline: "COMPLETE",
            coachingDetail: detail,
            cyclePresentation: CoachingCycleSession(
                track: .firstRound,
                technique: .jab,
                stance: .orthodox
            ).presentation,
            trackingPaused: false,
            trainingPaused: false,
            statusMessage: detail
        )
        #expect(instruction.message == detail)
        #expect(instruction.accessibilityValue.localizedCaseInsensitiveContains("this session only"))
        #expect(!instruction.accessibilityValue.localizedCaseInsensitiveContains("saved locally"))
    }

    private struct ForcedSwiftDataInitializationError: Error {}

    private func completedCycle() throws -> (
        result: CoachingCycleResult,
        reach: BilateralReach
    ) {
        var cycle = CoachingCycleSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000D401")!,
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        try cycle.completeFit(reach: BilateralReach(left: 0.62, right: 0.66)!)
        for _ in 0..<4 { try cycle.completeLearningStep() }
        for _ in 0..<cycle.track.guidedRehearsalCount {
            try cycle.completeGuidedRehearsal()
        }
        for _ in 0..<CoachingCycleSession.requiredAttempts {
            try cycle.admit(makeAttempt(path: 60))
        }
        try cycle.beginCorrectiveDrill()
        try cycle.completeCorrectiveDrill()
        for _ in 0..<CoachingCycleSession.requiredAttempts {
            try cycle.admit(makeAttempt(path: 68))
        }
        try cycle.continueFromProof()
        try cycle.completeTransfer(at: Date(timeIntervalSince1970: 390))
        return (
            try #require(cycle.result),
            try #require(cycle.fittedReach)
        )
    }

    private func makeAttempt(path: Float) throws -> CoachingAttemptEvidence {
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
