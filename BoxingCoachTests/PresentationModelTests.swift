import Foundation
import Testing
@testable import BoxingCoach

@Suite("Judge and audience presentation model")
struct PresentationModelTests {
    struct PreflightCase: Sendable {
        let selection: TrainingSelection
        let actionLabel: String
    }

    @Test("Every immersive route has one truthful safe-space start action", arguments: [
        PreflightCase(
            selection: .aura(track: .firstRound, technique: .jab, stance: .orthodox),
            actionLabel: "Start Rep"
        ),
        PreflightCase(
            selection: .reactive(mode: .air, combination: nil, stance: .orthodox),
            actionLabel: "Start Drill"
        ),
        PreflightCase(
            selection: .reactive(
                mode: .combination,
                combination: .oneTwo,
                stance: .southpaw
            ),
            actionLabel: "Start Drill"
        ),
        PreflightCase(selection: .reachCalibration, actionLabel: "Start Calibration"),
        PreflightCase(
            selection: .competitionCalibration(
                playerID: UUID(uuidString: "38ACDD75-E6F9-4030-95DC-ED0910649BE3")!
            ),
            actionLabel: "Start Calibration"
        ),
        PreflightCase(
            selection: .competition(
                playerID: UUID(uuidString: "3CE4B654-3E13-48EB-95B9-C1217152F255")!,
                mode: .reactiveStrike,
                stance: .orthodox,
                reach: BilateralReach(left: 0.62, right: 0.60)!
            ),
            actionLabel: "Start Ranked Round"
        ),
        PreflightCase(
            selection: .competition(
                playerID: UUID(uuidString: "E2C8254F-3A94-4A2E-AC46-F9FCE6636DE5")!,
                mode: .combination,
                stance: .southpaw,
                reach: BilateralReach(left: 0.61, right: 0.59)!
            ),
            actionLabel: "Start Ranked Round"
        ),
    ])
    func everyRouteHasSafePreflight(testCase: PreflightCase) {
        let presentation = TrainingSafetyPreflightPolicy.presentation(for: testCase.selection)

        #expect(presentation.stage == "SAFETY CHECK")
        #expect(presentation.message.contains("arm’s reach"))
        #expect(presentation.message.contains("passthrough"))
        #expect(presentation.message.contains("stop anytime"))
        #expect(presentation.primaryActionLabel == testCase.actionLabel)
        #expect(presentation.primaryActionCount == 1)
    }

    @Test(
        "Every judge stage keeps authored public copy and one optional compact metric",
        arguments: [
            (TrainingPresentationStage.welcome, TrainingPublicInstruction.chooseTrack),
            (.safety, .clearSafeSpace),
            (.fit, .fitReach),
            (.learn, .followGuide),
            (.baseline, .controlledPunch),
            (.correct, .focus(.path)),
            (.prove, .repeatPunch),
            (.transfer, .transferOneTwo),
            (.compete, .competeTarget),
            (.celebrate, .roundComplete),
            (.trackingPaused, .recoverTracking),
            (.coachOffline, .localCoachAvailable),
        ]
    )
    func judgeStateRemainsCompact(
        stage: TrainingPresentationStage,
        instruction: TrainingPublicInstruction
    ) throws {
        let state = try #require(TrainingPresentationState(
            stage: stage,
            instruction: instruction
        ))
        let mirror = AudienceMirrorPresenter.presentation(for: state)

        #expect(!mirror.stage.isEmpty)
        #expect(!mirror.instruction.isEmpty)
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
        let state = try #require(TrainingPresentationState(
            stage: .compete,
            instruction: .competeTarget,
            progress: TrainingProgressPresentation(current: 9, total: 10),
            competitionScore: 82,
            competitionRank: 2,
            publicHandle: handle
        ))

        let mirror = AudienceMirrorPresenter.presentation(for: state)

        #expect(mirror.publicIdentity == "Blue Corner #0427")
        #expect(mirror.stage == "COMPETE")
        #expect(mirror.instruction == "Hit the target and return to guard.")
        #expect(mirror.score == "82 points")
        #expect(mirror.rank == "Rank 2")
    }

    @Test("Invalid score, rank, proof, and progress cannot enter the public boundary")
    func invalidPublicEvidenceFailsClosed() {
        #expect(TrainingPresentationState(
            stage: .compete,
            instruction: .competeTarget,
            competitionScore: -1
        ) == nil)
        #expect(TrainingPresentationState(
            stage: .compete,
            instruction: .competeTarget,
            competitionScore: 101
        ) == nil)
        #expect(TrainingPresentationState(
            stage: .compete,
            instruction: .competeTarget,
            competitionRank: 0
        ) == nil)
        #expect(TrainingProgressPresentation(current: 11, total: 10) == nil)
        #expect(TrainingProofPresentation(metric: .path, baseline: -1, retest: 80) == nil)
    }

    @Test("Idle handoff clears all participant and result evidence")
    func nextBoxerStateIsPrivacySafe() {
        let mirror = AudienceMirrorPresenter.presentation(for: .nextBoxer)

        #expect(mirror.publicIdentity == nil)
        #expect(mirror.proofMetric == nil)
        #expect(mirror.progress == nil)
        #expect(mirror.score == nil)
        #expect(mirror.rank == nil)
        #expect(mirror.stage == "NEXT BOXER")
    }
}
