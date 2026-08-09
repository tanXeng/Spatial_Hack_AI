import XCTest
import simd
@testable import BoxingCoach

final class CombinationPunchValidatorTests: XCTestCase {
    private let guardPosition = SIMD3<Float>(0, 0, 0)
    private let targetPosition = SIMD3<Float>(0, 0, 0.60)
    private let hitRadius: Float = 0.05

    func testStanceMapsLeadAndRearPunchesToTheCorrectPhysicalHands() {
        let leadPunches: [PunchType] = [.jab, .leadHook, .leadUppercut]
        let rearPunches: [PunchType] = [.cross, .rearHook, .rearUppercut]

        for punch in leadPunches {
            XCTAssertEqual(punch.requiredHand(for: .orthodox), .left)
            XCTAssertEqual(punch.requiredHand(for: .southpaw), .right)
        }

        for punch in rearPunches {
            XCTAssertEqual(punch.requiredHand(for: .orthodox), .right)
            XCTAssertEqual(punch.requiredHand(for: .southpaw), .left)
        }

        XCTAssertEqual(Combination.oneTwo.requiredHands(for: .orthodox), [.left, .right])
        XCTAssertEqual(Combination.oneTwo.requiredHands(for: .southpaw), [.right, .left])
    }

    func testTargetsMirrorLaterallyBetweenOrthodoxAndSouthpaw() {
        let forwardBase: Float = 0.70

        for punch in PunchType.allCases {
            let orthodox = punch.targetPosition(forwardBase: forwardBase, stance: .orthodox)
            let southpaw = punch.targetPosition(forwardBase: forwardBase, stance: .southpaw)

            XCTAssertEqual(orthodox.x, -southpaw.x, accuracy: 1e-6, "\(punch) should mirror laterally")
            XCTAssertEqual(orthodox.y, southpaw.y, accuracy: 1e-6)
            XCTAssertEqual(orthodox.z, southpaw.z, accuracy: 1e-6)
        }
    }

    func testHookAndUppercutEndpointsCoachInwardAndUpwardFinishes() {
        for stance in Stance.allCases {
            for hook in [PunchType.leadHook, .rearHook] {
                let target = hook.targetPosition(forwardBase: 0.70, stance: stance)
                let side = hook.requiredHand(for: stance)
                XCTAssertLessThanOrEqual(
                    target.x * side.lateralSign,
                    0,
                    "A hook should finish inward from its throwing side"
                )
                XCTAssertGreaterThan(target.y, 0)
            }

            for uppercut in [PunchType.leadUppercut, .rearUppercut] {
                let target = uppercut.targetPosition(forwardBase: 0.70, stance: stance)
                XCTAssertEqual(target.x, 0, accuracy: 1e-6)
                XCTAssertGreaterThan(target.y, 0, "An uppercut should land above the shoulder line")
            }
        }
    }

    func testShortReachTargetsAreResolvedBeyondEachRequiredHandsGuard() throws {
        let guards: [BodySide: SIMD3<Float>] = [
            .left: SIMD3(0, 0, 0.40),
            .right: SIMD3(0, 0, 0.40)
        ]
        let minimumSeparation: Float = 0.16
        let maximumForward: Float = 0.592
        let authored = Combination.oneTwo.targets(forwardBase: 0.519, stance: .orthodox)
        let resolved = try XCTUnwrap(
            CombinationTargetResolver.resolve(
                authored,
                guardPositions: guards,
                minimumSeparation: minimumSeparation,
                maximumForward: maximumForward
            )
        )

        XCTAssertEqual(resolved.count, authored.count)
        for target in resolved {
            let guardPosition = try XCTUnwrap(guards[target.requiredHand])
            XCTAssertGreaterThanOrEqual(
                simd_distance(target.position, guardPosition),
                minimumSeparation - 1e-5
            )
            XCTAssertLessThanOrEqual(target.position.z, maximumForward)
            XCTAssertTrue(
                CombinationPunchValidator(
                    target: target,
                    guardPosition: guardPosition,
                    hitRadius: 0.12
                ).isValidConfiguration
            )
        }
    }

    func testStationaryRequiredFistAlreadyAtTargetCannotHit() {
        var validator = makeValidator()

        for frame in 0..<8 {
            let event = validator.observe(
                requiredFist: targetPosition,
                otherFist: nil,
                timestamp: Double(frame) * 0.016
            )
            XCTAssertEqual(event, .waiting)
        }

        XCTAssertEqual(validator.phase, .waitingForGuard)
    }

    func testWrongHandContactDoesNotAdvanceTheValidator() {
        var validator = makeValidator()

        XCTAssertEqual(
            validator.observe(requiredFist: guardPosition, otherFist: guardPosition, timestamp: 0),
            .waiting
        )
        XCTAssertEqual(validator.phase, .trackingOutbound)

        XCTAssertEqual(
            validator.observe(requiredFist: guardPosition, otherFist: targetPosition, timestamp: 0.05),
            .wrongHand
        )
        XCTAssertEqual(validator.phase, .trackingOutbound)

        XCTAssertEqual(
            validator.observe(requiredFist: guardPosition, otherFist: targetPosition, timestamp: 0.10),
            .waiting,
            "Holding the wrong fist in the target must not repeatedly trigger or advance"
        )
        XCTAssertEqual(validator.phase, .trackingOutbound)
    }

    func testOutboundMotionArmsThenLaterRequiredHandContactHits() {
        var validator = makeValidator()

        XCTAssertEqual(
            validator.observe(requiredFist: guardPosition, otherFist: nil, timestamp: 0),
            .waiting
        )
        XCTAssertEqual(
            validator.observe(requiredFist: targetPosition, otherFist: nil, timestamp: 0.05),
            .armed,
            "The outbound contact sample should arm, not hit, the validator"
        )
        XCTAssertEqual(validator.phase, .armed)

        XCTAssertEqual(
            validator.observe(requiredFist: targetPosition, otherFist: nil, timestamp: 0.066),
            .hit
        )
        XCTAssertEqual(validator.phase, .hit)
    }

    func testMissingTrackingFollowedByLongGapResetsPartialOutboundMotion() {
        var validator = makeValidator()

        _ = validator.observe(requiredFist: guardPosition, otherFist: nil, timestamp: 0)
        _ = validator.observe(
            requiredFist: SIMD3<Float>(0, 0, 0.05),
            otherFist: nil,
            timestamp: 0.05
        )
        XCTAssertEqual(validator.phase, .trackingOutbound)

        XCTAssertEqual(
            validator.observe(requiredFist: nil, otherFist: nil, timestamp: 0.10),
            .waiting
        )
        XCTAssertEqual(
            validator.observe(
                requiredFist: SIMD3<Float>(0, 0, 0.20),
                otherFist: nil,
                timestamp: 0.30
            ),
            .waiting
        )
        XCTAssertEqual(validator.phase, .waitingForGuard)

        XCTAssertEqual(
            validator.observe(requiredFist: targetPosition, otherFist: nil, timestamp: 0.35),
            .waiting,
            "An extended fist reacquired after a long gap must return to guard before rearming"
        )
        XCTAssertEqual(validator.phase, .waitingForGuard)
    }

    func testLongTrackingGapAfterArmingStillRequiresAFreshGuard() {
        var validator = makeValidator()

        _ = validator.observe(requiredFist: guardPosition, otherFist: nil, timestamp: 0)
        XCTAssertEqual(
            validator.observe(requiredFist: targetPosition, otherFist: nil, timestamp: 0.05),
            .armed
        )

        XCTAssertEqual(
            validator.observe(requiredFist: targetPosition, otherFist: nil, timestamp: 0.40),
            .waiting
        )
        XCTAssertEqual(validator.phase, .waitingForGuard)
        XCTAssertEqual(
            validator.observe(requiredFist: targetPosition, otherFist: nil, timestamp: 0.416),
            .waiting
        )
    }

    func testRetractionRequiresTheFistToReturnInsideTheGuardRadius() {
        XCTAssertTrue(
            CombinationPunchValidator.isRetracted(
                fist: SIMD3<Float>(CombinationPunchValidator.guardRadius, 0, 0),
                guardPosition: guardPosition,
                radius: CombinationPunchValidator.guardRadius
            )
        )
        XCTAssertFalse(
            CombinationPunchValidator.isRetracted(
                fist: SIMD3<Float>(CombinationPunchValidator.guardRadius + 0.001, 0, 0),
                guardPosition: guardPosition,
                radius: CombinationPunchValidator.guardRadius
            )
        )
        XCTAssertFalse(
            CombinationPunchValidator.isRetracted(
                fist: targetPosition,
                guardPosition: guardPosition,
                radius: CombinationPunchValidator.guardRadius
            )
        )
    }

    func testDoubleJabNeedsGuardReturnAndAFreshOutboundSequence() throws {
        let targets = Combination.doubleJabCross.targets(forwardBase: 0.60, stance: .orthodox)
        let firstJab = try XCTUnwrap(targets.first)
        let secondJab = targets[1]

        XCTAssertEqual(firstJab.requiredHand, .left)
        XCTAssertEqual(secondJab.requiredHand, .left)
        assertVectorEqual(firstJab.position, secondJab.position)

        var firstValidator = CombinationPunchValidator(
            target: firstJab,
            guardPosition: guardPosition,
            hitRadius: hitRadius
        )
        _ = firstValidator.observe(requiredFist: guardPosition, otherFist: nil, timestamp: 0)
        XCTAssertEqual(
            firstValidator.observe(requiredFist: firstJab.position, otherFist: nil, timestamp: 0.05),
            .armed
        )
        XCTAssertEqual(
            firstValidator.observe(requiredFist: firstJab.position, otherFist: nil, timestamp: 0.066),
            .hit
        )

        XCTAssertFalse(
            CombinationPunchValidator.isRetracted(
                fist: firstJab.position,
                guardPosition: guardPosition,
                radius: CombinationPunchValidator.guardRadius
            )
        )

        var secondValidator = CombinationPunchValidator(
            target: secondJab,
            guardPosition: guardPosition,
            hitRadius: hitRadius
        )
        XCTAssertEqual(
            secondValidator.observe(requiredFist: secondJab.position, otherFist: nil, timestamp: 0.082),
            .waiting
        )
        XCTAssertEqual(secondValidator.phase, .waitingForGuard)

        XCTAssertTrue(
            CombinationPunchValidator.isRetracted(
                fist: guardPosition,
                guardPosition: guardPosition,
                radius: CombinationPunchValidator.guardRadius
            )
        )
        _ = secondValidator.observe(requiredFist: guardPosition, otherFist: nil, timestamp: 0.10)
        XCTAssertEqual(secondValidator.phase, .trackingOutbound)
        XCTAssertEqual(
            secondValidator.observe(requiredFist: secondJab.position, otherFist: nil, timestamp: 0.15),
            .armed
        )
        XCTAssertEqual(
            secondValidator.observe(requiredFist: secondJab.position, otherFist: nil, timestamp: 0.166),
            .hit
        )
    }

    private func makeValidator() -> CombinationPunchValidator {
        CombinationPunchValidator(
            target: CombinationTarget(
                id: "test-jab",
                index: 0,
                punch: .jab,
                requiredHand: .left,
                position: targetPosition
            ),
            guardPosition: guardPosition,
            hitRadius: hitRadius
        )
    }

    private func assertVectorEqual(
        _ actual: SIMD3<Float>,
        _ expected: SIMD3<Float>,
        accuracy: Float = 1e-6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }
}
