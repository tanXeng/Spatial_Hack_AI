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
            let capturedGuard = try XCTUnwrap(guards[target.requiredHand])
            XCTAssertGreaterThanOrEqual(
                simd_distance(target.position, capturedGuard),
                minimumSeparation - 1e-5
            )
            XCTAssertLessThanOrEqual(target.position.z, maximumForward)
            XCTAssertTrue(
                CombinationPunchValidator(
                    target: target,
                    stance: .orthodox,
                    guardPosition: capturedGuard,
                    hitRadius: 0.12,
                    generation: 4,
                    continuityEpoch: 9
                ).isValidConfiguration
            )
        }
    }

    func testWrapperRequiresOutboundContactRetractionAndSameChainCoverage() throws {
        let target = makeTarget(punch: .jab, requiredHand: .left)
        var validator = makeValidator(target: target, stance: .orthodox)

        XCTAssertEqual(validator.observe(frame(left: guardPosition, timestamp: 1.00)),
                       .waiting(.trackingOutbound))
        XCTAssertEqual(validator.observe(frame(left: SIMD3(0, 0, 0.75), timestamp: 1.05)),
                       .contact)
        XCTAssertEqual(validator.observe(frame(left: SIMD3(0, 0, 0.30), timestamp: 1.10)),
                       .waiting(.trackingRetraction))
        XCTAssertEqual(validator.observe(frame(left: SIMD3(0, 0, 0.02), timestamp: 1.15)),
                       .readyForCoverage)

        let completion = validator.complete(
            coverage: PunchEvidenceValidator.Coverage(
                trackedFraction: 0.91,
                generation: 4,
                continuityEpoch: 9
            )
        )
        guard case let .validated(evidence) = completion else {
            return XCTFail("Expected validated combination evidence, got \(completion)")
        }
        XCTAssertEqual(evidence.technique, .jab)
        XCTAssertEqual(evidence.stance, .orthodox)
        XCTAssertEqual(evidence.side, .left)
    }

    func testWrapperMapsEveryPunchNumberToItsSemanticTechnique() {
        let expected: [(PunchType, Technique)] = [
            (.jab, .jab),
            (.cross, .cross),
            (.leadHook, .hook),
            (.rearHook, .hook),
            (.leadUppercut, .uppercut),
            (.rearUppercut, .uppercut)
        ]

        for (punch, technique) in expected {
            let side = punch.requiredHand(for: .southpaw)
            let validator = makeValidator(
                target: makeTarget(punch: punch, requiredHand: side),
                stance: .southpaw
            )
            XCTAssertEqual(validator.technique, technique)
            XCTAssertEqual(validator.requiredHand, side)
        }
    }

    func testWrapperRejectsMalformedLeadAndRearPhysicalSides() {
        let punches: [PunchType] = [
            .leadHook,
            .rearHook,
            .leadUppercut,
            .rearUppercut
        ]

        for stance in [Stance.orthodox, .southpaw] {
            for punch in punches {
                let expected = punch.requiredHand(for: stance)
                var validator = makeValidator(
                    target: makeTarget(punch: punch, requiredHand: expected.opposite),
                    stance: stance
                )

                XCTAssertFalse(
                    validator.isValidConfiguration,
                    "\(punch) must reject \(expected.opposite) in \(stance)"
                )
                XCTAssertEqual(
                    validator.observe(
                        frame(
                            left: expected.opposite == .left ? guardPosition : nil,
                            right: expected.opposite == .right ? guardPosition : nil,
                            timestamp: 1.00
                        )
                    ),
                    .invalid(.invalidConfiguration)
                )
            }
        }
    }

    func testWrongHandAndOpenRetractionRemainTypedInvalidEvidence() {
        var wrongHand = makeValidator(
            target: makeTarget(punch: .jab, requiredHand: .left),
            stance: .orthodox
        )
        _ = wrongHand.observe(frame(left: guardPosition, right: guardPosition, timestamp: 1.00))
        XCTAssertEqual(
            wrongHand.observe(
                frame(left: guardPosition, right: SIMD3(0, 0, 0.75), timestamp: 1.05)
            ),
            .invalid(.wrongHand(expected: .left, actual: .right))
        )

        var opening = makeValidator(
            target: makeTarget(punch: .jab, requiredHand: .left),
            stance: .orthodox
        )
        _ = opening.observe(frame(left: guardPosition, timestamp: 1.00))
        _ = opening.observe(frame(left: SIMD3(0, 0, 0.75), timestamp: 1.05))
        XCTAssertEqual(
            opening.observe(
                frame(left: SIMD3(0, 0, 0.30), leftState: .open, timestamp: 1.10)
            ),
            .invalid(.fistNotClosed(side: .left, state: .open))
        )
    }

    func testRetractionGeometryFailsClosed() {
        XCTAssertTrue(
            CombinationPunchValidator.isRetracted(
                fist: SIMD3<Float>(CombinationPunchValidator.guardRadius, 0, 0),
                guardPosition: guardPosition,
                radius: CombinationPunchValidator.guardRadius
            )
        )
        XCTAssertFalse(
            CombinationPunchValidator.isRetracted(
                fist: SIMD3<Float>(.nan, 0, 0),
                guardPosition: guardPosition,
                radius: CombinationPunchValidator.guardRadius
            )
        )
    }

    private func makeTarget(
        punch: PunchType,
        requiredHand: BodySide
    ) -> CombinationTarget {
        CombinationTarget(
            id: "test-\(punch.rawValue)",
            index: 0,
            punch: punch,
            requiredHand: requiredHand,
            position: targetPosition
        )
    }

    private func makeValidator(
        target: CombinationTarget,
        stance: Stance
    ) -> CombinationPunchValidator {
        CombinationPunchValidator(
            target: target,
            stance: stance,
            guardPosition: guardPosition,
            hitRadius: hitRadius,
            generation: 4,
            continuityEpoch: 9
        )
    }

    private func frame(
        left: SIMD3<Float>? = nil,
        right: SIMD3<Float>? = nil,
        leftState: TrackedFistState = .closed,
        rightState: TrackedFistState = .closed,
        timestamp: TimeInterval
    ) -> PunchEvidenceValidator.Frame {
        var samples: [PunchEvidenceValidator.HandSample] = []
        if let left {
            samples.append(.init(
                side: .left,
                fistPosition: left,
                fistState: leftState,
                acquisitionTimestamp: timestamp,
                quality: .measured
            ))
        }
        if let right {
            samples.append(.init(
                side: .right,
                fistPosition: right,
                fistState: rightState,
                acquisitionTimestamp: timestamp,
                quality: .measured
            ))
        }
        return PunchEvidenceValidator.Frame(
            now: timestamp,
            deviceTimestamp: timestamp,
            generation: 4,
            continuityEpoch: 9,
            hands: samples
        )
    }
}
