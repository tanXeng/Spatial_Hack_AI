import Foundation
import Testing
@testable import BoxingCoach

@Suite("Immersive instruction policy")
@MainActor
struct ImmersiveInstructionPolicyTests {
    @Test("Reach calibration explains safety and measurement at every phase")
    func reachCalibrationCopyIsSpecific() {
        let idle = ImmersiveInstructionPolicy.instruction(
            for: .reachCalibration,
            phase: .idle,
            progressLabel: "Idle",
            feedback: "Ready",
            trackingPaused: false
        )
        #expect(idle == ImmersiveInstruction(
            stage: "REACH CALIBRATION",
            message: "Stand naturally, keep the floor clear, and bring both fists into view.",
            symbol: "ruler"
        ))

        let measuring = ImmersiveInstructionPolicy.instruction(
            for: .reachCalibration,
            phase: .calibrating,
            progressLabel: "Calibration",
            feedback: "Extend your left arm comfortably",
            trackingPaused: false
        )
        #expect(measuring.stage == "MEASURING REACH")
        #expect(measuring.message == "Extend your left arm comfortably")

        let finished = ImmersiveInstructionPolicy.instruction(
            for: .reachCalibration,
            phase: .finished,
            progressLabel: "Round complete",
            feedback: "Reach saved",
            trackingPaused: false
        )
        #expect(finished.stage == "REACH READY")
        #expect(finished.message == "Reach saved")
    }

    @Test("Competition calibration explains why the fit is required")
    func competitionCalibrationCopyIsSpecific() {
        let idle = ImmersiveInstructionPolicy.instruction(
            for: .competitionCalibration,
            phase: .idle,
            progressLabel: "Idle",
            feedback: "Ready",
            trackingPaused: false
        )
        #expect(idle == ImmersiveInstruction(
            stage: "COMPETITION FIT",
            message: "This reach check keeps every ranked target inside your comfortable range.",
            symbol: "figure.arms.open"
        ))

        let measuring = ImmersiveInstructionPolicy.instruction(
            for: .competitionCalibration,
            phase: .calibrating,
            progressLabel: "Calibration",
            feedback: "Hold both fists in guard",
            trackingPaused: false
        )
        #expect(measuring.stage == "COMPETITION FIT")
        #expect(measuring.message == "Hold both fists in guard")

        let finished = ImmersiveInstructionPolicy.instruction(
            for: .competitionCalibration,
            phase: .finished,
            progressLabel: "Round complete",
            feedback: "Reach calibrated",
            trackingPaused: false
        )
        #expect(finished == ImmersiveInstruction(
            stage: "COMPETITION FIT COMPLETE",
            message: "Reach calibrated",
            symbol: "checkmark.circle.fill"
        ))
    }

    @Test("Ranked rounds expose ready, progress, recovery, and completion states")
    func rankedRoundCopyIsSpecific() {
        let ready = ImmersiveInstructionPolicy.instruction(
            for: .competition(isCombination: false),
            phase: .idle,
            progressLabel: "Idle",
            feedback: "Ready",
            trackingPaused: false
        )
        #expect(ready.stage == "RANKED ROUND READY")
        #expect(ready.message == "Raise your guard. The timer begins with your first target.")

        let running = ImmersiveInstructionPolicy.instruction(
            for: .competition(isCombination: false),
            phase: .running,
            progressLabel: "Target 3 / 8",
            feedback: "Jab and return to guard",
            trackingPaused: false
        )
        #expect(running.stage == "RANKED · TARGET 3 / 8")
        #expect(running.message == "Jab and return to guard")
        #expect(running.symbol == "trophy.fill")

        let paused = ImmersiveInstructionPolicy.instruction(
            for: .competition(isCombination: true),
            phase: .running,
            progressLabel: "Rep 2 / 5",
            feedback: "Tracking paused · hold both fists in guard",
            trackingPaused: true
        )
        #expect(paused.stage == "ROUND PAUSED")
        #expect(paused.message == "Tracking paused · hold both fists in guard")
        #expect(paused.symbol == "pause.circle.fill")

        let finished = ImmersiveInstructionPolicy.instruction(
            for: .competition(isCombination: true),
            phase: .finished,
            progressLabel: "Round complete",
            feedback: "Score saved",
            trackingPaused: false
        )
        #expect(finished.stage == "RANKED ROUND COMPLETE")
        #expect(finished.message == "Score saved")
    }

    @Test("Standard reactive instruction remains explicit")
    func standardReactiveCopyRemainsExplicit() {
        let instruction = ImmersiveInstructionPolicy.instruction(
            for: .standard(isCombination: true),
            phase: .running,
            progressLabel: "Rep 1 / 5 · Step 2 / 4",
            feedback: "Cross and return to guard",
            trackingPaused: false
        )
        #expect(instruction.stage == "REP 1 / 5 · STEP 2 / 4")
        #expect(instruction.symbol == "list.number")

        let paused = ImmersiveInstructionPolicy.instruction(
            for: .standard(isCombination: true),
            phase: .running,
            progressLabel: "Rep 1 / 5 · Step 2 / 4",
            feedback: "Tracking paused · hold both fists in guard",
            trackingPaused: true
        )
        #expect(paused == ImmersiveInstruction(
            stage: "TRAINING PAUSED",
            message: "Tracking paused · hold both fists in guard",
            symbol: "pause.circle.fill"
        ))

        let stopped = ImmersiveInstructionPolicy.instruction(
            for: .standard(isCombination: false),
            phase: .finished,
            progressLabel: "Round complete",
            feedback: "Drill stopped",
            trackingPaused: false
        )
        #expect(stopped == ImmersiveInstruction(
            stage: "TRAINING STOPPED",
            message: "Your training was stopped",
            symbol: "stop.circle.fill"
        ))
    }

    @Test("Every reactive selection maps to its visible training context")
    func selectionMappingIsExhaustive() throws {
        #expect(ImmersiveTrainingContext(selection: .reactive(
            mode: .air,
            combination: nil,
            stance: .orthodox
        )) == .standard(isCombination: false))
        #expect(ImmersiveTrainingContext(selection: .reactive(
            mode: .combination,
            combination: .oneTwo,
            stance: .southpaw
        )) == .standard(isCombination: true))
        #expect(ImmersiveTrainingContext(selection: .reachCalibration) == .reachCalibration)

        let playerID = UUID(uuidString: "5C2F7FD7-4D9E-4232-9D34-68A057DC9DF7")!
        #expect(ImmersiveTrainingContext(
            selection: .competitionCalibration(playerID: playerID)
        ) == .competitionCalibration)

        let reach = try #require(BilateralReach(left: 0.62, right: 0.60))
        #expect(ImmersiveTrainingContext(selection: .competition(
            playerID: playerID,
            mode: .reactiveStrike,
            stance: .orthodox,
            reach: reach
        )) == .competition(isCombination: false))
        #expect(ImmersiveTrainingContext(selection: .competition(
            playerID: playerID,
            mode: .combination,
            stance: .southpaw,
            reach: reach
        )) == .competition(isCombination: true))
    }

    @Test("Completion announcements name the experience that just finished")
    func completionAnnouncementsAreContextSpecific() {
        #expect(ImmersiveInstructionPolicy.completionAnnouncement(
            for: .standard(isCombination: false),
            wasStoppedBeforeCompletion: false
        ) == "Reactive Strike complete")
        #expect(ImmersiveInstructionPolicy.completionAnnouncement(
            for: .reachCalibration,
            wasStoppedBeforeCompletion: false
        ) == "Reach calibration complete")
        #expect(ImmersiveInstructionPolicy.completionAnnouncement(
            for: .competitionCalibration,
            wasStoppedBeforeCompletion: false
        ) == "Competition fit complete")
        #expect(ImmersiveInstructionPolicy.completionAnnouncement(
            for: .competition(isCombination: false),
            wasStoppedBeforeCompletion: false
        ) == "Ranked round complete")
        #expect(ImmersiveInstructionPolicy.completionAnnouncement(
            for: .competition(isCombination: true),
            wasStoppedBeforeCompletion: false
        ) == "Ranked round complete")
        #expect(ImmersiveInstructionPolicy.completionAnnouncement(
            for: .competition(isCombination: false),
            wasStoppedBeforeCompletion: true
        ) == nil)
    }

    @Test("Essential guidance grows vertically at accessibility text sizes")
    func compactBannerDoesNotTruncateAccessibilityCopy() {
        #expect(ImmersiveInstructionBannerLayout.messageLineLimit(
            for: .compact,
            isAccessibilitySize: false
        ) == 3)
        #expect(ImmersiveInstructionBannerLayout.messageLineLimit(
            for: .compact,
            isAccessibilitySize: true
        ) == nil)
    }
}
