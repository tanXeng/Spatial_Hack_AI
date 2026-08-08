//
//  BoxingDomainTests.swift
//  TestTests
//

import Foundation
import Testing
import simd
@testable import Test

struct BoxingDomainTests {
    private let profile = CalibrationProfile(
        stance: .orthodox,
        leftGuard: SIMD3<Float>(0, 1.3, -0.35),
        rightGuard: SIMD3<Float>(0.2, 1.3, -0.35),
        comfortableReach: 0.4,
        straightPunchDirection: SIMD3<Float>(0, 0, -1),
        referenceStraightSpeed: 1.0
    )

    @Test
    func stanceMapsLeadAndRearHands() {
        #expect(Stance.orthodox.hand(for: .jab) == .left)
        #expect(Stance.orthodox.hand(for: .cross) == .right)
        #expect(Stance.southpaw.hand(for: .jab) == .right)
        #expect(Stance.southpaw.hand(for: .cross) == .left)
        #expect(Stance.southpaw.punch(for: .right) == .jab)
    }

    @Test
    func fistCenterUsesOnlyFiniteTrackedJoints() {
        let center = FistCenterEstimator.centroid(
            of: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(0.03, 0, 0),
                nil,
                SIMD3<Float>(0.06, 0, 0),
                SIMD3<Float>(.infinity, 0, 0),
            ],
            minimumJointCount: 3
        )

        #expect(center != nil)
        #expect(abs((center?.x ?? 0) - 0.03) < 0.0001)
        #expect(FistCenterEstimator.centroid(
            of: [SIMD3<Float>.zero, nil],
            minimumJointCount: 2
        ) == nil)
    }

    @Test
    func sweptHitCatchesTunnelingCombinedRadiiAndDegenerateSegments() {
        let center = SIMD3<Float>(0, 0, -0.5)

        #expect(BoxingGeometry.sweptSegmentIntersectsSphere(
            from: SIMD3<Float>(0, 0, 0),
            to: SIMD3<Float>(0, 0, -1),
            sphereCenter: center,
            sphereRadius: 0.1
        ))

        #expect(!BoxingGeometry.sweptSegmentIntersectsSphere(
            from: SIMD3<Float>(0.16, 0, 0),
            to: SIMD3<Float>(0.16, 0, -1),
            sphereCenter: center,
            sphereRadius: 0.1
        ))

        #expect(BoxingGeometry.sweptSegmentIntersectsSphere(
            from: SIMD3<Float>(0.13, 0, 0),
            to: SIMD3<Float>(0.13, 0, -1),
            sphereCenter: center,
            sphereRadius: 0.1,
            movingRadius: 0.04
        ))

        #expect(BoxingGeometry.sweptSegmentIntersectsSphere(
            from: center,
            to: center,
            sphereCenter: center,
            sphereRadius: 0.1
        ))
        #expect(!BoxingGeometry.sweptSegmentIntersectsSphere(
            from: .zero,
            to: .zero,
            sphereCenter: center,
            sphereRadius: 0.1
        ))
    }

    @Test
    func calibratedTargetsKeepAMinimumClearPunchPath() {
        let configuration = DrillConfiguration.provisional

        for punch in PunchKind.allCases {
            let hand = profile.hand(for: punch)
            let guardPosition = profile.guardPosition(for: hand)
            let target = profile.targetPosition(for: punch, configuration: configuration)
            let clearPath = simd_length(target - guardPosition)
                - configuration.effectiveTargetRadius

            #expect(clearPath >= configuration.minimumPunchTravel)
        }
    }

    @Test
    func targetsAndDetectorUseIndependentHandCalibration() {
        var configuration = detectorConfiguration()
        configuration.targetReachFraction = 0.80
        configuration.targetVerticalOffset = 0
        let bilateral = CalibrationProfile(
            stance: .orthodox,
            leftGuard: profile.leftGuard,
            rightGuard: profile.rightGuard,
            leftHand: HandCalibrationProfile(
                acceptedFunctionalReach: 0.36,
                targetPlacementReach: 0.30,
                straightPunchDirection: SIMD3<Float>(0, 0, -1),
                referenceProjectedPace: 0.8
            ),
            rightHand: HandCalibrationProfile(
                acceptedFunctionalReach: 0.52,
                targetPlacementReach: 0.44,
                straightPunchDirection: SIMD3<Float>(1, 0, 0),
                referenceProjectedPace: 1.4
            )
        )

        let jabTarget = bilateral.targetPosition(
            for: .jab,
            configuration: configuration
        )
        let crossTarget = bilateral.targetPosition(
            for: .cross,
            configuration: configuration
        )
        #expect(abs(simd_distance(jabTarget, bilateral.leftGuard) - 0.24) < 0.0001)
        #expect(abs(simd_distance(crossTarget, bilateral.rightGuard) - 0.352) < 0.0001)
        #expect(bilateral.referenceProjectedPace(for: .left) == 0.8)
        #expect(bilateral.referenceProjectedPace(for: .right) == 1.4)

        var detector = PunchDetector(
            calibration: bilateral,
            configuration: configuration
        )
        let cue = targetCue(
            expectedPunch: .cross,
            center: bilateral.rightGuard + SIMD3<Float>(0.25, 0, 0)
        )
        _ = detector.process(sample(time: 0, right: bilateral.rightGuard), target: cue)
        _ = detector.process(sample(
            time: 0.1,
            right: bilateral.rightGuard + SIMD3<Float>(0.10, 0, 0)
        ), target: cue)
        let events = detector.process(sample(
            time: 0.2,
            right: bilateral.rightGuard + SIMD3<Float>(0.30, 0, 0)
        ), target: cue)
        #expect(events.first?.hand == .right)
        #expect(events.first?.kind == .cross)
    }

    @Test
    func punchDetectorEmitsAtFirstContactAndLocksUntilGuardReturn() {
        let configuration = detectorConfiguration()
        var detector = PunchDetector(calibration: profile, configuration: configuration)
        let guardPosition = profile.leftGuard
        let target = targetCue(
            expectedPunch: .jab,
            center: guardPosition + SIMD3<Float>(0, 0, -0.25)
        )

        #expect(detector.process(sample(time: 0, left: guardPosition), target: target).isEmpty)
        #expect(detector.process(sample(
            time: 0.1,
            left: guardPosition + SIMD3<Float>(0, 0, -0.10)
        ), target: target).isEmpty)

        let first = detector.process(sample(
            time: 0.2,
            left: guardPosition + SIMD3<Float>(0, 0, -0.30)
        ), target: target)
        #expect(first.count == 1)
        #expect(first.first?.kind == .jab)
        #expect((first.first?.contactAt ?? 1) < 0.2)

        #expect(detector.process(sample(
            time: 0.3,
            left: guardPosition + SIMD3<Float>(0, 0, -0.35)
        ), target: target).isEmpty)

        #expect(detector.process(sample(time: 0.4, left: guardPosition), target: target).isEmpty)
        #expect(detector.process(sample(
            time: 0.5,
            left: guardPosition + SIMD3<Float>(0, 0, -0.10)
        ), target: target).isEmpty)

        let second = detector.process(sample(
            time: 0.6,
            left: guardPosition + SIMD3<Float>(0, 0, -0.30)
        ), target: target)
        #expect(second.count == 1)
    }

    @Test
    func cachedPoseTimestampDoesNotCreateSyntheticVelocity() {
        let configuration = detectorConfiguration()
        var detector = PunchDetector(calibration: profile, configuration: configuration)
        let guardPosition = profile.leftGuard
        let target = targetCue(
            expectedPunch: .jab,
            center: guardPosition + SIMD3<Float>(0, 0, -0.25)
        )

        let guardPose = pose(guardPosition, capturedAt: 0)
        #expect(detector.process(
            HandSample(timestamp: 0, left: guardPose, right: nil),
            target: target
        ).isEmpty)
        #expect(detector.process(
            HandSample(timestamp: 0.09, left: guardPose, right: nil),
            target: target
        ).isEmpty)

        #expect(detector.process(sample(
            time: 0.1,
            left: guardPosition + SIMD3<Float>(0, 0, -0.10)
        ), target: target).isEmpty)
        #expect(detector.process(sample(
            time: 0.2,
            left: guardPosition + SIMD3<Float>(0, 0, -0.30)
        ), target: target).count == 1)
    }

    @Test
    func slowDriftAndSidewaysMotionDoNotBecomePunches() {
        var configuration = detectorConfiguration()
        configuration.minimumOutwardSpeed = 0.5
        var detector = PunchDetector(calibration: profile, configuration: configuration)
        let guardPosition = profile.leftGuard
        let target = targetCue(
            expectedPunch: .jab,
            center: guardPosition + SIMD3<Float>(0, 0, -0.25)
        )

        #expect(detector.process(sample(time: 0, left: guardPosition), target: target).isEmpty)
        #expect(detector.process(sample(
            time: 0.15,
            left: guardPosition + SIMD3<Float>(0, 0, -0.06)
        ), target: target).isEmpty)
        #expect(detector.process(sample(
            time: 0.30,
            left: guardPosition + SIMD3<Float>(0, 0, -0.12)
        ), target: target).isEmpty)
        #expect(detector.process(sample(
            time: 0.45,
            left: guardPosition + SIMD3<Float>(0, 0, -0.30)
        ), target: target).isEmpty)

        detector.reset()
        #expect(detector.process(sample(time: 1.0, left: guardPosition), target: target).isEmpty)
        #expect(detector.process(sample(
            time: 1.1,
            left: guardPosition + SIMD3<Float>(0.20, 0, 0)
        ), target: target).isEmpty)
    }

    @Test
    func validStraightSpatialMissEmitsWhenRetractionBegins() {
        let configuration = detectorConfiguration()
        var detector = PunchDetector(calibration: profile, configuration: configuration)
        let guardPosition = profile.leftGuard
        let target = targetCue(
            expectedPunch: .jab,
            center: guardPosition + SIMD3<Float>(0.30, 0, -0.25)
        )

        _ = detector.process(sample(time: 0, left: guardPosition), target: target)
        _ = detector.process(sample(
            time: 0.1,
            left: guardPosition + SIMD3<Float>(0, 0, -0.10)
        ), target: target)
        _ = detector.process(sample(
            time: 0.2,
            left: guardPosition + SIMD3<Float>(0, 0, -0.30)
        ), target: target)
        let events = detector.process(sample(
            time: 0.3,
            left: guardPosition + SIMD3<Float>(0, 0, -0.20)
        ), target: target)

        #expect(events.count == 1)
        #expect(events.first?.kind == .jab)
        #expect(events.first?.contactAt == nil)
        #expect(events.first?.completedAt == 0.2)
    }

    @Test
    func punchStartedBeforeCueDoesNotAttachToLaterCue() {
        let configuration = detectorConfiguration()
        var detector = PunchDetector(calibration: profile, configuration: configuration)
        let guardPosition = profile.leftGuard
        let target = targetCue(
            expectedPunch: .jab,
            center: guardPosition + SIMD3<Float>(0, 0, -0.25),
            presentedAt: 0.15,
            expiresAt: 1
        )

        _ = detector.process(sample(time: 0, left: guardPosition), target: nil)
        _ = detector.process(sample(
            time: 0.1,
            left: guardPosition + SIMD3<Float>(0, 0, -0.15)
        ), target: nil)
        _ = detector.process(sample(
            time: 0.2,
            left: guardPosition + SIMD3<Float>(0, 0, -0.30)
        ), target: target)
        let events = detector.process(sample(
            time: 0.3,
            left: guardPosition + SIMD3<Float>(0, 0, -0.20)
        ), target: target)

        #expect(events.isEmpty)
    }

    @Test
    func cueExpiryIncludesExactContactAndRejectsLaterContact() {
        let configuration = detectorConfiguration()
        let guardPosition = profile.leftGuard

        func run(expiresAt: TimeInterval) -> [PunchEvent] {
            var detector = PunchDetector(calibration: profile, configuration: configuration)
            let target = targetCue(
                expectedPunch: .jab,
                center: guardPosition + SIMD3<Float>(0, 0, -0.35),
                expiresAt: expiresAt
            )
            _ = detector.process(sample(time: 0, left: guardPosition), target: target)
            _ = detector.process(sample(
                time: 0.1,
                left: guardPosition + SIMD3<Float>(0, 0, -0.10)
            ), target: target)
            return detector.process(sample(
                time: 0.2,
                left: guardPosition + SIMD3<Float>(0, 0, -0.30)
            ), target: target)
        }

        #expect(run(expiresAt: 0.2).count == 1)
        #expect(run(expiresAt: 0.199).isEmpty)
    }

    @Test
    func trackingGapRequiresFreshGuardBeforeAnotherPunch() {
        let configuration = detectorConfiguration()
        var detector = PunchDetector(calibration: profile, configuration: configuration)
        let guardPosition = profile.leftGuard
        let target = targetCue(
            expectedPunch: .jab,
            center: guardPosition + SIMD3<Float>(0, 0, -0.25)
        )

        _ = detector.process(sample(time: 0, left: guardPosition), target: target)
        _ = detector.process(sample(
            time: 0.1,
            left: guardPosition + SIMD3<Float>(0, 0, -0.1)
        ), target: target)
        _ = detector.process(HandSample(timestamp: 0.2, left: nil, right: nil), target: target)
        #expect(detector.process(sample(
            time: 0.3,
            left: guardPosition + SIMD3<Float>(0, 0, -0.3)
        ), target: target).isEmpty)
        #expect(detector.process(sample(time: 0.4, left: guardPosition), target: target).isEmpty)
    }

    @Test
    func southpawRightHandContactMapsToJab() {
        let southpaw = CalibrationProfile(
            stance: .southpaw,
            leftGuard: profile.leftGuard,
            rightGuard: profile.rightGuard,
            leftHand: profile.leftHand,
            rightHand: profile.rightHand
        )
        let configuration = detectorConfiguration()
        var detector = PunchDetector(calibration: southpaw, configuration: configuration)
        let guardPosition = southpaw.rightGuard
        let target = targetCue(
            expectedPunch: .jab,
            center: guardPosition + SIMD3<Float>(0, 0, -0.25)
        )

        _ = detector.process(sample(time: 0, right: guardPosition), target: target)
        _ = detector.process(sample(
            time: 0.1,
            right: guardPosition + SIMD3<Float>(0, 0, -0.10)
        ), target: target)
        let events = detector.process(sample(
            time: 0.2,
            right: guardPosition + SIMD3<Float>(0, 0, -0.30)
        ), target: target)

        #expect(events.first?.kind == .jab)
        #expect(events.first?.hand == .right)
    }

    @Test
    func roundSummarySeparatesTimeoutsWrongHandsAndCancelledCues() {
        let empty = RoundSummary(attempts: [], pausedDuration: 1.5)
        #expect(empty.hitRate == 0)
        #expect(empty.averageResponseTime == nil)
        #expect(empty.guardReturnConsistency == nil)

        let cue = targetCue(
            expectedPunch: .jab,
            center: SIMD3<Float>(0, 1, -1),
            presentedAt: 10,
            expiresAt: 12
        )
        let attempts = [
            AttemptResult(
                cue: cue,
                outcome: .hit,
                resolvedAt: 10.4,
                punch: punchEvent(
                    hand: .left,
                    kind: .jab,
                    completedAt: 10.4,
                    contactAt: 10.4
                ),
                responseTime: 0.4,
                relativeSpeed: 1.2,
                returnedToGuard: true
            ),
            AttemptResult(
                cue: cue,
                outcome: .timeout,
                resolvedAt: 12,
                punch: nil,
                responseTime: nil,
                relativeSpeed: nil,
                returnedToGuard: nil
            ),
            AttemptResult(
                cue: cue,
                outcome: .wrongPunch,
                resolvedAt: 11,
                punch: punchEvent(
                    hand: .right,
                    kind: .cross,
                    completedAt: 11,
                    contactAt: nil
                ),
                responseTime: 0.9,
                relativeSpeed: 1.0,
                returnedToGuard: nil
            ),
            AttemptResult(
                cue: cue,
                outcome: .miss,
                resolvedAt: 11.2,
                punch: punchEvent(
                    hand: .left,
                    kind: .jab,
                    completedAt: 11.2,
                    contactAt: nil
                ),
                responseTime: nil,
                relativeSpeed: 0.8,
                returnedToGuard: false
            ),
        ]
        let summary = RoundSummary(
            attempts: attempts,
            pausedDuration: 2,
            cancelledCues: 2,
            trackingInterruptions: 3
        )

        #expect(summary.completedAttempts == 4)
        #expect(summary.hits == 1)
        #expect(summary.misses == 3)
        #expect(summary.spatialMisses == 1)
        #expect(summary.timeouts == 1)
        #expect(summary.wrongPunches == 1)
        #expect(summary.cancelledCues == 2)
        #expect(summary.trackingInterruptions == 3)
        #expect(summary.guardReturnsCensored == 1)
        #expect(abs(summary.hitRate - 0.25) < 0.0001)
        #expect(abs((summary.averageResponseTime ?? 0) - 0.4) < 0.0001)
        #expect(abs((summary.averageRelativeSpeed ?? 0) - 1.0) < 0.0001)
        #expect(summary.guardReturnConsistency == 0.5)
    }

    private func punchEvent(
        hand: HandSide,
        kind: PunchKind,
        completedAt: TimeInterval,
        contactAt: TimeInterval?
    ) -> PunchEvent {
        PunchEvent(
            hand: hand,
            kind: kind,
            startedAt: completedAt - 0.2,
            completedAt: completedAt,
            contactAt: contactAt,
            segmentStart: .zero,
            segmentEnd: SIMD3<Float>(0, 0, -0.2),
            peakSpeed: 1
        )
    }

    private func detectorConfiguration() -> DrillConfiguration {
        var configuration = DrillConfiguration.provisional
        configuration.targetRadius = 0.03
        configuration.fistRadius = 0.02
        configuration.guardReturnRadius = 0.06
        configuration.minimumGuardDeparture = 0.08
        configuration.minimumPunchTravel = 0.08
        configuration.minimumOutwardSpeed = 0.10
        configuration.minimumRetractSpeed = 0.10
        configuration.reversalDistance = 0.01
        return configuration
    }

    private func targetCue(
        expectedPunch: PunchKind,
        center: SIMD3<Float>,
        presentedAt: TimeInterval = 0,
        expiresAt: TimeInterval = 1
    ) -> TargetCue {
        TargetCue(
            sequenceIndex: 0,
            expectedPunch: expectedPunch,
            center: center,
            radius: 0.03,
            presentedAt: presentedAt,
            expiresAt: expiresAt
        )
    }

    private func pose(
        _ position: SIMD3<Float>,
        capturedAt: TimeInterval
    ) -> HandPose {
        HandPose(
            fistCenter: position,
            wrist: nil,
            trackedKnuckleCount: 4,
            capturedAt: capturedAt
        )
    }

    private func sample(
        time: TimeInterval,
        left: SIMD3<Float>? = nil,
        right: SIMD3<Float>? = nil
    ) -> HandSample {
        HandSample(
            timestamp: time,
            left: left.map { pose($0, capturedAt: time) },
            right: right.map { pose($0, capturedAt: time) }
        )
    }
}
