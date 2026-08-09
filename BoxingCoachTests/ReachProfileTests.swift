import Foundation
import XCTest
import simd
@testable import BoxingCoach

final class ReachProfileTests: XCTestCase {
    func testCalibrationRejectsStationaryAndInsufficientMotion() {
        let stationary = ReachCalibration.candidateForwardReach(
            guardPosition: SIMD3(0.02, -0.04, 0.62),
            fistPosition: SIMD3(0.02, -0.04, 0.62)
        )
        XCTAssertNil(stationary, "An already-extended stationary fist must not calibrate reach")

        let justUnderMinimum = ReachCalibration.minimumExtensionFromGuard - 0.001
        let insufficient = ReachCalibration.candidateForwardReach(
            guardPosition: SIMD3(0, 0, 0.40),
            fistPosition: SIMD3(0, 0, 0.40 + justUnderMinimum)
        )
        XCTAssertNil(insufficient, "Calibration must require meaningful outward travel from guard")
    }

    func testCalibrationRejectsImplausibleAndNonFiniteSamples() {
        let belowPlausibleRange = ReachCalibration.candidateForwardReach(
            guardPosition: SIMD3(0, 0, 0.10),
            fistPosition: SIMD3(0, 0, ReachCalibration.plausibleForwardRange.lowerBound - 0.01)
        )
        XCTAssertNil(belowPlausibleRange)

        let abovePlausibleRange = ReachCalibration.candidateForwardReach(
            guardPosition: SIMD3(0, 0, 0.80),
            fistPosition: SIMD3(0, 0, ReachCalibration.plausibleForwardRange.upperBound + 0.01)
        )
        XCTAssertNil(abovePlausibleRange)

        let nonFiniteGuard = ReachCalibration.candidateForwardReach(
            guardPosition: SIMD3(.nan, 0, 0.20),
            fistPosition: SIMD3(0, 0, 0.70)
        )
        XCTAssertNil(nonFiniteGuard)

        let nonFiniteFist = ReachCalibration.candidateForwardReach(
            guardPosition: SIMD3(0, 0, 0.20),
            fistPosition: SIMD3(0, 0, .infinity)
        )
        XCTAssertNil(nonFiniteFist)
    }

    func testCalibrationAcceptsAnOutwardExtension() throws {
        let reach = try XCTUnwrap(
            ReachCalibration.candidateForwardReach(
                guardPosition: SIMD3(-0.14, -0.03, 0.20),
                fistPosition: SIMD3(-0.10, 0.02, 0.72)
            )
        )

        XCTAssertEqual(reach, 0.72, accuracy: 1e-6)
    }

    func testRobustReachIgnoresASingleFiniteTrackingSpike() throws {
        let samples: [Float] = [0.61, 0.62, 0.63, 0.62, 0.64, 0.61, 0.63, 1.10]
        let reach = try XCTUnwrap(ReachCalibration.robustForwardReach(from: samples))

        XCTAssertEqual(reach, 0.63, accuracy: 1e-6)
        XCTAssertNil(
            ReachCalibration.robustForwardReach(from: Array(samples.prefix(7))),
            "A brief burst must not be treated as a stable held extension"
        )
    }

    func testBilateralCalibrationUsesTheShorterArmAndRequiresBoth() throws {
        let reach = try XCTUnwrap(
            ReachCalibration.conservativeBilateralReach([
                .left: 0.80,
                .right: 0.55
            ])
        )

        XCTAssertEqual(reach, 0.55, accuracy: 1e-6)
        XCTAssertNil(ReachCalibration.conservativeBilateralReach([.left: 0.80]))
        XCTAssertNil(
            ReachCalibration.conservativeBilateralReach([
                .left: 0.80,
                .right: ReachCalibration.plausibleForwardRange.lowerBound - 0.01
            ])
        )
    }

    func testCalibratedProfilesPutEveryTargetInTheLastTenthOfReach() {
        let measuredReach: Float = 0.80
        let originalAir = ReachProfile.air
        let air = originalAir.calibrated(measuredForwardReach: measuredReach)

        XCTAssertEqual(air.forwardMax, measuredReach, accuracy: 1e-6)
        XCTAssertEqual(
            forwardWidth(of: air),
            measuredReach * originalAir.forwardBandFraction,
            accuracy: 1e-6
        )

        XCTAssertEqual(air.lateralMin, originalAir.lateralMin, accuracy: 1e-6)
        XCTAssertEqual(air.lateralMax, originalAir.lateralMax, accuracy: 1e-6)

        XCTAssertEqual(air.verticalMin, originalAir.verticalMin)
        XCTAssertEqual(air.verticalMax, originalAir.verticalMax)
    }

    func testCalibratedTargetsAlwaysSitNearFullReach() {
        for measuredReach in stride(from: Float(0.40), through: 0.90, by: 0.05) {
            let air = ReachProfile.air.calibrated(measuredForwardReach: measuredReach)
            let expectedNearEdge = measuredReach * (1 - ReachProfile.air.forwardBandFraction)

            XCTAssertEqual(air.forwardMax, measuredReach, accuracy: 1e-6)
            XCTAssertEqual(air.forwardMin, expectedNearEdge, accuracy: 1e-6)
            XCTAssertLessThan(air.forwardMin, air.forwardMax)
        }
    }

    func testSpawnBandScalesWithMeasuredBody() {
        let short = ReachProfile.air.calibrated(measuredForwardReach: 0.50)
        let long = ReachProfile.air.calibrated(measuredForwardReach: 0.80)

        XCTAssertEqual(short.forwardMin, 0.45, accuracy: 1e-6)
        XCTAssertEqual(short.forwardMax, 0.50, accuracy: 1e-6)
        XCTAssertEqual(long.forwardMin, 0.72, accuracy: 1e-6)
        XCTAssertEqual(long.forwardMax, 0.80, accuracy: 1e-6)
        XCTAssertEqual(
            short.forwardMin / short.forwardMax,
            long.forwardMin / long.forwardMax,
            accuracy: 1e-6
        )
    }

    func testCalibrationClampsUsableReachWithoutChangingProfileIdentity() {
        let shortAir = ReachProfile.air.calibrated(measuredForwardReach: 0.10)
        let longAir = ReachProfile.air.calibrated(measuredForwardReach: 2.0)

        XCTAssertEqual(shortAir.forwardMax, 0.35, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(shortAir.forwardMin, ReachProfile.minimumForwardSpawn)
        XCTAssertLessThan(shortAir.forwardMin, shortAir.forwardMax)
        XCTAssertEqual(longAir.forwardMax, 0.95, accuracy: 1e-6)
        XCTAssertEqual(longAir.verticalMin, ReachProfile.air.verticalMin)
        XCTAssertEqual(longAir.verticalMax, ReachProfile.air.verticalMax)
    }

    func testSettledReachMeasuresHeldExtensionInsteadOfOutboundRamp() throws {
        let samples = rampThenHold(from: 0.40, to: 0.66, rampDuration: 0.35, holdDuration: 0.40)
        let settled = try XCTUnwrap(ReachCalibration.settledForwardReach(from: samples))

        XCTAssertEqual(settled, 0.66, accuracy: 0.01)

        let legacy = try XCTUnwrap(
            ReachCalibration.robustForwardReach(
                from: samples.prefix(while: { $0.time <= 0.25 }).map(\.forward)
            )
        )
        XCTAssertLessThan(legacy, settled - 0.05)
    }

    func testSettledReachRejectsMotionWithoutAHold() {
        let rampOnly = rampThenHold(from: 0.40, to: 0.66, rampDuration: 0.35, holdDuration: 0)
        XCTAssertNil(ReachCalibration.settledForwardReach(from: rampOnly))

        let tooBriefHold = rampThenHold(
            from: 0.40,
            to: 0.66,
            rampDuration: 0.35,
            holdDuration: ReachCalibration.plateauDuration - 0.10
        )
        XCTAssertNil(ReachCalibration.settledForwardReach(from: tooBriefHold))
    }

    func testSettledReachIgnoresEarlyTouchAndUsesLaterHold() throws {
        var samples = rampThenHold(from: 0.40, to: 0.655, rampDuration: 0.08, holdDuration: 0.03)
        let retreat = rampThenHold(from: 0.40, to: 0.40, rampDuration: 0.10, holdDuration: 0)
        let realHold = rampThenHold(from: 0.41, to: 0.66, rampDuration: 0.30, holdDuration: 0.40)

        let spikeEnd = samples.last?.time ?? 0
        samples += retreat.map {
            ReachSample(forward: $0.forward, time: $0.time + spikeEnd + 0.02)
        }
        let retreatEnd = samples.last?.time ?? 0
        samples += realHold.map {
            ReachSample(forward: $0.forward, time: $0.time + retreatEnd + 0.02)
        }

        let settled = try XCTUnwrap(ReachCalibration.settledForwardReach(from: samples))
        XCTAssertEqual(settled, 0.66, accuracy: 0.01)
    }

    func testGuardClearancePreventsStationaryAutoHitAndFailsClosedWithoutSpace() throws {
        let profile = ReachProfile.air.calibrated(measuredForwardReach: 0.80)
        let safe = try XCTUnwrap(
            profile.placingTargetsBeyondGuard(
                maximumGuardForward: 0.44,
                hitRadius: 0.12
            )
        )

        XCTAssertGreaterThanOrEqual(safe.forwardMin, 0.58)
        XCTAssertEqual(safe.forwardMax, profile.forwardMax)
        XCTAssertNil(
            profile.placingTargetsBeyondGuard(
                maximumGuardForward: profile.forwardMax - 0.10,
                hitRadius: 0.12
            )
        )
    }

    func testRandomBodyTargetsRemainInsideEveryProfileBound() {
        let profiles = [
            ReachProfile.air,
            ReachProfile.air.calibrated(measuredForwardReach: 0.82)
        ]

        for profile in profiles {
            for _ in 0..<1_000 {
                let target = profile.randomBodyTargetPosition()
                XCTAssertGreaterThanOrEqual(target.x, profile.lateralMin)
                XCTAssertLessThanOrEqual(target.x, profile.lateralMax)
                XCTAssertGreaterThanOrEqual(target.y, profile.verticalMin)
                XCTAssertLessThanOrEqual(target.y, profile.verticalMax)
                XCTAssertGreaterThanOrEqual(target.z, profile.forwardMin)
                XCTAssertLessThanOrEqual(target.z, profile.forwardMax)
            }
        }
    }

    func testBodyFrameRoundTripAndForwardReachAreTranslationAndYawInvariant() throws {
        let frames = [
            makeFrame(origin: SIMD3(0, 1.20, 0), yaw: 0),
            makeFrame(origin: SIMD3(3.4, 0.85, -2.1), yaw: 1.17)
        ]
        let bodyPoint = SIMD3<Float>(0.23, -0.11, 0.67)

        for frame in frames {
            assertVectorEqual(frame.toBody(frame.toWorld(bodyPoint)), bodyPoint)
        }

        let guardInBodySpace = SIMD3<Float>(-0.14, -0.04, 0.18)
        let fistInBodySpace = SIMD3<Float>(-0.08, 0.03, 0.72)
        let measuredReaches = frames.map { frame -> Float? in
            let guardInWorld = frame.toWorld(guardInBodySpace)
            let fistInWorld = frame.toWorld(fistInBodySpace)
            return ReachCalibration.candidateForwardReach(
                guardPosition: frame.toBody(guardInWorld),
                fistPosition: frame.toBody(fistInWorld)
            )
        }

        XCTAssertEqual(try XCTUnwrap(measuredReaches[0]), 0.72, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(measuredReaches[1]), 0.72, accuracy: 1e-5)

        let firstWorldTravel = frames[0].toWorld(fistInBodySpace) - frames[0].toWorld(guardInBodySpace)
        let secondWorldTravel = frames[1].toWorld(fistInBodySpace) - frames[1].toWorld(guardInBodySpace)
        XCTAssertNotEqual(
            firstWorldTravel.z,
            secondWorldTravel.z,
            accuracy: 0.05,
            "The test frames should represent meaningfully different world-space yaws"
        )
    }

    private func lateralWidth(of profile: ReachProfile) -> Float {
        profile.lateralMax - profile.lateralMin
    }

    private func forwardWidth(of profile: ReachProfile) -> Float {
        profile.forwardMax - profile.forwardMin
    }

    private func rampThenHold(
        from: Float,
        to: Float,
        rampDuration: TimeInterval,
        holdDuration: TimeInterval
    ) -> [ReachSample] {
        let step = 1.0 / 90.0
        var samples: [ReachSample] = []
        var time: TimeInterval = 0

        while time < rampDuration {
            let progress = rampDuration > 0 ? Float(time / rampDuration) : 1
            samples.append(ReachSample(forward: from + (to - from) * progress, time: time))
            time += step
        }

        let holdEnd = rampDuration + holdDuration
        var jitterIndex = 0
        while time <= holdEnd {
            let jitter: Float = jitterIndex.isMultiple(of: 2) ? 0.005 : -0.005
            samples.append(ReachSample(forward: to - 0.005 + jitter, time: time))
            jitterIndex += 1
            time += step
        }

        return samples
    }

    private func makeFrame(origin: SIMD3<Float>, yaw: Float) -> BodyFrame {
        let up = SIMD3<Float>(0, 1, 0)
        let forward = SIMD3<Float>(sin(yaw), 0, -cos(yaw))
        let right = simd_normalize(simd_cross(forward, up))
        return BodyFrame(
            origin: origin,
            right: right,
            up: up,
            forward: forward,
            headPosition: origin + up * 0.20 + forward * 0.10
        )
    }

    private func assertVectorEqual(
        _ actual: SIMD3<Float>,
        _ expected: SIMD3<Float>,
        accuracy: Float = 1e-5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }
}
