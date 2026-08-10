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
}
