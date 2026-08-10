import XCTest
@testable import BoxingCoach

@MainActor
final class TrainingFlowCoordinatorTests: XCTestCase {
    func testLandingCalibrationShowsPreflightWithoutStartingImmersion() {
        let flow = TrainingFlowCoordinator()
        let session = ReactiveStrikeSession()

        flow.showLandingCalibrationPreflight()

        XCTAssertEqual(flow.route, .experience(.reachCalibration))
        XCTAssertEqual(flow.transition, .idle)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.isImmersiveSpaceOpen)
    }

    func testAuraRequiresTrackSelectionBeforeTechniqueSelection() {
        let flow = TrainingFlowCoordinator()

        flow.chooseFeature(.auraPunch)
        XCTAssertEqual(flow.route, .auraTrackSetup)

        flow.chooseAuraTechnique(.jab)
        XCTAssertEqual(flow.route, .auraTrackSetup)

        flow.chooseAuraTrack(.technicalCamp)
        XCTAssertEqual(flow.route, .auraSetup(.technicalCamp))

        flow.setDraftStance(.southpaw)
        flow.chooseAuraTechnique(.uppercut)
        XCTAssertEqual(
            flow.route,
            .experience(
                .aura(
                    track: .technicalCamp,
                    technique: .uppercut,
                    stance: .southpaw
                )
            )
        )
    }

    func testAirRoutesDirectlyToExperienceWhileCombinationRoutesToSetup() {
        let flow = TrainingFlowCoordinator()

        flow.chooseFeature(.reactiveStrike)
        XCTAssertEqual(flow.route, .reactiveSetup)

        flow.chooseReactiveMode(.air)
        XCTAssertEqual(
            flow.route,
            .experience(.reactive(mode: .air, combination: nil, stance: .orthodox))
        )

        let combinationFlow = TrainingFlowCoordinator()
        combinationFlow.chooseFeature(.reactiveStrike)
        combinationFlow.chooseReactiveMode(.combination)

        XCTAssertEqual(combinationFlow.route, .combinationSetup)
    }

    func testChoosingCombinationCommitsCombinationAndStanceToSelection() {
        let flow = TrainingFlowCoordinator()
        flow.chooseFeature(.reactiveStrike)
        flow.chooseReactiveMode(.combination)
        flow.setDraftStance(.southpaw)
        flow.chooseCombination(.jabCrossHookCross)

        guard case .experience(
            .reactive(let mode, let combination, let stance)
        ) = flow.route else {
            return XCTFail("Expected a committed Reactive Strike selection")
        }

        XCTAssertEqual(mode, .combination)
        XCTAssertEqual(combination, .jabCrossHookCross)
        XCTAssertEqual(stance, .southpaw)
    }

    func testBackFromCombinationSetupReturnsToReactiveModeSelection() {
        let flow = TrainingFlowCoordinator()
        flow.chooseFeature(.reactiveStrike)
        flow.chooseReactiveMode(.combination)
        flow.setDraftStance(.southpaw)

        flow.backFromSetup()

        XCTAssertEqual(flow.route, .reactiveSetup)
        XCTAssertEqual(flow.draftStance, .southpaw)
    }

    func testReturningFromCombinationExperienceRestoresStanceWithoutDismissingImmersion() async {
        let flow = TrainingFlowCoordinator()
        let session = ReactiveStrikeSession()
        flow.chooseFeature(.reactiveStrike)
        flow.chooseReactiveMode(.combination)
        flow.setDraftStance(.southpaw)
        flow.chooseCombination(.doubleJabCross)

        let selection = TrainingSelection.reactive(
            mode: .combination,
            combination: .doubleJabCross,
            stance: .southpaw
        )
        XCTAssertEqual(flow.route, .experience(selection))
        XCTAssertFalse(session.isImmersiveSpaceOpen)

        // Prove the committed selection, rather than incidental draft state, restores the stance.
        flow.setDraftStance(.orthodox)
        var dismissCallCount = 0

        await flow.returnToSetup(
            from: selection,
            session: session,
            dismissImmersive: { dismissCallCount += 1 }
        )

        XCTAssertEqual(dismissCallCount, 0)
        XCTAssertFalse(session.isImmersiveSpaceOpen)
        XCTAssertEqual(flow.draftStance, .southpaw)
        XCTAssertEqual(flow.route, .combinationSetup)
        XCTAssertEqual(flow.transition, .idle)
    }

    func testEndTrainingCancelsTheEngineBeforeDismissingImmersion() async {
        let flow = TrainingFlowCoordinator()
        let session = ReactiveStrikeSession()
        session.immersiveSpaceDidOpen()
        session.startDrill()
        XCTAssertEqual(session.phase, .calibrating)

        var dismissCallCount = 0
        await flow.endExperience(
            session: session,
            showControlWindow: { flow.controlWindowDidAppear() },
            dismissImmersive: { dismissCallCount += 1 }
        )

        XCTAssertEqual(dismissCallCount, 1)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.lastFeedback, "Drill stopped")
        XCTAssertFalse(session.isImmersiveSpaceOpen)
        XCTAssertEqual(flow.transition, .idle)
    }

    func testSystemDismissalAndParticipantHandoffInvalidateIssuedCommands() {
        let flow = TrainingFlowCoordinator()
        let session = ReactiveStrikeSession()

        flow.immersiveSceneDidBecomeReady(session: session)
        let beforeSystemDismissal = flow.commandGeneration
        flow.immersiveSceneDidClose(session: session)
        XCTAssertGreaterThan(flow.commandGeneration, beforeSystemDismissal)

        let beforeHandoff = flow.commandGeneration
        flow.participantDidChange(session: session)
        XCTAssertGreaterThan(flow.commandGeneration, beforeHandoff)
    }
}
