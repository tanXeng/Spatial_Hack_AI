import XCTest
@testable import BoxingCoach

final class CompetitionDomainTests: XCTestCase {
    @MainActor
    func testConfigureCompetitionImmediatelyUsesPassedReach() throws {
        let calibration = BodyCalibration.calibratedFixture
        let session = ReactiveStrikeSession(calibration: calibration)
        let reach = try XCTUnwrap(BilateralReach(left: 0.58, right: 0.72))

        session.configureCompetition(mode: .reactiveStrike, stance: .orthodox, reach: reach)
        XCTAssertEqual(session.reachProfile.forwardMax, 0.58, accuracy: 0.0001)
        XCTAssertEqual(calibration.reaches, reach.bySide)
        XCTAssertEqual(calibration.measurements.armReach, 0.58, accuracy: 0.0001)
    }

    @MainActor
    func testPlayerHandoffAppliesReachAndClearsLaunchLocalGuards() throws {
        let calibration = BodyCalibration.calibratedFixture
        let session = ReactiveStrikeSession(calibration: calibration)
        let reach = try XCTUnwrap(BilateralReach(left: 0.61, right: 0.67))
        XCTAssertFalse(calibration.guardPositionsBody.isEmpty)

        session.applyPersistedCompetitionReach(reach, clearingGuards: true)

        XCTAssertEqual(calibration.reaches, reach.bySide)
        XCTAssertTrue(calibration.guardPositionsBody.isEmpty)
        session.configure(mode: .air, combination: nil, stance: .orthodox)
        XCTAssertEqual(session.reachProfile.forwardMax, 0.61, accuracy: 0.0001)
    }

    @MainActor
    /// Every ranked run is an eight-target Air drill. A ranked run must never leave Combination
    /// Mode selected on the session, which is what would happen if Combo were still competable.
    func testCompetitionSessionAlwaysUsesTheEightTargetAirDrill() throws {
        let session = ReactiveStrikeSession()
        let reach = try XCTUnwrap(BilateralReach(left: 0.64, right: 0.69))

        for stance in [Stance.orthodox, .southpaw] {
            session.configureCompetition(mode: .reactiveStrike, stance: stance, reach: reach)
            XCTAssertEqual(session.mode, .air)
            XCTAssertNil(CompetitionMode.allCases.first { $0 != .reactiveStrike })
            XCTAssertEqual(session.config.targetCount, 8)
            XCTAssertEqual(session.config.timeout, 4)
        }

        session.configure(mode: .air, combination: nil, stance: .orthodox)
        XCTAssertEqual(session.config, DrillConfig(), "Competition timing must not leak into normal training")
    }

    @MainActor
    func testPersistedPlayerReachFlowsIntoRegularReactiveAndComboThenClears() throws {
        let session = ReactiveStrikeSession()
        let reach = try XCTUnwrap(BilateralReach(left: 0.58, right: 0.72))
        let expected = ReachProfile.air.calibrated(measuredForwardReach: reach.conservative)

        session.applyPersistedCompetitionReach(reach)
        session.configure(mode: .air, combination: nil, stance: .orthodox)
        XCTAssertEqual(session.reachProfile.forwardMax, expected.forwardMax, accuracy: 0.0001)

        session.configure(mode: .combination, combination: .jabCrossHookCross, stance: .southpaw)
        XCTAssertEqual(session.reachProfile.forwardMax, expected.forwardMax, accuracy: 0.0001)

        session.applyPersistedCompetitionReach(nil)
        session.configure(mode: .air, combination: nil, stance: .orthodox)
        XCTAssertEqual(session.reachProfile.forwardMax, ReachProfile.air.forwardMax, accuracy: 0.0001)
    }

    @MainActor
    func testExplicitStopMarksCompetitionAsCancelledBeforeAnySubmission() throws {
        let session = ReactiveStrikeSession()
        let reach = try XCTUnwrap(BilateralReach(left: 0.62, right: 0.66))
        session.configureCompetition(mode: .reactiveStrike, stance: .orthodox, reach: reach)

        session.startDrill()
        session.stopDrill()

        XCTAssertTrue(session.wasStoppedBeforeCompletion)
        XCTAssertEqual(session.lastFeedback, "Drill stopped")
    }

    func testClosedFistPositionSurvivesMissingFingertips() throws {
        let knuckles = [
            SIMD3<Float>(-0.03, 0, 0),
            SIMD3<Float>(-0.01, 0.01, 0),
            SIMD3<Float>(0.01, 0.01, 0),
            SIMD3<Float>(0.03, 0, 0)
        ]

        let center = try XCTUnwrap(HandObservationGeometry.fistCenter(knuckles: knuckles))
        XCTAssertEqual(center.x, 0, accuracy: 0.0001)
        XCTAssertEqual(center.y, 0.005, accuracy: 0.0001)
        XCTAssertNil(HandObservationGeometry.fistCenter(knuckles: Array(knuckles.prefix(2))))

        // Missing tips reduce shape confidence, but no longer erase the usable fist position.
        XCTAssertEqual(
            FistStateClassifier.classify(fingertipToKnuckleRatios: [0.8, 0.9]),
            .uncertain
        )
    }

    func testCompetitionTrackingRecoveryNeedsConsecutiveStableEvidence() {
        var gate = CompetitionTrackingRecoveryGate()
        XCTAssertFalse(gate.observe(freshAndGuarded: true))
        XCTAssertFalse(gate.observe(freshAndGuarded: true))
        XCTAssertFalse(gate.observe(freshAndGuarded: false))
        XCTAssertEqual(gate.consecutiveStableSamples, 0)

        for _ in 0..<(CompetitionTrackingRecoveryGate.requiredStableSamples - 1) {
            XCTAssertFalse(gate.observe(freshAndGuarded: true))
        }
        XCTAssertTrue(gate.observe(freshAndGuarded: true))
    }

    func testGuardCoachUsesTheRoundCapturedGuardInsteadOfAnAverageBodyPose() {
        let captured = SIMD3<Float>(-0.24, 0.12, 0.31)
        XCTAssertEqual(
            GuardCoach.isGuardUp(
                guardFistBody: captured + SIMD3<Float>(0.04, -0.03, 0.02),
                capturedGuardBody: captured
            ),
            true
        )
        XCTAssertEqual(
            GuardCoach.isGuardUp(
                guardFistBody: captured + SIMD3<Float>(0, -0.30, 0),
                capturedGuardBody: captured
            ),
            false
        )
        XCTAssertNil(GuardCoach.isGuardUp(guardFistBody: nil, capturedGuardBody: captured))
    }

    func testPunchingHandRequiresOutboundTravelInsteadOfTargetProximity() {
        let target = SIMD3<Float>(0, 0, 1)
        let starts: [BodySide: SIMD3<Float>] = [
            .left: SIMD3<Float>(-0.2, 0, 0.3),
            .right: SIMD3<Float>(0.2, 0, 0.3)
        ]

        XCTAssertNil(GuardCoach.punchingSide(
            current: [.left: SIMD3<Float>(-0.02, 0, 0.95), .right: starts[.right]!],
            starts: [.right: starts[.right]!],
            target: target
        ), "A nearby lowered hand without a captured outbound start must not become the punch")

        XCTAssertEqual(GuardCoach.punchingSide(
            current: [.left: starts[.left]!, .right: SIMD3<Float>(0.12, 0, 0.62)],
            starts: starts,
            target: target
        ), .right)
    }

    func testNameNormalizationCollapsesWhitespaceAndReopensEquivalentNames() throws {
        let display = try CompetitionName.display("  José   Lee  ")
        XCTAssertEqual(display, "José Lee")
        XCTAssertEqual(CompetitionName.normalized(display), "jose lee")
        XCTAssertEqual(CompetitionName.normalized("JOSE LEE"), "jose lee")
        XCTAssertThrowsError(try CompetitionName.display("A"))
        XCTAssertThrowsError(try CompetitionName.display("Player!"))
    }

    func testReactiveScoreBoundariesAndMisses() throws {
        let player = makePlayer()
        let perfect = makeEvidence(mode: .reactiveStrike, validCount: 8, error: 0)
        let zero = makeEvidence(mode: .reactiveStrike, validCount: 0, error: 0)
        let halfAtEdge = makeEvidence(
            mode: .reactiveStrike,
            validCount: 4,
            error: CompetitionScorer.targetRadius
        )

        XCTAssertEqual(try XCTUnwrap(submission(player: player, evidence: perfect)).score, 100)
        XCTAssertEqual(try XCTUnwrap(submission(player: player, evidence: zero)).score, 0)
        XCTAssertEqual(try XCTUnwrap(submission(player: player, evidence: halfAtEdge)).score, 40)
    }

    func testPartialStaleAndTechnicalEvidenceCannotSubmit() {
        let player = makePlayer()
        let partial = CompetitionEvidence(
            mode: .reactiveStrike,
            steps: Array(makeEvidence(mode: .reactiveStrike, validCount: 8, error: 0).steps.prefix(7)),
            completedRepetitions: 0,
            activeElapsedTime: nil,
            trackingStatus: .complete
        )
        XCTAssertNil(submission(player: player, evidence: partial))

        for status in [CompetitionTrackingStatus.stale, .technicalFailure] {
            let invalid = CompetitionEvidence(
                mode: .reactiveStrike,
                steps: makeEvidence(mode: .reactiveStrike, validCount: 8, error: 0).steps,
                completedRepetitions: 0,
                activeElapsedTime: nil,
                trackingStatus: status
            )
            XCTAssertNil(submission(player: player, evidence: invalid))
        }
    }

    func testSpeedBreaksOnlyOtherwiseEqualScoresAndExactTiesShareRank() {
        let a = directSubmission(id: 1, player: 1, name: "Alex", score: 90, reaction: 0.4)
        let b = directSubmission(id: 2, player: 2, name: "Blair", score: 90, reaction: 0.3)
        let c = directSubmission(id: 3, player: 3, name: "Casey", score: 90, reaction: 0.3)

        let standings = CompetitionLeaderboard.standings(
            mode: .reactiveStrike,
            submissions: [a, b, c]
        )
        XCTAssertEqual(standings.map(\.submission.playerName), ["Blair", "Casey", "Alex"])
        XCTAssertEqual(standings.map(\.rank), [1, 1, 3])
    }

    func testUnlimitedAttemptsUseEachPlayersBestModeSpecificResult() {
        let attempts = [
            directSubmission(id: 1, player: 1, name: "Alex", score: 60, reaction: 0.2),
            directSubmission(id: 2, player: 1, name: "Alex", score: 95, reaction: 0.5),
            directSubmission(id: 3, player: 1, name: "Alex", score: 80, reaction: 0.3),
            directSubmission(id: 4, player: 2, name: "Blair", score: 90, reaction: 0.2)
        ]
        let standings = CompetitionLeaderboard.standings(
            mode: .reactiveStrike,
            submissions: attempts
        )
        XCTAssertEqual(standings.count, 2)
        XCTAssertEqual(standings[0].submission.score, 95)
        XCTAssertEqual(standings[0].submission.playerName, "Alex")
    }

    private func makePlayer() -> CompetitionPlayer {
        CompetitionPlayer(
            id: UUID(),
            name: "Alex",
            normalizedName: "alex",
            rememberedStance: .orthodox,
            reach: BilateralReach(left: 0.68, right: 0.70),
            calibrationVersion: CompetitionPlayer.calibrationVersion,
            calibratedAt: Date(timeIntervalSince1970: 10),
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 10)
        )
    }

    private func makeEvidence(
        mode: CompetitionMode,
        validCount: Int,
        error: Float
    ) -> CompetitionEvidence {
        let steps = (0..<mode.totalSteps).map { index in
            CompetitionStepEvidence(
                index: index,
                valid: index < validCount,
                centreErrorMeters: index < validCount ? error : nil,
                reactionTime: index < validCount ? 0.35 : nil,
                requiredHand: nil,
                returnedToGuard: index < validCount
            )
        }
        return CompetitionEvidence(
            mode: mode,
            steps: steps,
            completedRepetitions: 0,
            activeElapsedTime: nil,
            trackingStatus: .complete
        )
    }

    private func submission(
        player: CompetitionPlayer,
        evidence: CompetitionEvidence
    ) -> CompetitionSubmission? {
        CompetitionScorer.submission(
            id: UUID(),
            player: player,
            evidence: evidence,
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 20)
        )
    }

    private func directSubmission(
        id: UInt8,
        player: UInt8,
        name: String,
        score: Int,
        reaction: TimeInterval
    ) -> CompetitionSubmission {
        CompetitionSubmission(
            id: uuid(id),
            playerID: uuid(player + 50),
            playerName: name,
            normalizedPlayerName: name.lowercased(),
            mode: .reactiveStrike,
            score: score,
            validSteps: 7,
            totalSteps: 8,
            completedRepetitions: 0,
            meanCentreErrorMeters: 0.02,
            speedTieBreakSeconds: reaction,
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            trackingStatus: .complete
        )
    }

    private func uuid(_ suffix: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix))
    }
}
