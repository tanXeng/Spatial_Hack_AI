import XCTest
@testable import BoxingCoach

final class OrderedReachCalibrationTests: XCTestCase {
    func testRequiresLeftGuardAndReachBeforeRightCanAdvance() {
        var sequence = OrderedReachCalibration()

        XCTAssertEqual(sequence.stage, .awaitingGuard(.left))
        XCTAssertEqual(sequence.activeSide, .left)
        XCTAssertFalse(sequence.confirmGuard(for: .right))
        XCTAssertFalse(sequence.acceptSettledReach(0.68, for: .right))

        XCTAssertTrue(sequence.confirmGuard(for: .left))
        XCTAssertEqual(sequence.stage, .measuring(.left))
        XCTAssertFalse(sequence.acceptSettledReach(0.68, for: .right))
        XCTAssertNil(sequence.completedReaches)

        XCTAssertTrue(sequence.acceptSettledReach(0.64, for: .left))
        XCTAssertEqual(sequence.stage, .awaitingGuard(.right))
        XCTAssertEqual(sequence.activeSide, .right)
    }

    func testCompletesOnlyAfterAValidRightReach() throws {
        var sequence = OrderedReachCalibration()
        XCTAssertTrue(sequence.confirmGuard(for: .left))
        XCTAssertTrue(sequence.acceptSettledReach(0.64, for: .left))
        XCTAssertTrue(sequence.confirmGuard(for: .right))

        XCTAssertFalse(sequence.acceptSettledReach(.infinity, for: .right))
        XCTAssertNil(sequence.completedReaches)
        XCTAssertTrue(sequence.acceptSettledReach(0.69, for: .right))

        let reaches = try XCTUnwrap(sequence.completedReaches)
        XCTAssertEqual(reaches[.left], 0.64)
        XCTAssertEqual(reaches[.right], 0.69)
        XCTAssertEqual(sequence.stage, .complete)
        XCTAssertNil(sequence.activeSide)
    }

    /// The calibration screen renders per-arm progress from the published stage alone, so the
    /// stage has to answer "which arm" and "guard or measuring" without the sequence in hand.
    func testStageDescribesTheActiveArmAndWhetherItIsMeasuring() {
        XCTAssertEqual(OrderedReachCalibration.Stage.awaitingGuard(.left).activeSide, .left)
        XCTAssertFalse(OrderedReachCalibration.Stage.awaitingGuard(.left).isMeasuring)

        XCTAssertEqual(OrderedReachCalibration.Stage.measuring(.right).activeSide, .right)
        XCTAssertTrue(OrderedReachCalibration.Stage.measuring(.right).isMeasuring)

        XCTAssertNil(OrderedReachCalibration.Stage.complete.activeSide)
        XCTAssertFalse(OrderedReachCalibration.Stage.complete.isMeasuring)
    }

    /// Every stage the sequence can publish must name an arm except the terminal one — otherwise
    /// the screen would show both arms as "Waiting" partway through a real measurement.
    func testEveryNonTerminalStageNamesAnArm() {
        var sequence = OrderedReachCalibration()
        var seen: [OrderedReachCalibration.Stage] = [sequence.stage]

        sequence.confirmGuard(for: .left)
        seen.append(sequence.stage)
        sequence.acceptSettledReach(0.64, for: .left)
        seen.append(sequence.stage)
        sequence.confirmGuard(for: .right)
        seen.append(sequence.stage)
        sequence.acceptSettledReach(0.69, for: .right)
        seen.append(sequence.stage)

        XCTAssertEqual(seen.count, 5)
        for stage in seen.dropLast() {
            XCTAssertNotNil(stage.activeSide, "\(stage) leaves the screen with no active arm")
        }
        XCTAssertEqual(seen.last, .complete)
    }
}
