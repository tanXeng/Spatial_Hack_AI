import Foundation
import Testing
@testable import BoxingCoach

@Suite("Judge and audience presentation model")
struct PresentationModelTests {
    @Test(
        "Every judge state keeps one stage, one instruction, and optional compact evidence",
        arguments: [
            TrainingPresentationState(stage: "WELCOME", instruction: "Choose First Round or Technical Camp."),
            TrainingPresentationState(stage: "SAFETY", instruction: "Clear enough room to extend both arms."),
            TrainingPresentationState(stage: "FIT", instruction: "Measure both arms inside comfortable reach."),
            TrainingPresentationState(stage: "LEARN", instruction: "Follow the cyan guide from guard to guard.", progress: "2 of 4"),
            TrainingPresentationState(stage: "BASELINE", instruction: "Throw one controlled punch.", progress: "1 of 3"),
            TrainingPresentationState(stage: "CORRECT", instruction: "Keep the elbow under the fist.", proofMetric: "Path 62"),
            TrainingPresentationState(stage: "PROVE", instruction: "Repeat the same punch.", proofMetric: "Path 62 to 74"),
            TrainingPresentationState(stage: "TRANSFER", instruction: "Throw a stance-correct 1–2."),
            TrainingPresentationState(stage: "COMPETE", instruction: "Hit the target and return to guard.", progress: "4 of 10"),
            TrainingPresentationState(stage: "CELEBRATE", instruction: "Round complete.", proofMetric: "Path plus 12"),
            TrainingPresentationState(stage: "TRACKING PAUSED", instruction: "Return both fists to guard."),
            TrainingPresentationState(stage: "COACH OFFLINE", instruction: "Measured local coaching remains available."),
        ]
    )
    func judgeStateRemainsCompact(state: TrainingPresentationState) {
        #expect(!state.stage.isEmpty)
        #expect(!state.instruction.isEmpty)
        #expect(state.secondaryMetricCount <= 1)
    }

    @Test("Audience output uses only the event-local public handle")
    func mirrorNeverNeedsThePrivateParticipantName() throws {
        let eventID = UUID(uuidString: "A8C3951C-A41D-4555-9BA7-EF547C582887")!
        let handle = try #require(ParticipantPublicHandle.reserving(
            eventID: eventID,
            displayName: "Blue Corner",
            displayCode: "0427",
            against: []
        ))
        let state = TrainingPresentationState(
            stage: "COMPETE",
            instruction: "Final target.",
            progress: "9 of 10",
            competitionScore: 820,
            competitionRank: 2,
            publicHandle: handle
        )

        let mirror = AudienceMirrorPresenter.presentation(for: state)

        #expect(mirror.publicIdentity == "Blue Corner #0427")
        #expect(mirror.stage == "COMPETE")
        #expect(mirror.instruction == "Final target.")
        #expect(mirror.score == "820 points")
        #expect(mirror.rank == "Rank 2")
    }

    @Test("Idle handoff clears all participant and result evidence")
    func nextBoxerStateIsPrivacySafe() {
        let mirror = AudienceMirrorPresenter.presentation(for: .nextBoxer)

        #expect(mirror.publicIdentity == nil)
        #expect(mirror.proofMetric == nil)
        #expect(mirror.score == nil)
        #expect(mirror.rank == nil)
        #expect(mirror.stage == "NEXT BOXER")
    }
}
