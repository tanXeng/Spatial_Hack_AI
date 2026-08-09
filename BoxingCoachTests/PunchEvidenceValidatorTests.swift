import Foundation
import Testing
import simd
@testable import BoxingCoach

@Suite("Validated punch evidence")
struct PunchEvidenceValidatorTests {
    private let guardPosition = SIMD3<Float>(0, 0, 0)
    private let targetPosition = SIMD3<Float>(0, 0, 0.60)
    private let targetRadius: Float = 0.05

    @Test(
        "A Jab validates with the stance's physical lead hand",
        arguments: [
            (Stance.orthodox, BodySide.left),
            (Stance.southpaw, BodySide.right)
        ]
    )
    func jabUsesTheStanceLeadHand(stance: Stance, expectedSide: BodySide) throws {
        var validator = makeValidator(technique: .jab, stance: stance)

        let evidence = try completeFastPunch(
            validator: &validator,
            side: expectedSide,
            target: targetPosition
        )

        #expect(evidence.technique == .jab)
        #expect(evidence.stance == stance)
        #expect(evidence.side == expectedSide)
        #expect(evidence.generation == 7)
        #expect(abs(evidence.outboundTravel - 0.75) < 0.000_001)
        #expect(evidence.landingError < 0.000_001)
        #expect(evidence.trackedFraction == 0.95)
    }

    @Test(
        "An Orthodox and Southpaw one-two validate Jab then Cross with literal physical hands",
        arguments: [
            (Stance.orthodox, BodySide.left, BodySide.right),
            (Stance.southpaw, BodySide.right, BodySide.left)
        ]
    )
    func oneTwoUsesLiteralRequiredHands(
        stance: Stance,
        jabSide: BodySide,
        crossSide: BodySide
    ) throws {
        var jab = makeValidator(technique: .jab, stance: stance)
        let jabEvidence = try completeFastPunch(
            validator: &jab,
            side: jabSide,
            target: targetPosition
        )

        var cross = makeValidator(
            technique: .cross,
            stance: stance,
            target: SIMD3<Float>(0, 0, 0.65)
        )
        let crossEvidence = try completeFastPunch(
            validator: &cross,
            side: crossSide,
            target: SIMD3<Float>(0, 0, 0.65)
        )

        #expect(jabEvidence.side == jabSide)
        #expect(jabEvidence.technique == .jab)
        #expect(crossEvidence.side == crossSide)
        #expect(crossEvidence.technique == .cross)
    }

    @Test("A fixed-hand technique rejects an explicit side that contradicts stance")
    func explicitSideCannotOverrideTechniqueHand() {
        var validator = PunchEvidenceValidator(
            configuration: PunchEvidenceValidator.Configuration(
                technique: .jab,
                stance: .orthodox,
                requiredHand: .right,
                guardPosition: guardPosition,
                targetPosition: targetPosition,
                targetRadius: targetRadius,
                generation: 7,
                continuityEpoch: 11
            )
        )

        #expect(
            validator.observe(
                frame(side: .right, position: guardPosition, timestamp: 1.00)
            ) == .invalid(.invalidConfiguration)
        )
        #expect(validator.phase == .waitingForGuard)
    }

    @Test("Swept contact detects a target crossing between two outside samples")
    func sweptContactBetweenSamples() {
        var validator = makeValidator()

        #expect(
            validator.observe(frame(side: .left, position: guardPosition, timestamp: 1.00))
                == .waiting(.trackingOutbound)
        )
        #expect(
            validator.observe(
                frame(side: .left, position: SIMD3<Float>(0, 0, 0.45), timestamp: 1.10)
            ) == .armed
        )
        #expect(
            validator.observe(
                frame(side: .left, position: SIMD3<Float>(0, 0, 0.75), timestamp: 1.15)
            ) == .contact
        )
        #expect(validator.phase == .trackingRetraction)
    }

    @Test("A fast fist can cross the target without any point sample inside it")
    func fastThroughTargetUsesTheWholeSegment() {
        var validator = makeValidator()

        _ = validator.observe(frame(side: .left, position: guardPosition, timestamp: 1.00))
        let event = validator.observe(
            frame(side: .left, position: SIMD3<Float>(0, 0, 0.75), timestamp: 1.05)
        )

        #expect(event == .contact)
        #expect(validator.phase == .trackingRetraction)
    }

    @Test("Outbound travel starts at the freshly acquired guard sample")
    func travelIsMeasuredFromFreshGuardInsteadOfNominalGuardCenter() {
        var validator = makeValidator()
        let acquiredGuard = SIMD3<Float>(0, 0, 0.13)

        #expect(
            validator.observe(frame(side: .left, position: acquiredGuard, timestamp: 1.00))
                == .waiting(.trackingOutbound)
        )
        #expect(
            validator.observe(
                frame(side: .left, position: SIMD3<Float>(0, 0, 0.20), timestamp: 1.05)
            ) == .waiting(.trackingOutbound)
        )

        guard case let .invalid(.insufficientOutboundTravel(actual, minimum)) = validator.finish()
        else {
            Issue.record("Expected travel to be measured from the acquired 0.13 m guard")
            return
        }
        #expect(abs(actual - 0.07) < 0.000_01)
        #expect(minimum == 0.10)
    }

    @Test("A swept segment must have ten centimeters of travel before sphere entry")
    func endpointCannotArmAfterEarlierUnqualifiedContact() {
        var validator = PunchEvidenceValidator(
            configuration: .init(
                technique: .jab,
                stance: .orthodox,
                guardPosition: guardPosition,
                targetPosition: SIMD3<Float>(0, 0, 0.16),
                targetRadius: 0.07,
                generation: 7,
                continuityEpoch: 11
            )
        )

        _ = validator.observe(frame(side: .left, position: guardPosition, timestamp: 1.00))
        let event = validator.observe(
            frame(side: .left, position: SIMD3<Float>(0, 0, 0.30), timestamp: 1.05)
        )

        guard case let .invalid(.insufficientOutboundTravel(actual, minimum)) = event else {
            Issue.record("Expected the 0.09 m sphere-entry point to fail before endpoint arming")
            return
        }
        #expect(abs(actual - 0.09) < 0.000_01)
        #expect(minimum == 0.10)
        #expect(validator.phase == .waitingForGuard)
    }

    @Test("Target contact before leaving the calibrated guard sphere is rejected")
    func contactCannotReplaceGuardDeparture() {
        var validator = PunchEvidenceValidator(
            configuration: .init(
                technique: .jab,
                stance: .orthodox,
                guardPosition: guardPosition,
                targetPosition: SIMD3<Float>(0, 0, 0.25),
                targetRadius: 0.12,
                generation: 7,
                continuityEpoch: 11
            )
        )

        _ = validator.observe(frame(side: .left, position: guardPosition, timestamp: 1.00))
        #expect(
            validator.observe(
                frame(side: .left, position: SIMD3<Float>(0, 0, 0.40), timestamp: 1.05)
            ) == .invalid(.missingGuardDeparture)
        )
    }

    @Test("The opposite physical hand cannot satisfy a required-hand target")
    func wrongHandIsTypedInvalidEvidence() {
        var validator = makeValidator()

        _ = validator.observe(
            frame(
                left: guardPosition,
                right: guardPosition,
                timestamp: 1.00
            )
        )
        let event = validator.observe(
            frame(
                left: SIMD3<Float>(0, 0, 0.02),
                right: SIMD3<Float>(0, 0, 0.75),
                timestamp: 1.05
            )
        )

        #expect(event == .invalid(.wrongHand(expected: .left, actual: .right)))
        #expect(validator.phase == .waitingForGuard)
    }

    @Test("Opposite-hand-only callbacks remain visible to wrong-hand validation")
    func perHandCursorAdmitsAsynchronousWrongHandEvidence() {
        var cursor = PunchEvidenceFrameCursor()
        var validator = makeValidator()
        let guardFrame = asynchronousFrame(
            left: guardPosition,
            leftTimestamp: 1.000,
            right: guardPosition,
            rightTimestamp: 1.000
        )
        let wrongHandOutbound = asynchronousFrame(
            left: guardPosition,
            leftTimestamp: 1.000,
            right: SIMD3<Float>(0, 0, 0.20),
            rightTimestamp: 1.015
        )
        let wrongHandContact = asynchronousFrame(
            left: guardPosition,
            leftTimestamp: 1.000,
            right: SIMD3<Float>(0, 0, 0.75),
            rightTimestamp: 1.025
        )

        let seesGuard = cursor.shouldObserve(guardFrame)
        #expect(seesGuard)
        _ = validator.observe(guardFrame)
        let seesWrongHandOutbound = cursor.shouldObserve(wrongHandOutbound)
        #expect(seesWrongHandOutbound)
        #expect(
            validator.observe(wrongHandOutbound) == .waiting(.trackingOutbound)
        )
        let seesWrongHandContact = cursor.shouldObserve(wrongHandContact)
        #expect(seesWrongHandContact)
        #expect(
            validator.observe(wrongHandContact)
                == .invalid(.wrongHand(expected: .left, actual: .right))
        )
        let seesExactDuplicate = cursor.shouldObserve(wrongHandContact)
        #expect(seesExactDuplicate == false)
    }

    @Test(
        "A required hand must be definitely closed",
        arguments: [TrackedFistState.open, .uncertain]
    )
    func nonClosedHandIsTypedInvalidEvidence(fistState: TrackedFistState) {
        var validator = makeValidator()

        _ = validator.observe(frame(side: .left, position: guardPosition, timestamp: 1.00))
        let event = validator.observe(
            frame(
                side: .left,
                position: SIMD3<Float>(0, 0, 0.75),
                fistState: fistState,
                timestamp: 1.05
            )
        )

        #expect(event == .invalid(.fistNotClosed(side: .left, state: fistState)))
        #expect(validator.phase == .waitingForGuard)
    }

    @Test("A fist opening after contact invalidates the whole evidence chain")
    func handOpeningDuringRetractionIsTypedInvalidEvidence() {
        var validator = makeValidator()

        _ = validator.observe(frame(side: .left, position: guardPosition, timestamp: 1.00))
        #expect(
            validator.observe(
                frame(side: .left, position: SIMD3<Float>(0, 0, 0.75), timestamp: 1.05)
            ) == .contact
        )
        let event = validator.observe(
            frame(
                side: .left,
                position: SIMD3<Float>(0, 0, 0.30),
                fistState: .open,
                timestamp: 1.10
            )
        )

        #expect(event == .invalid(.fistNotClosed(side: .left, state: .open)))
        #expect(validator.phase == .waitingForGuard)
    }

    @Test("A stationary fist already inside the target cannot arm or contact")
    func stationaryInsideTargetIsTypedInvalidEvidence() {
        var validator = makeValidator()

        let event = validator.observe(
            frame(side: .left, position: targetPosition, timestamp: 1.00)
        )

        #expect(event == .invalid(.stationaryInsideTarget(side: .left)))
        #expect(validator.phase == .waitingForGuard)
    }

    @Test("A rejected frame cannot seed swept-contact history for the next attempt")
    func invalidFrameLeavesNoPriorHandHistory() {
        var validator = makeValidator()

        #expect(
            validator.observe(
                frame(
                    left: targetPosition,
                    right: guardPosition,
                    timestamp: 1.00
                )
            ) == .invalid(.stationaryInsideTarget(side: .left))
        )

        // The right fist is outside the sphere at both admitted endpoints. This is a wrong-hand
        // crossing only if the rejected frame's right-at-guard position leaked into the reset.
        #expect(
            validator.observe(
                frame(
                    left: guardPosition,
                    right: SIMD3<Float>(0, 0, 0.75),
                    timestamp: 1.05
                )
            ) == .waiting(.trackingOutbound)
        )
    }

    @Test("A sample older than 100 milliseconds resets the punch")
    func staleSampleIsTypedInvalidEvidence() {
        var validator = makeValidator()

        let event = validator.observe(
            frame(
                side: .left,
                position: guardPosition,
                timestamp: 1.00,
                now: 1.101
            )
        )

        guard case let .invalid(.staleSample(side, age, maximumAge)) = event else {
            Issue.record("Expected stale-sample invalid evidence, got \(event)")
            return
        }
        #expect(side == .left)
        #expect(abs(age - 0.101) < 0.000_001)
        #expect(maximumAge == 0.100)
    }

    @Test("Hand and device timestamps over 33 milliseconds apart reset the punch")
    func overSkewedSampleIsTypedInvalidEvidence() {
        var validator = makeValidator()

        let event = validator.observe(
            frame(
                side: .left,
                position: guardPosition,
                timestamp: 1.00,
                deviceTimestamp: 1.034,
                now: 1.034
            )
        )

        guard case let .invalid(.overSkewed(side, skew, maximumSkew)) = event else {
            Issue.record("Expected over-skew invalid evidence, got \(event)")
            return
        }
        #expect(side == .left)
        #expect(abs(skew - 0.034) < 0.000_001)
        #expect(maximumSkew == 0.033)
    }

    @Test("Nonfinite fist coordinates reset the punch")
    func nonFinitePositionIsTypedInvalidEvidence() {
        var validator = makeValidator()

        let event = validator.observe(
            frame(
                side: .left,
                position: SIMD3<Float>(.nan, 0, 0),
                timestamp: 1.00
            )
        )

        #expect(event == .invalid(.nonFinite(field: "fistPosition.left")))
    }

    @Test("A gap greater than 200 milliseconds discards partial outbound state")
    func sampleGapIsTypedInvalidEvidence() {
        var validator = makeValidator()

        _ = validator.observe(frame(side: .left, position: guardPosition, timestamp: 1.00))
        let event = validator.observe(
            frame(
                side: .left,
                position: SIMD3<Float>(0, 0, 0.05),
                timestamp: 1.201
            )
        )

        guard case let .invalid(.sampleGap(duration, maximumGap)) = event else {
            Issue.record("Expected sample-gap invalid evidence, got \(event)")
            return
        }
        #expect(abs(duration - 0.201) < 0.000_001)
        #expect(maximumGap == 0.200)
        #expect(validator.phase == .waitingForGuard)
    }

    @Test("Two independently timestamped hands share only a 33 ms coherent snapshot")
    func twoHandFrameUsesOneBoundedDeviceTimestamp() {
        var inclusive = makeValidator()
        let inclusiveFrame = PunchEvidenceValidator.Frame(
            now: 1.033,
            deviceTimestamp: 1.033,
            generation: 7,
            continuityEpoch: 11,
            hands: [
                .init(
                    side: .left,
                    fistPosition: guardPosition,
                    fistState: .closed,
                    acquisitionTimestamp: 1.000,
                    quality: .measured
                ),
                .init(
                    side: .right,
                    fistPosition: guardPosition,
                    fistState: .closed,
                    acquisitionTimestamp: 1.033,
                    quality: .measured
                )
            ]
        )
        #expect(inclusive.observe(inclusiveFrame) == .waiting(.trackingOutbound))

        var rejected = makeValidator()
        let rejectedFrame = PunchEvidenceValidator.Frame(
            now: 1.034,
            deviceTimestamp: 1.034,
            generation: 7,
            continuityEpoch: 11,
            hands: [
                .init(
                    side: .left,
                    fistPosition: guardPosition,
                    fistState: .closed,
                    acquisitionTimestamp: 1.000,
                    quality: .measured
                ),
                .init(
                    side: .right,
                    fistPosition: guardPosition,
                    fistState: .closed,
                    acquisitionTimestamp: 1.034,
                    quality: .measured
                )
            ]
        )
        guard case let .invalid(.overSkewed(side, skew, maximum)) = rejected.observe(
            rejectedFrame
        ) else {
            Issue.record("Expected the older hand to fail the shared device-time coherence gate")
            return
        }
        #expect(side == .left)
        #expect(abs(skew - 0.034) < 0.000_001)
        #expect(maximum == 0.033)
    }

    @Test("An unchanged required-hand sample does not reset when the other anchor advances")
    func duplicateRequiredTimestampIsANoOp() {
        var validator = makeValidator()

        _ = validator.observe(
            frame(left: guardPosition, right: guardPosition, timestamp: 1.00)
        )
        let otherAnchorOnly = PunchEvidenceValidator.Frame(
            now: 1.01,
            deviceTimestamp: 1.00,
            generation: 7,
            continuityEpoch: 11,
            hands: [
                .init(
                    side: .left,
                    fistPosition: guardPosition,
                    fistState: .closed,
                    acquisitionTimestamp: 1.00,
                    quality: .measured
                ),
                .init(
                    side: .right,
                    fistPosition: guardPosition,
                    fistState: .closed,
                    acquisitionTimestamp: 1.01,
                    quality: .measured
                )
            ]
        )

        #expect(validator.observe(otherAnchorOnly) == .waiting(.trackingOutbound))
        #expect(
            validator.observe(
                frame(side: .left, position: SIMD3<Float>(0, 0, 0.75), timestamp: 1.05)
            ) == .contact
        )
    }

    @Test("A new provider generation cannot finish an older partial punch")
    func generationChangeIsTypedInvalidEvidence() {
        var validator = makeValidator()

        _ = validator.observe(frame(side: .left, position: guardPosition, timestamp: 1.00))
        let event = validator.observe(
            frame(
                side: .left,
                position: SIMD3<Float>(0, 0, 0.75),
                timestamp: 1.05,
                generation: 8
            )
        )

        #expect(event == .invalid(.generationMismatch(expected: 7, actual: 8)))
        #expect(validator.phase == .waitingForGuard)
    }

    @Test("A continuity epoch change cannot finish an older partial punch")
    func continuityEpochChangeIsTypedInvalidEvidence() {
        var validator = makeValidator()

        _ = validator.observe(frame(side: .left, position: guardPosition, timestamp: 1.00))
        let event = validator.observe(
            frame(
                side: .left,
                position: SIMD3<Float>(0, 0, 0.75),
                timestamp: 1.05,
                continuityEpoch: 12
            )
        )

        #expect(event == .invalid(.continuityEpochMismatch(expected: 11, actual: 12)))
        #expect(validator.phase == .waitingForGuard)
    }

    @Test("Less than ten centimeters of outbound travel cannot finish")
    func insufficientOutboundTravelIsTypedInvalidEvidence() {
        var validator = makeValidator()

        _ = validator.observe(frame(side: .left, position: guardPosition, timestamp: 1.00))
        _ = validator.observe(
            frame(side: .left, position: SIMD3<Float>(0, 0, 0.09), timestamp: 1.10)
        )

        guard case let .invalid(.insufficientOutboundTravel(actual, minimum)) = validator.finish()
        else {
            Issue.record("Expected insufficient-travel invalid evidence")
            return
        }
        #expect(abs(actual - 0.09) < 0.000_001)
        #expect(minimum == 0.10)
    }

    @Test("Outbound motion below 0.20 meters per second cannot finish")
    func insufficientOutwardVelocityIsTypedInvalidEvidence() {
        var validator = makeValidator()

        _ = validator.observe(frame(side: .left, position: guardPosition, timestamp: 1.00))
        _ = validator.observe(
            frame(side: .left, position: SIMD3<Float>(0, 0, 0.03), timestamp: 1.19)
        )
        _ = validator.observe(
            frame(side: .left, position: SIMD3<Float>(0, 0, 0.06), timestamp: 1.38)
        )
        _ = validator.observe(
            frame(side: .left, position: SIMD3<Float>(0, 0, 0.09), timestamp: 1.57)
        )
        _ = validator.observe(
            frame(side: .left, position: SIMD3<Float>(0, 0, 0.12), timestamp: 1.76)
        )

        guard case let .invalid(.insufficientOutwardVelocity(actual, minimum)) = validator.finish()
        else {
            Issue.record("Expected insufficient-velocity invalid evidence")
            return
        }
        #expect(abs(actual - (0.03 / 0.19)) < 0.000_01)
        #expect(minimum == 0.20)
    }

    @Test("Contact without a return toward calibrated guard is invalid")
    func missingRetractionIsTypedInvalidEvidence() {
        var validator = makeValidator()

        _ = validator.observe(frame(side: .left, position: guardPosition, timestamp: 1.00))
        #expect(
            validator.observe(
                frame(side: .left, position: SIMD3<Float>(0, 0, 0.75), timestamp: 1.05)
            ) == .contact
        )

        #expect(validator.finish() == .invalid(.missingRetraction))
        #expect(validator.phase == .waitingForGuard)
    }

    @Test("Tracking coverage below 45 percent cannot create accepted punch evidence")
    func insufficientCoverageIsTypedInvalidEvidence() throws {
        var validator = makeValidator()
        try driveToCoverage(validator: &validator, side: .left, target: targetPosition)

        let event = validator.complete(
            coverage: PunchEvidenceValidator.Coverage(
                trackedFraction: 0.44,
                generation: 7,
                continuityEpoch: 11
            )
        )

        #expect(
            event == .invalid(
                .insufficientTrackingCoverage(actual: 0.44, minimum: 0.45)
            )
        )
        #expect(validator.phase == .waitingForGuard)
    }

    @Test("Coverage from another tracking chain cannot validate a retracted punch")
    func staleCoverageChainIsTypedInvalidEvidence() throws {
        var generationValidator = makeValidator()
        try driveToCoverage(
            validator: &generationValidator,
            side: .left,
            target: targetPosition
        )
        #expect(
            generationValidator.complete(
                coverage: PunchEvidenceValidator.Coverage(
                    trackedFraction: 0.95,
                    generation: 8,
                    continuityEpoch: 11
                )
            ) == .invalid(.generationMismatch(expected: 7, actual: 8))
        )

        var epochValidator = makeValidator()
        try driveToCoverage(validator: &epochValidator, side: .left, target: targetPosition)
        #expect(
            epochValidator.complete(
                coverage: PunchEvidenceValidator.Coverage(
                    trackedFraction: 0.95,
                    generation: 7,
                    continuityEpoch: 12
                )
            ) == .invalid(.continuityEpochMismatch(expected: 11, actual: 12))
        )
    }

    @Test("Session coverage can only be stamped by the chain that began capture")
    func captureChainRejectsCoverageAfterGenerationOrEpochChange() {
        let chain = PunchEvidenceCaptureChain(generation: 7, continuityEpoch: 11)

        #expect(
            chain.coverage(
                trackedFraction: 0.95,
                currentGeneration: 7,
                currentContinuityEpoch: 11
            )?.generation == 7
        )
        #expect(
            chain.coverage(
                trackedFraction: 0.95,
                currentGeneration: 8,
                currentContinuityEpoch: 11
            ) == nil
        )
        #expect(
            chain.coverage(
                trackedFraction: 0.95,
                currentGeneration: 7,
                currentContinuityEpoch: 12
            ) == nil
        )
    }

    @Test(
        "A reactive target locks the first valid outbound physical side",
        arguments: [BodySide.left, .right]
    )
    func reactiveTargetLocksOutboundSideInsteadOfNearestSide(selectedSide: BodySide) {
        var selector = PunchEvidenceSideSelector(
            technique: .hook,
            stance: .orthodox,
            guardPositions: [.left: guardPosition, .right: guardPosition],
            targetPosition: targetPosition,
            targetRadius: targetRadius,
            generation: 7,
            continuityEpoch: 11
        )

        #expect(
            selector.observe(
                frame(left: guardPosition, right: guardPosition, timestamp: 1.00)
            ) == .waiting
        )
        let movingPosition = SIMD3<Float>(0, 0, 0.20)
        #expect(
            selector.observe(
                frame(
                    left: selectedSide == .left ? movingPosition : guardPosition,
                    right: selectedSide == .right ? movingPosition : guardPosition,
                    timestamp: 1.05
                )
            ) == .selected(side: selectedSide, event: .armed)
        )
        #expect(selector.requiredHand == selectedSide)
    }

    @Test("After reactive side selection the opposite hand remains typed wrong-hand evidence")
    func reactiveSelectionNeverReselectsTheNearestHand() {
        var selector = PunchEvidenceSideSelector(
            technique: .hook,
            stance: .orthodox,
            guardPositions: [.left: guardPosition, .right: guardPosition],
            targetPosition: targetPosition,
            targetRadius: targetRadius,
            generation: 7,
            continuityEpoch: 11
        )

        _ = selector.observe(frame(left: guardPosition, right: guardPosition, timestamp: 1.00))
        _ = selector.observe(
            frame(
                left: SIMD3<Float>(0, 0, 0.20),
                right: guardPosition,
                timestamp: 1.05
            )
        )

        #expect(
            selector.observe(
                frame(
                    left: SIMD3<Float>(0, 0, 0.25),
                    right: SIMD3<Float>(0, 0, 0.75),
                    timestamp: 1.10
                )
            ) == .selected(
                side: .left,
                event: .invalid(.wrongHand(expected: .left, actual: .right))
            )
        )
        #expect(selector.requiredHand == .left)
    }

    @Test("A typed invalid before side lock is returned to the session for retry")
    func reactiveSelectionDoesNotErasePreselectionInvalidEvidence() {
        var selector = PunchEvidenceSideSelector(
            technique: .hook,
            stance: .orthodox,
            guardPositions: [.left: guardPosition, .right: guardPosition],
            targetPosition: targetPosition,
            targetRadius: targetRadius,
            generation: 7,
            continuityEpoch: 11
        )

        _ = selector.observe(frame(left: guardPosition, right: guardPosition, timestamp: 1.00))
        let event = selector.observe(
            frame(
                left: SIMD3<Float>(0, 0, 0.75),
                right: guardPosition,
                leftState: .uncertain,
                timestamp: 1.05
            )
        )

        #expect(event == .invalid(.fistNotClosed(side: .left, state: .uncertain)))
        #expect(selector.requiredHand == nil)
    }

    @Test("One invalid speculative side is not hidden by the other side waiting")
    func reactiveSelectionSurfacesOneSidedPreselectionInvalid() {
        var selector = PunchEvidenceSideSelector(
            technique: .hook,
            stance: .orthodox,
            guardPositions: [.left: guardPosition, .right: guardPosition],
            targetPosition: targetPosition,
            targetRadius: targetRadius,
            generation: 7,
            continuityEpoch: 11
        )

        _ = selector.observe(frame(left: guardPosition, right: guardPosition, timestamp: 1.00))
        #expect(
            selector.observe(
                frame(
                    left: SIMD3<Float>(0, 0, 0.20),
                    right: guardPosition,
                    leftState: .open,
                    timestamp: 1.05
                )
            ) == .invalid(.fistNotClosed(side: .left, state: .open))
        )
        #expect(selector.requiredHand == nil)
    }

    @Test("Simultaneous dual-arm outbound motion fails closed instead of choosing left")
    func reactiveSelectionTypesAmbiguousDualArmMotion() {
        var selector = PunchEvidenceSideSelector(
            technique: .hook,
            stance: .orthodox,
            guardPositions: [.left: guardPosition, .right: guardPosition],
            targetPosition: targetPosition,
            targetRadius: targetRadius,
            generation: 7,
            continuityEpoch: 11
        )

        _ = selector.observe(frame(left: guardPosition, right: guardPosition, timestamp: 1.00))
        let event = selector.observe(
            frame(
                left: SIMD3<Float>(-0.01, 0, 0.20),
                right: SIMD3<Float>(0.01, 0, 0.20),
                timestamp: 1.05
            )
        )

        #expect(event == .invalid(.ambiguousHandSelection))
        #expect(selector.requiredHand == nil)
    }

    @Test("Dual-arm outbound motion split across coherent callbacks is ambiguous")
    func reactiveSelectionTypesSplitCallbackAmbiguity() {
        var selector = PunchEvidenceSideSelector(
            technique: .hook,
            stance: .orthodox,
            guardPositions: [.left: guardPosition, .right: guardPosition],
            targetPosition: targetPosition,
            targetRadius: targetRadius,
            generation: 7,
            continuityEpoch: 11
        )

        _ = selector.observe(frame(left: guardPosition, right: guardPosition, timestamp: 1.00))
        let firstCallback = selector.observe(
            asynchronousFrame(
                left: SIMD3<Float>(-0.01, 0, 0.20),
                leftTimestamp: 1.050,
                right: guardPosition,
                rightTimestamp: 1.030
            )
        )
        let secondCallback = selector.observe(
            asynchronousFrame(
                left: SIMD3<Float>(-0.01, 0, 0.20),
                leftTimestamp: 1.050,
                right: SIMD3<Float>(0.01, 0, 0.20),
                rightTimestamp: 1.060
            )
        )

        #expect(firstCallback == .waiting)
        #expect(secondCallback == .invalid(.ambiguousHandSelection))
        #expect(selector.requiredHand == nil)
    }

    @Test("A guarded opposite-hand callback resolves a provisional single-hand selection")
    func reactiveSelectionResolvesAfterOppositeGuardCallback() {
        var selector = PunchEvidenceSideSelector(
            technique: .hook,
            stance: .orthodox,
            guardPositions: [.left: guardPosition, .right: guardPosition],
            targetPosition: targetPosition,
            targetRadius: targetRadius,
            generation: 7,
            continuityEpoch: 11
        )

        _ = selector.observe(frame(left: guardPosition, right: guardPosition, timestamp: 1.00))
        #expect(
            selector.observe(
                asynchronousFrame(
                    left: SIMD3<Float>(-0.01, 0, 0.20),
                    leftTimestamp: 1.050,
                    right: guardPosition,
                    rightTimestamp: 1.030
                )
            ) == .waiting
        )
        #expect(
            selector.observe(
                asynchronousFrame(
                    left: SIMD3<Float>(-0.01, 0, 0.20),
                    leftTimestamp: 1.050,
                    right: guardPosition,
                    rightTimestamp: 1.060
                )
            ) == .selected(side: .left, event: .armed)
        )
        #expect(selector.requiredHand == .left)
    }

    @Test("Invalid punch actions retry and cannot be deferred, scored, or ranked")
    func invalidAttemptPolicyNeverAdmitsSatisfyingFeedbackOrMetrics() throws {
        let reason = PunchEvidenceValidator.InvalidReason.missingRetraction
        let action = PunchEvidenceAttemptAction(
            event: .invalid(reason)
        )

        #expect(action == .retry(reason))
        #expect(action.canBeDeferredByGuard == false)
        #expect(action.recordsMetric == false)
        #expect(action.isRankable == false)
        #expect(action.advancesScoredSlot == false)
        #expect(
            PunchEvidenceAttemptAction(event: .contact)
                .canBeDeferredByGuard == false
        )
        #expect(
            PunchEvidenceAttemptAction(event: .readyForCoverage)
                .canBeDeferredByGuard == false
        )

        var validator = makeValidator()
        let evidence = try completeFastPunch(
            validator: &validator,
            side: .left,
            target: targetPosition
        )
        let admitted = PunchEvidenceAttemptAction(event: .validated(evidence))
        #expect(admitted.recordsMetric)
        #expect(admitted.isRankable)
        #expect(admitted.advancesScoredSlot)
    }

    @Test("Typed wrong-hand evidence renders the required physical side in visible feedback")
    func typedWrongHandFeedbackNamesTheRequiredSide() {
        #expect(
            PunchEvidenceFeedback.message(
                for: .wrongHand(expected: .right, actual: .left)
            ) == "Wrong hand · use your right hand"
        )
        #expect(
            PunchEvidenceFeedback.strikeNow(side: .left)
                == "Left hand · strike now"
        )
        #expect(
            PunchEvidenceFeedback.returnToGuard(side: .right, style: .return)
                == "Return your right hand to guard"
        )
        #expect(
            PunchEvidenceFeedback.returnToGuard(side: .left, style: .snap)
                == "Snap your left hand back to guard"
        )
        #expect(
            PunchEvidenceFeedback.message(for: .ambiguousHandSelection)
                == "Use one hand at a time"
        )
    }

    @Test("The hard freshness, skew, and gap ceilings are inclusive")
    func temporalCeilingsAreInclusive() {
        var validator = makeValidator()

        let guardEvent = validator.observe(
            frame(
                side: .left,
                position: guardPosition,
                timestamp: 1.00,
                deviceTimestamp: 1.00,
                now: 1.10
            )
        )
        let contactEvent = validator.observe(
            frame(
                side: .left,
                position: SIMD3<Float>(0, 0, 0.75),
                timestamp: 1.20,
                deviceTimestamp: 1.167,
                now: 1.20
            )
        )

        #expect(guardEvent == .waiting(.trackingOutbound))
        #expect(contactEvent == .contact)
    }

    @Test("The reducer API remains callable as an explicit nonisolated Sendable contract")
    func validatorIsSendableAndNonisolated() async {
        let event = await Task.detached { @Sendable in
            var validator = PunchEvidenceValidator(
                configuration: PunchEvidenceValidator.Configuration(
                    technique: .jab,
                    stance: .orthodox,
                    guardPosition: SIMD3<Float>(0, 0, 0),
                    targetPosition: SIMD3<Float>(0, 0, 0.60),
                    targetRadius: 0.05,
                    generation: 7,
                    continuityEpoch: 11
                )
            )
            return validator.observe(
                PunchEvidenceValidator.Frame(
                    now: 1.0,
                    deviceTimestamp: 1.0,
                    generation: 7,
                    continuityEpoch: 11,
                    hands: [
                        PunchEvidenceValidator.HandSample(
                            side: .left,
                            fistPosition: SIMD3<Float>(0, 0, 0),
                            fistState: .closed,
                            acquisitionTimestamp: 1.0,
                            quality: .measured
                        )
                    ]
                )
            )
        }.value

        #expect(event == .waiting(.trackingOutbound))
    }

    private func makeValidator(
        technique: Technique = .jab,
        stance: Stance = .orthodox,
        target: SIMD3<Float>? = nil
    ) -> PunchEvidenceValidator {
        PunchEvidenceValidator(
            configuration: PunchEvidenceValidator.Configuration(
                technique: technique,
                stance: stance,
                guardPosition: guardPosition,
                targetPosition: target ?? targetPosition,
                targetRadius: targetRadius,
                generation: 7,
                continuityEpoch: 11
            )
        )
    }

    private func frame(
        side: BodySide,
        position: SIMD3<Float>,
        fistState: TrackedFistState = .closed,
        timestamp: TimeInterval,
        deviceTimestamp: TimeInterval? = nil,
        now: TimeInterval? = nil,
        generation: UInt64 = 7,
        continuityEpoch: UInt64 = 11
    ) -> PunchEvidenceValidator.Frame {
        frame(
            left: side == .left ? position : nil,
            right: side == .right ? position : nil,
            leftState: side == .left ? fistState : .closed,
            rightState: side == .right ? fistState : .closed,
            timestamp: timestamp,
            deviceTimestamp: deviceTimestamp,
            now: now,
            generation: generation,
            continuityEpoch: continuityEpoch
        )
    }

    private func frame(
        left: SIMD3<Float>?,
        right: SIMD3<Float>?,
        leftState: TrackedFistState = .closed,
        rightState: TrackedFistState = .closed,
        timestamp: TimeInterval,
        deviceTimestamp: TimeInterval? = nil,
        now: TimeInterval? = nil,
        generation: UInt64 = 7,
        continuityEpoch: UInt64 = 11
    ) -> PunchEvidenceValidator.Frame {
        var hands: [PunchEvidenceValidator.HandSample] = []
        if let left {
            hands.append(
                PunchEvidenceValidator.HandSample(
                    side: .left,
                    fistPosition: left,
                    fistState: leftState,
                    acquisitionTimestamp: timestamp,
                    quality: .measured
                )
            )
        }
        if let right {
            hands.append(
                PunchEvidenceValidator.HandSample(
                    side: .right,
                    fistPosition: right,
                    fistState: rightState,
                    acquisitionTimestamp: timestamp,
                    quality: .measured
                )
            )
        }
        return PunchEvidenceValidator.Frame(
            now: now ?? timestamp,
            deviceTimestamp: deviceTimestamp ?? timestamp,
            generation: generation,
            continuityEpoch: continuityEpoch,
            hands: hands
        )
    }

    private func asynchronousFrame(
        left: SIMD3<Float>,
        leftTimestamp: TimeInterval,
        right: SIMD3<Float>,
        rightTimestamp: TimeInterval
    ) -> PunchEvidenceValidator.Frame {
        let now = max(leftTimestamp, rightTimestamp)
        return PunchEvidenceValidator.Frame(
            now: now,
            deviceTimestamp: now,
            generation: 7,
            continuityEpoch: 11,
            hands: [
                PunchEvidenceValidator.HandSample(
                    side: .left,
                    fistPosition: left,
                    fistState: .closed,
                    acquisitionTimestamp: leftTimestamp,
                    quality: .measured
                ),
                PunchEvidenceValidator.HandSample(
                    side: .right,
                    fistPosition: right,
                    fistState: .closed,
                    acquisitionTimestamp: rightTimestamp,
                    quality: .measured
                )
            ]
        )
    }

    private func driveToCoverage(
        validator: inout PunchEvidenceValidator,
        side: BodySide,
        target: SIMD3<Float>
    ) throws {
        #expect(
            validator.observe(frame(side: side, position: guardPosition, timestamp: 1.00))
                == .waiting(.trackingOutbound)
        )
        #expect(
            validator.observe(
                frame(side: side, position: SIMD3<Float>(0, 0, target.z + 0.15), timestamp: 1.05)
            ) == .contact
        )
        #expect(
            validator.observe(
                frame(side: side, position: SIMD3<Float>(0, 0, 0.30), timestamp: 1.10)
            ) == .waiting(.trackingRetraction)
        )
        #expect(
            validator.observe(
                frame(side: side, position: SIMD3<Float>(0, 0, 0.02), timestamp: 1.15)
            ) == .readyForCoverage
        )
    }

    private func completeFastPunch(
        validator: inout PunchEvidenceValidator,
        side: BodySide,
        target: SIMD3<Float>
    ) throws -> ValidatedPunchEvidence {
        try driveToCoverage(validator: &validator, side: side, target: target)
        let event = validator.complete(
            coverage: PunchEvidenceValidator.Coverage(
                trackedFraction: 0.95,
                generation: 7,
                continuityEpoch: 11
            )
        )
        guard case let .validated(evidence) = event else {
            Issue.record("Expected accepted punch evidence, got \(event)")
            throw FixtureError.expectedValidatedPunch
        }
        return evidence
    }
}

private enum FixtureError: Error {
    case expectedValidatedPunch
}
