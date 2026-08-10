import XCTest
import simd
@testable import BoxingCoach

@MainActor
extension BodyCalibration {
    /// A body that has already been through Anthropometry, so tests can exercise the routes that
    /// sit behind the app-entry calibration gate.
    static var calibratedFixture: BodyCalibration {
        let calibration = BodyCalibration()
        calibration.store(
            reaches: [.left: 0.66, .right: 0.64],
            guardPositionsBody: [
                .left: SIMD3(-0.14, -0.04, 0.20),
                .right: SIMD3(0.14, -0.04, 0.20)
            ]
        )
        return calibration
    }
}

@MainActor
final class TrainingFlowCoordinatorTests: XCTestCase {
    func testAnUncalibratedLaunchOpensStraightIntoAnthropometry() {
        let flow = TrainingFlowCoordinator()

        XCTAssertEqual(flow.route, .experience(.calibration))
        XCTAssertFalse(flow.calibration.isCalibrated)

        // Every other feature stays behind the gate until a measurement exists.
        flow.chooseFeature(.reactiveStrike)
        XCTAssertEqual(flow.route, .experience(.calibration))
        flow.chooseFeature(.auraPunch)
        XCTAssertEqual(flow.route, .experience(.calibration))
    }

    func testACalibratedLaunchStartsAtTheFeatureMenuAndCanRemeasure() {
        let flow = TrainingFlowCoordinator(calibration: .calibratedFixture)

        XCTAssertEqual(flow.route, .features)

        flow.chooseFeature(.anthropometry)
        XCTAssertEqual(flow.route, .experience(.calibration))

        flow.finishCalibration()
        XCTAssertEqual(flow.route, .features)
    }

    func testCalibrationIsSharedAcrossEveryReactiveModeInsteadOfPerMode() throws {
        let calibration = BodyCalibration.calibratedFixture
        let session = ReactiveStrikeSession(calibration: calibration)
        let measuredReach = try XCTUnwrap(calibration.measuredReach)

        // The shorter arm sets the volume for all three modes.
        XCTAssertEqual(measuredReach, 0.64, accuracy: 1e-6)

        var profilesByMode: [ReactiveStrikeMode: ReachProfile] = [:]
        for mode in ReactiveStrikeMode.allCases {
            session.configure(mode: mode, combination: .oneTwo, stance: .orthodox)
            profilesByMode[mode] = session.reachProfile
        }

        for (mode, profile) in profilesByMode {
            XCTAssertEqual(
                profile.forwardMax,
                0.64,
                accuracy: 1e-6,
                "\(mode) must reuse the one measurement rather than re-deriving its own"
            )
        }

        // Switching modes never invalidates the measurement.
        XCTAssertTrue(calibration.isCalibrated)
    }

    func testAirRoutesDirectlyToExperienceWhileCombinationRoutesToSetup() {
        let flow = TrainingFlowCoordinator(calibration: .calibratedFixture)

        flow.chooseFeature(.reactiveStrike)
        XCTAssertEqual(flow.route, .reactiveSetup)

        flow.chooseReactiveMode(.air)
        XCTAssertEqual(
            flow.route,
            .experience(.reactive(mode: .air, combination: nil, stance: .orthodox))
        )

        let combinationFlow = TrainingFlowCoordinator(calibration: .calibratedFixture)
        combinationFlow.chooseFeature(.reactiveStrike)
        combinationFlow.chooseReactiveMode(.combination)

        XCTAssertEqual(combinationFlow.route, .combinationSetup)
    }

    func testChoosingCombinationCommitsCombinationAndStanceToSelection() {
        let flow = TrainingFlowCoordinator(calibration: .calibratedFixture)
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
        let flow = TrainingFlowCoordinator(calibration: .calibratedFixture)
        flow.chooseFeature(.reactiveStrike)
        flow.chooseReactiveMode(.combination)
        flow.setDraftStance(.southpaw)

        flow.backFromSetup()

        XCTAssertEqual(flow.route, .reactiveSetup)
        XCTAssertEqual(flow.draftStance, .southpaw)
    }

    func testCompetitionSetupUsesTheSameFullWindowProgressionAsTraining() {
        let flow = TrainingFlowCoordinator()

        flow.enterCompetitionSetup(stance: .southpaw)
        XCTAssertEqual(flow.route, .competitionSetup)
        XCTAssertEqual(flow.draftStance, .southpaw)

        // Competition setup is one level deep now that Combo is not a ranked mode: there is no
        // intermediate stance screen, so Back goes straight home.
        flow.backFromSetup()
        XCTAssertEqual(flow.route, .features)
        XCTAssertEqual(flow.draftStance, .southpaw)
    }

    func testReturningFromAPreparedRankedRunRestoresCompetitionSetup() async {
        let flow = TrainingFlowCoordinator()
        let session = ReactiveStrikeSession()
        let reach = try! XCTUnwrap(BilateralReach(left: 0.62, right: 0.60))
        let selection = TrainingSelection.competition(
            playerID: UUID(),
            mode: .reactiveStrike,
            stance: .southpaw,
            reach: reach
        )

        flow.enterCompetitionSetup(stance: .southpaw)
        flow.navigate(to: .experience(selection))

        await flow.returnToSetup(
            from: selection,
            session: session,
            dismissImmersive: {}
        )

        XCTAssertEqual(flow.route, .competitionSetup)
        XCTAssertEqual(flow.draftStance, .southpaw)
    }

    func testCompletedCompetitionUsesAFullWindowResultRoute() {
        let flow = TrainingFlowCoordinator()

        flow.enterCompetitionResult()

        XCTAssertEqual(flow.route, .competitionResult)
    }

    func testCompetitionCalibrationUsesDedicatedAtomicCalibrationWorkflow() async {
        let calibration = BodyCalibration.calibratedFixture
        let session = ReactiveStrikeSession(calibration: calibration)
        let flow = TrainingFlowCoordinator(calibration: calibration)
        let selection = TrainingSelection.competitionCalibration(playerID: UUID())
        flow.navigate(to: .experience(selection))
        flow.immersiveSceneDidBecomeReady(session: session)
        var openCallCount = 0
        var hideCallCount = 0

        await flow.startExperience(
            selection,
            session: session,
            supportsMultipleScenes: true,
            openImmersive: { _ in
                openCallCount += 1
                return .opened
            },
            dismissImmersive: {},
            hideControlWindow: { hideCallCount += 1 }
        )

        XCTAssertEqual(openCallCount, 0)
        XCTAssertEqual(hideCallCount, 1)
        XCTAssertEqual(session.phase, .calibrating)
        XCTAssertTrue(
            calibration.isCalibrated,
            "A replacement must not erase the last complete result before both arms succeed"
        )
        session.stopDrill()
    }

    func testReturningFromCombinationExperienceRestoresStanceWithoutDismissingImmersion() async {
        let flow = TrainingFlowCoordinator(calibration: .calibratedFixture)
        let session = ReactiveStrikeSession(calibration: .calibratedFixture)
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
        let flow = TrainingFlowCoordinator(calibration: .calibratedFixture)
        let session = ReactiveStrikeSession(calibration: .calibratedFixture)
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
