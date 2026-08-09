import XCTest
@testable import BoxingCoach

@MainActor
final class TrainingFlowCoordinatorTests: XCTestCase {
    func testAppStartsOnFeatureSelection() {
        XCTAssertEqual(TrainingFlowCoordinator().route, .features)
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

        XCTAssertEqual(
            flow.route,
            .experience(.reactive(
                mode: .combination,
                combination: .jabCrossHookCross,
                stance: .southpaw
            ))
        )
    }

    func testCompetitionSelectionsRemainDistinctFromNormalTraining() throws {
        let playerID = UUID()
        let reach = try XCTUnwrap(BilateralReach(left: 0.66, right: 0.68))
        XCTAssertEqual(
            TrainingSelection.competitionCalibration(playerID: playerID).feature,
            .reactiveStrike
        )
        XCTAssertEqual(
            TrainingSelection.competition(
                playerID: playerID,
                mode: .combination,
                stance: .southpaw,
                reach: reach
            ).feature,
            .reactiveStrike
        )
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
        let selection = TrainingSelection.reactive(
            mode: .combination,
            combination: .doubleJabCross,
            stance: .southpaw
        )
        flow.navigate(to: .experience(selection))
        var dismissCallCount = 0

        await flow.returnToSetup(
            from: selection,
            session: session,
            dismissImmersive: { dismissCallCount += 1 }
        )

        XCTAssertEqual(dismissCallCount, 0)
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
}
