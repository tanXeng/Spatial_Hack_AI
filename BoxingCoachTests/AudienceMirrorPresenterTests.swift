import Foundation
import Testing
@testable import BoxingCoach

@Suite("Audience mirror production presenter")
struct AudienceMirrorPresenterTests {
    @Test("Every Aura learning stage maps to a public presentation stage", arguments: [
        (LearningStage.fit, TrainingPresentationStage.fit),
        (.learnWatch, .learn),
        (.learnOutbound, .learn),
        (.learnLanding, .learn),
        (.learnReturn, .learn),
        (.guidedRehearsal, .learn),
        (.baseline, .baseline),
        (.correction, .correct),
        (.correctiveDrill, .correct),
        (.retest, .prove),
        (.proof, .prove),
        (.transfer, .transfer),
        (.complete, .celebrate),
    ])
    func auraStageMapping(stage: LearningStage, expected: TrainingPresentationStage) throws {
        let state = try #require(TrainingPresentationPolicy.state(
            for: .aura(
                stage: stage,
                trackingPaused: false,
                proof: nil,
                aiPhrasingAvailable: false
            )
        ))

        #expect(state.stage == expected)
        #expect(state.secondaryMetricCount <= 1)
    }

    @Test("Tracking recovery overrides the underlying training stage")
    func trackingRecoveryPrecedence() throws {
        let state = try #require(TrainingPresentationPolicy.state(
            for: .reactive(
                context: .standard(isCombination: false),
                phase: .running,
                trackingPaused: true,
                progress: TrainingProgressPresentation(current: 2, total: 8),
                score: nil,
                rank: nil,
                publicHandle: nil
            )
        ))

        #expect(state.stage == .trackingPaused)
        #expect(state.instruction == .recoverTracking)
        #expect(state.progress == nil)
    }

    @Test("Next boxer clears every prior participant and result field")
    func nextBoxerIsPrivacySafe() {
        let state = TrainingPresentationPolicy.state(for: .nextBoxer)
        let mirror = state.map(AudienceMirrorPresenter.presentation)

        #expect(mirror?.stage == "NEXT BOXER")
        #expect(mirror?.proofMetric == nil)
        #expect(mirror?.progress == nil)
        #expect(mirror?.score == nil)
        #expect(mirror?.rank == nil)
        #expect(mirror?.publicIdentity == nil)
    }

    @Test("Competition output accepts only event-local public identity")
    func competitionUsesPublicHandle() throws {
        let eventID = UUID()
        let handle = try #require(ParticipantPublicHandle.reserving(
            eventID: eventID,
            displayName: "RING",
            displayCode: "0007",
            against: []
        ))
        let state = try #require(TrainingPresentationPolicy.state(
            for: .reactive(
                context: .competition(isCombination: false),
                phase: .finished,
                trackingPaused: false,
                progress: nil,
                score: 92,
                rank: 1,
                publicHandle: handle
            )
        ))
        let mirror = AudienceMirrorPresenter.presentation(for: state)

        #expect(mirror.publicIdentity == handle.displayValue)
        #expect(mirror.score == "92 points")
        #expect(mirror.rank == "Rank 1")
    }
}
