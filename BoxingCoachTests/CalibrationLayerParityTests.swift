import XCTest
@testable import BoxingCoach

/// Guards the places where the training (Anthropometry gate) and Competition calibration paths
/// are allowed to differ — and, more importantly, the places they are not.
///
/// All three cases below were live defects found by auditing the two layers against each other.
@MainActor
final class CalibrationLayerParityTests: XCTestCase {

    // MARK: Per-arm progress is the run's own, not the shared calibration's

    /// A re-measure must open with both arms unmeasured.
    ///
    /// `BodyCalibration` is only written when both arms succeed, so during a re-calibration it
    /// still holds the previous run's numbers. Driving the per-arm rows from it made every
    /// re-measure start with both arms ticked off at stale values and no live meter — which is the
    /// *normal* path in Competition, where the reach arrives pre-populated from the player record.
    func testStartingACalibrationClearsPerArmProgressEvenWhenAlreadyCalibrated() {
        let calibration = BodyCalibration.calibratedFixture
        let session = ReactiveStrikeSession(calibration: calibration)
        XCTAssertTrue(calibration.isCalibrated, "fixture should start already measured")

        session.startCalibration()

        XCTAssertTrue(
            session.calibrationMeasuredReaches.isEmpty,
            "per-arm progress must describe this run, not the previous measurement"
        )
        XCTAssertEqual(session.calibrationStage, .awaitingGuard(.left))
        XCTAssertEqual(session.calibrationLiveExtension, 0)
        // The old measurement is deliberately still intact: replacement is atomic, so abandoning
        // this run leaves the previous body in place.
        XCTAssertTrue(calibration.isCalibrated)

        session.stopDrill()
    }

    func testCompetitionCalibrationClearsPerArmProgressTheSameWay() {
        let calibration = BodyCalibration.calibratedFixture
        let session = ReactiveStrikeSession(calibration: calibration)

        session.startCompetitionCalibration()

        XCTAssertTrue(session.calibrationMeasuredReaches.isEmpty)
        XCTAssertEqual(session.calibrationStage, .awaitingGuard(.left))

        session.stopDrill()
    }

    func testEndingACalibrationClearsPublishedProgress() {
        let session = ReactiveStrikeSession()
        session.startCalibration()
        XCTAssertNotNil(session.calibrationStage)

        session.resetForNewRound()

        XCTAssertNil(session.calibrationStage)
        XCTAssertTrue(session.calibrationMeasuredReaches.isEmpty)
        XCTAssertEqual(session.calibrationLiveExtension, 0)
    }

    // MARK: A standalone re-measure must not be discarded by the next ranked run

    /// Anthropometry writes only the shared `BodyCalibration`. Without propagation the next ranked
    /// run passes the player's *stale* persisted reach to `configureCompetition`, which stores it
    /// back over the shared calibration — losing the measurement the user just took, and leaving
    /// the old one in place for Aura Punch and regular Reactive Strike as well.
    func testStandaloneRecalibrationReachesTheSignedInPlayer() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository)
        await store.join(name: "Alex")

        let stale = try XCTUnwrap(BilateralReach(left: 0.64, right: 0.69))
        await store.adoptStandaloneCalibration(stale.bySide)
        XCTAssertEqual(store.currentPlayer?.reach, stale)

        let fresh = try XCTUnwrap(BilateralReach(left: 0.58, right: 0.60))
        await store.adoptStandaloneCalibration(fresh.bySide)

        XCTAssertEqual(store.currentPlayer?.reach, fresh, "the newer measurement must win")
        let persisted = try await repository.player(normalizedName: "alex")
        XCTAssertEqual(persisted?.reach, fresh, "and must survive a reload")
    }

    /// Propagation must not fight `reconcileCompletedRun` for ownership of an in-flight run, and
    /// must not thrash the store when nothing changed.
    func testAdoptionIsInertWithoutAPlayerDuringARunOrWhenUnchanged() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository)
        let reach = try XCTUnwrap(BilateralReach(left: 0.62, right: 0.66))

        // No player signed in.
        await store.adoptStandaloneCalibration(reach.bySide)
        XCTAssertNil(store.currentPlayer)

        await store.join(name: "Alex")
        await store.adoptStandaloneCalibration(reach.bySide)
        let calibratedAt = try XCTUnwrap(store.currentPlayer?.calibratedAt)

        // Unchanged value: no rewrite, so the calibration timestamp holds.
        await store.adoptStandaloneCalibration(reach.bySide)
        XCTAssertEqual(store.currentPlayer?.calibratedAt, calibratedAt)

        // A competition run owns the calibration while it is active.
        _ = store.prepareCalibration()
        XCTAssertNotNil(store.activeRun)
        let other = try XCTUnwrap(BilateralReach(left: 0.50, right: 0.52))
        await store.adoptStandaloneCalibration(other.bySide)
        XCTAssertEqual(store.currentPlayer?.reach, reach, "an active run owns the player's reach")
    }

    /// An implausible or half-finished measurement must never reach the player record.
    func testAdoptionRejectsAnIncompleteMeasurement() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository)
        await store.join(name: "Alex")

        await store.adoptStandaloneCalibration([:])
        XCTAssertNil(store.currentPlayer?.reach)

        await store.adoptStandaloneCalibration([.left: 0.64])
        XCTAssertNil(store.currentPlayer?.reach, "one arm is not a bilateral reach")
    }
}
