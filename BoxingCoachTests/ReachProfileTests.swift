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

    func testCalibratedProfilesAnchorToReachAndKeepTheirAuthoredDepth() {
        let measuredReach: Float = 0.80
        let originalAir = ReachProfile.air
        let originalBag = ReachProfile.bagZone
        let air = originalAir.calibrated(measuredForwardReach: measuredReach)
        let bag = originalBag.calibrated(measuredForwardReach: measuredReach)

        // The far edge is the measurement itself — no haircut applied on top of it.
        XCTAssertEqual(air.forwardMax, measuredReach, accuracy: 1e-6)
        XCTAssertEqual(bag.forwardMax, measuredReach, accuracy: 1e-6)

        // Depth is absolute, so the near edge cannot collapse toward the chest as reach shrinks.
        XCTAssertEqual(forwardWidth(of: air), forwardWidth(of: originalAir), accuracy: 1e-6)
        XCTAssertEqual(forwardWidth(of: bag), forwardWidth(of: originalBag), accuracy: 1e-6)

        // Lateral bounds have no dimensional relationship to forward reach and must not scale.
        XCTAssertEqual(air.lateralMin, originalAir.lateralMin, accuracy: 1e-6)
        XCTAssertEqual(air.lateralMax, originalAir.lateralMax, accuracy: 1e-6)
        XCTAssertEqual(bag.lateralMin, originalBag.lateralMin, accuracy: 1e-6)
        XCTAssertEqual(bag.lateralMax, originalBag.lateralMax, accuracy: 1e-6)

        XCTAssertEqual(air.verticalMin, originalAir.verticalMin)
        XCTAssertEqual(air.verticalMax, originalAir.verticalMax)
        XCTAssertEqual(bag.verticalMin, originalBag.verticalMin)
        XCTAssertEqual(bag.verticalMax, originalBag.verticalMax)

        XCTAssertGreaterThan(bag.forwardMin, air.forwardMin)
        XCTAssertLessThan(forwardWidth(of: bag), forwardWidth(of: air))
        XCTAssertLessThan(lateralWidth(of: bag), lateralWidth(of: air))
    }

    /// Regression test for targets spawning at roughly two-thirds of reach in Air Mode.
    func testCalibratedAirTargetsStayCloseToFullReach() {
        for measuredReach in stride(from: Float(0.50), through: 0.85, by: 0.05) {
            let air = ReachProfile.air.calibrated(measuredForwardReach: measuredReach)

            XCTAssertEqual(air.forwardMax, measuredReach, accuracy: 1e-6)
            XCTAssertGreaterThanOrEqual(
                air.forwardMin / measuredReach,
                0.73,
                "Nothing may spawn below 73% of measured reach at \(measuredReach) m"
            )
            XCTAssertGreaterThanOrEqual(air.forwardMin, ReachProfile.minimumForwardSpawn)
            XCTAssertLessThan(air.forwardMin, air.forwardMax)
        }
    }

    func testCalibrationClampsUsableReachWithoutChangingProfileIdentity() {
        let shortAir = ReachProfile.air.calibrated(measuredForwardReach: 0.10)
        let longBag = ReachProfile.bagZone.calibrated(measuredForwardReach: 2.0)

        XCTAssertEqual(shortAir.forwardMax, 0.35, accuracy: 1e-6)
        // The absolute floor wins over the authored depth on an implausibly short measurement.
        XCTAssertEqual(shortAir.forwardMin, ReachProfile.minimumForwardSpawn, accuracy: 1e-6)
        XCTAssertLessThan(shortAir.forwardMin, shortAir.forwardMax)

        XCTAssertEqual(longBag.forwardMax, 0.95, accuracy: 1e-6)
        XCTAssertLessThan(lateralWidth(of: longBag), lateralWidth(of: ReachProfile.air))
        XCTAssertEqual(longBag.verticalMin, ReachProfile.bagZone.verticalMin)
        XCTAssertEqual(longBag.verticalMax, ReachProfile.bagZone.verticalMax)
    }

    func testSettledReachMeasuresTheHeldExtensionNotTheOutboundRamp() throws {
        let samples = rampThenHold(from: 0.40, to: 0.66, rampDuration: 0.35, holdDuration: 0.40)
        let settled = try XCTUnwrap(ReachCalibration.settledForwardReach(from: samples))

        XCTAssertEqual(settled, 0.66, accuracy: 0.01)

        // The rule this replaced finalized on the ramp and landed far short of the real hold.
        let legacy = try XCTUnwrap(
            ReachCalibration.robustForwardReach(
                from: samples.prefix(while: { $0.time <= 0.25 }).map(\.forward)
            )
        )
        XCTAssertLessThan(
            legacy,
            settled - 0.05,
            "The old 0.25 s percentile rule should measurably under-report the held extension"
        )
    }

    func testSettledReachRejectsAPunchThatNeverHolds() {
        let rampOnly = rampThenHold(from: 0.40, to: 0.66, rampDuration: 0.35, holdDuration: 0)
        XCTAssertNil(
            ReachCalibration.settledForwardReach(from: rampOnly),
            "A fist still travelling has not established a reach"
        )

        let tooBriefHold = rampThenHold(
            from: 0.40,
            to: 0.66,
            rampDuration: 0.35,
            holdDuration: ReachCalibration.plateauDuration - 0.10
        )
        XCTAssertNil(ReachCalibration.settledForwardReach(from: tooBriefHold))
    }

    func testSettledReachIgnoresAnEarlyTouchAndUsesTheLaterRealHold() throws {
        // A brief spike near the eventual peak, a drop back to guard, then a genuine hold.
        var samples = rampThenHold(from: 0.40, to: 0.655, rampDuration: 0.08, holdDuration: 0.03)
        let retreat = rampThenHold(from: 0.40, to: 0.40, rampDuration: 0.10, holdDuration: 0)
        let realHold = rampThenHold(from: 0.41, to: 0.66, rampDuration: 0.30, holdDuration: 0.40)

        let spikeEnd = samples.last?.time ?? 0
        samples += retreat.map { ReachSample(forward: $0.forward, time: $0.time + spikeEnd + 0.02) }
        let retreatEnd = samples.last?.time ?? 0
        samples += realHold.map { ReachSample(forward: $0.forward, time: $0.time + retreatEnd + 0.02) }

        let settled = try XCTUnwrap(ReachCalibration.settledForwardReach(from: samples))
        XCTAssertEqual(settled, 0.66, accuracy: 0.01)
    }

    /// 90 Hz stream that ramps to `to`, then holds there with a little tracking jitter.
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
            // ±5 mm, comfortably inside `plateauTolerance`.
            let jitter: Float = jitterIndex % 2 == 0 ? 0.005 : -0.005
            samples.append(ReachSample(forward: to - 0.005 + jitter, time: time))
            jitterIndex += 1
            time += step
        }

        return samples
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
            ReachProfile.bagZone,
            ReachProfile.air.calibrated(measuredForwardReach: 0.82),
            ReachProfile.bagZone.calibrated(measuredForwardReach: 0.82)
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
