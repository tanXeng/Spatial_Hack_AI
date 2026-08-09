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

    func testNormalCombinationTrackingInterruptionsPauseAndRetryWithoutScoring() {
        let interruptedInputs: [CombinationTrackingInterruptionPolicy.Input] = [
            .init(
                requiredHandAvailable: false,
                otherHandAvailable: true,
                devicePoseAvailable: true,
                expectedGeneration: 4,
                currentGeneration: 4,
                expectedContinuityEpoch: 9,
                currentContinuityEpoch: 9
            ),
            .init(
                requiredHandAvailable: true,
                otherHandAvailable: false,
                devicePoseAvailable: true,
                expectedGeneration: 4,
                currentGeneration: 4,
                expectedContinuityEpoch: 9,
                currentContinuityEpoch: 9
            ),
            .init(
                requiredHandAvailable: true,
                otherHandAvailable: true,
                devicePoseAvailable: false,
                expectedGeneration: 4,
                currentGeneration: 4,
                expectedContinuityEpoch: 9,
                currentContinuityEpoch: 9
            ),
            .init(
                requiredHandAvailable: true,
                otherHandAvailable: true,
                devicePoseAvailable: true,
                expectedGeneration: 4,
                currentGeneration: 5,
                expectedContinuityEpoch: 9,
                currentContinuityEpoch: 9
            ),
            .init(
                requiredHandAvailable: true,
                otherHandAvailable: true,
                devicePoseAvailable: true,
                expectedGeneration: 4,
                currentGeneration: 4,
                expectedContinuityEpoch: 9,
                currentContinuityEpoch: 10
            )
        ]

        for input in interruptedInputs {
            let decision = CombinationTrackingInterruptionPolicy.decision(
                input: input,
                capturesCompetitionEvidence: false
            )
            XCTAssertEqual(decision, .discardAndRetry)
            XCTAssertTrue(decision.pausesForFreshGuard)
            XCTAssertFalse(decision.recordsMetric)
            XCTAssertFalse(decision.flashesTarget)
            XCTAssertFalse(decision.advancesStep)
        }
    }

    func testCompetitionTrackingInterruptionRetainsRecoveryUIPath() {
        let input = CombinationTrackingInterruptionPolicy.Input(
            requiredHandAvailable: false,
            otherHandAvailable: true,
            devicePoseAvailable: true,
            expectedGeneration: 4,
            currentGeneration: 4,
            expectedContinuityEpoch: 9,
            currentContinuityEpoch: 9
        )

        XCTAssertEqual(
            CombinationTrackingInterruptionPolicy.decision(
                input: input,
                capturesCompetitionEvidence: true
            ),
            .competitionRecovery
        )
    }

    func testNormalCombinationRecoveryReleasesOnExactlyTheThirdFreshGuardPair() {
        XCTAssertEqual(NormalCombinationGuardRecoveryGate.requiredStableSamples, 3)
        XCTAssertEqual(CompetitionTrackingRecoveryGate.requiredStableSamples, 4)

        var gate = NormalCombinationGuardRecoveryGate()
        XCTAssertFalse(gate.observe(sample(timestamp: 1.00)))
        XCTAssertFalse(gate.observe(sample(timestamp: 1.01)))
        XCTAssertTrue(gate.observe(sample(timestamp: 1.02)))
    }

    func testNormalCombinationRecoveryResetsOnOpenMissingAndStalePairs() {
        for reset in [
            sample(timestamp: 1.02, freshClosedAndGuarded: false),
            sample(timestamp: nil),
            sample(timestamp: .nan),
            sample(timestamp: 1.02, observationsFresh: false)
        ] {
            var gate = NormalCombinationGuardRecoveryGate()
            XCTAssertFalse(gate.observe(sample(timestamp: 1.00)))
            XCTAssertFalse(gate.observe(sample(timestamp: 1.01)))
            XCTAssertFalse(gate.observe(reset))
            XCTAssertFalse(gate.observe(sample(timestamp: 1.03)))
            XCTAssertFalse(gate.observe(sample(timestamp: 1.04)))
            XCTAssertTrue(gate.observe(sample(timestamp: 1.05)))
        }
    }

    func testNormalCombinationRecoveryResetsAcrossGenerationAndEpochChanges() {
        for changedIdentity in [
            (generation: UInt64(5), epoch: UInt64(9)),
            (generation: UInt64(4), epoch: UInt64(10))
        ] {
            var gate = NormalCombinationGuardRecoveryGate()
            XCTAssertFalse(gate.observe(sample(timestamp: 1.00)))
            XCTAssertFalse(gate.observe(sample(timestamp: 1.01)))
            XCTAssertFalse(
                gate.observe(
                    sample(
                        timestamp: 1.02,
                        generation: changedIdentity.generation,
                        continuityEpoch: changedIdentity.epoch
                    )
                )
            )
            XCTAssertFalse(
                gate.observe(
                    sample(
                        timestamp: 1.03,
                        generation: changedIdentity.generation,
                        continuityEpoch: changedIdentity.epoch
                    )
                )
            )
            XCTAssertTrue(
                gate.observe(
                    sample(
                        timestamp: 1.04,
                        generation: changedIdentity.generation,
                        continuityEpoch: changedIdentity.epoch
                    )
                )
            )
        }
    }

    func testNormalCombinationRecoveryResetsWhenGuardIsLostAtAnEqualTimestamp() {
        var gate = NormalCombinationGuardRecoveryGate()
        XCTAssertFalse(gate.observe(sample(timestamp: 1.00)))
        XCTAssertFalse(gate.observe(sample(timestamp: 1.01)))

        // This represents either fist opening or leaving its calibrated guard radius while the
        // bilateral pair identity has not advanced.
        XCTAssertFalse(
            gate.observe(sample(timestamp: 1.01, freshClosedAndGuarded: false))
        )

        XCTAssertFalse(gate.observe(sample(timestamp: 1.02)))
        XCTAssertFalse(gate.observe(sample(timestamp: 1.03)))
        XCTAssertTrue(gate.observe(sample(timestamp: 1.04)))
    }

    func testNormalCombinationRecoveryResetsOnBackwardPairTimestamp() {
        var gate = NormalCombinationGuardRecoveryGate()
        XCTAssertFalse(gate.observe(sample(timestamp: 1.00)))
        XCTAssertFalse(gate.observe(sample(timestamp: 1.01)))
        XCTAssertFalse(gate.observe(sample(timestamp: 0.99)))

        XCTAssertFalse(gate.observe(sample(timestamp: 1.02)))
        XCTAssertFalse(gate.observe(sample(timestamp: 1.03)))
        XCTAssertTrue(gate.observe(sample(timestamp: 1.04)))
    }

    func testNormalCombinationRecoveryDoesNotCountExactClosedDuplicates() {
        var gate = NormalCombinationGuardRecoveryGate()
        XCTAssertFalse(gate.observe(sample(timestamp: 1.00)))
        XCTAssertFalse(gate.observe(sample(timestamp: 1.00)))
        XCTAssertFalse(gate.observe(sample(timestamp: 1.01)))
        XCTAssertFalse(gate.observe(sample(timestamp: 1.01)))
        XCTAssertTrue(gate.observe(sample(timestamp: 1.02)))
    }

    func testNormalCombinationRecoveryDoesNotHideAsyncGuardLossBehindEqualMinimumTimestamp() {
        var gate = NormalCombinationGuardRecoveryGate()
        XCTAssertFalse(gate.observe(sample(leftTimestamp: 1.00, rightTimestamp: 1.00)))
        XCTAssertFalse(gate.observe(sample(leftTimestamp: 1.01, rightTimestamp: 1.01)))

        XCTAssertFalse(
            gate.observe(
                sample(
                    leftTimestamp: 1.02,
                    rightTimestamp: 1.01,
                    freshClosedAndGuarded: false
                )
            )
        )

        XCTAssertFalse(gate.observe(sample(leftTimestamp: 1.03, rightTimestamp: 1.02)))
        XCTAssertFalse(gate.observe(sample(leftTimestamp: 1.04, rightTimestamp: 1.03)))
        XCTAssertTrue(gate.observe(sample(leftTimestamp: 1.05, rightTimestamp: 1.04)))
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

    private func sample(
        timestamp: TimeInterval?,
        generation: UInt64 = 4,
        continuityEpoch: UInt64 = 9,
        observationsFresh: Bool = true,
        freshClosedAndGuarded: Bool = true
    ) -> NormalCombinationGuardRecoveryGate.Sample {
        NormalCombinationGuardRecoveryGate.Sample(
            providerGeneration: generation,
            continuityEpoch: continuityEpoch,
            pairTimestamp: timestamp,
            observationsFresh: observationsFresh,
            freshClosedAndGuarded: freshClosedAndGuarded
        )
    }

    private func sample(
        leftTimestamp: TimeInterval,
        rightTimestamp: TimeInterval,
        freshClosedAndGuarded: Bool = true
    ) -> NormalCombinationGuardRecoveryGate.Sample {
        sample(
            timestamp: min(leftTimestamp, rightTimestamp),
            freshClosedAndGuarded: freshClosedAndGuarded
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
