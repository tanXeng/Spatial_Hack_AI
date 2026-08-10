import RealityKit
import XCTest
@testable import BoxingCoach

/// Two kinds of test here.
///
/// The mapping tests are pure logic and run anywhere. The asset tests actually load the USDZ files
/// through RealityKit and assert the animations bind — the only way to catch a rig that imports
/// but silently refuses to animate, which no amount of `usdchecker` output proves.
@MainActor
final class CoachCharacterEntityTests: XCTestCase {

    // MARK: Clip mapping

    func testEveryTechniqueResolvesToAClip() throws {
        for technique in Technique.all {
            for side in [BodySide.left, .right] {
                let resolved = CoachCharacterEntity.resolveClip(technique: technique, side: side)
                XCTAssertNotNil(
                    resolved,
                    "\(technique.id) on the \(side.rawValue) has no coach clip"
                )
            }
        }
    }

    /// The coach stands beside the user facing the same way, so a clip already authored on the
    /// requested side needs no mirroring at all. Reflecting only on a side mismatch is what lets
    /// four one-sided clips cover all eight technique/side combinations.
    func testMirroringPutsTheMotionOnTheUsersSide() throws {
        // Jab is authored on the coach's left. An orthodox jab is the user's left, and side by side
        // his left is already the user's left — so the most common case does not mirror at all.
        let leftJab = try XCTUnwrap(
            CoachCharacterEntity.resolveClip(technique: .jab, side: .left)
        )
        XCTAssertEqual(leftJab.clip, "jab_left")
        XCTAssertFalse(leftJab.reflected)

        // A southpaw jab is thrown with the right, so the left-arm clip has to be mirrored.
        let rightJab = try XCTUnwrap(
            CoachCharacterEntity.resolveClip(technique: .jab, side: .right)
        )
        XCTAssertEqual(rightJab.clip, "jab_left")
        XCTAssertTrue(rightJab.reflected)

        // Cross is authored on the coach's right, so the reflection flips the other way.
        let rightCross = try XCTUnwrap(
            CoachCharacterEntity.resolveClip(technique: .cross, side: .right)
        )
        XCTAssertEqual(rightCross.clip, "cross_right")
        XCTAssertFalse(rightCross.reflected)

        let leftCross = try XCTUnwrap(
            CoachCharacterEntity.resolveClip(technique: .cross, side: .left)
        )
        XCTAssertTrue(leftCross.reflected)
    }

    /// Regression guard for the facing change: when the coach turned from facing the user to
    /// standing beside them, this rule had to invert. A stale `==` here puts every demo on the
    /// wrong arm while still looking perfectly plausible in the simulator.
    func testReflectionHappensOnlyOnASideMismatch() {
        for clipSide in [BodySide.left, .right] {
            for requested in [BodySide.left, .right] {
                XCTAssertEqual(
                    CoachCharacterEntity.shouldReflect(
                        clipSide: clipSide,
                        requestedSide: requested
                    ),
                    clipSide != requested,
                    "\(clipSide.rawValue) clip for a \(requested.rawValue) punch"
                )
            }
        }
    }

    // MARK: Placement

    /// He must stand off to one side — the side that keeps the demonstrating arm between the two
    /// bodies — but still **inside the user's forward field of view**, with his feet on the floor.
    func testCoachStandsOffAxisButInsideTheForwardFieldOfView() async throws {
        let coach = CoachCharacterEntity()
        let loaded = await coach.load()
        XCTAssertTrue(loaded, "coach failed to load from the app bundle")

        let measurements = BodyMeasurements.averageAdult
        // Shoulder line at 1.4 m, facing +Z, so "right" is +X.
        let frame = BodyFrame(
            origin: SIMD3(0, 1.4, 0),
            right: SIMD3(1, 0, 0),
            up: SIMD3(0, 1, 0),
            forward: SIMD3(0, 0, 1),
            headPosition: SIMD3(0, 1.6, 0)
        )

        coach.place(using: frame, measurements: measurements, demoSide: .right, reflected: false)
        let rightArmDemo = coach.worldPositionForTesting

        coach.place(using: frame, measurements: measurements, demoSide: .left, reflected: false)
        let leftArmDemo = coach.worldPositionForTesting

        // Right-arm demo stands on the user's left, and vice versa.
        XCTAssertLessThan(rightArmDemo.x, 0, "a right-arm demo belongs on the user's left")
        XCTAssertGreaterThan(leftArmDemo.x, 0, "a left-arm demo belongs on the user's right")

        // The one that actually matters: he has to be findable without turning your head. An
        // earlier version sat at ~62° off axis, which is only visible over your own shoulder.
        for spot in [rightArmDemo, leftArmDemo] {
            let offAxisAngle = atan2(abs(spot.x), spot.z) * 180 / .pi
            XCTAssertLessThan(
                offAxisAngle,
                30,
                "the coach must sit inside the forward field of view, not over the user's shoulder"
            )
            XCTAssertGreaterThan(
                offAxisAngle,
                10,
                "…but far enough off axis to be beside the user rather than in their punching lane"
            )
            // Mostly ahead, and far enough away that a whole body fits in view.
            XCTAssertGreaterThan(spot.z, 1.0)
        }

        // Feet on the floor, derived from the shoulder-line origin rather than assumed at y = 0.
        XCTAssertEqual(rightArmDemo.y, 1.4 - measurements.height * 0.83, accuracy: 0.05)
    }

    /// Turning the user must carry the coach round with them, not leave him at a fixed world spot.
    func testCoachFollowsTheUserAroundAndKeepsHisRelativeAngle() async throws {
        let coach = CoachCharacterEntity()
        let loaded = await coach.load()
        XCTAssertTrue(loaded, "coach failed to load from the app bundle")

        let measurements = BodyMeasurements.averageAdult
        let facingForward = BodyFrame(
            origin: SIMD3(0, 1.4, 0),
            right: SIMD3(1, 0, 0),
            up: SIMD3(0, 1, 0),
            forward: SIMD3(0, 0, 1),
            headPosition: SIMD3(0, 1.6, 0)
        )
        // Same user, now turned 90° to their right: forward is +X, right is -Z.
        let turnedRight = BodyFrame(
            origin: SIMD3(0, 1.4, 0),
            right: SIMD3(0, 0, -1),
            up: SIMD3(0, 1, 0),
            forward: SIMD3(1, 0, 0),
            headPosition: SIMD3(0, 1.6, 0)
        )

        coach.place(using: facingForward, measurements: measurements, demoSide: .right, reflected: false)
        let before = coach.worldPositionForTesting

        // Follow is smoothed, so drive it the way the session does rather than expecting one step
        // to arrive. 200 ticks is a little over two seconds at the session's frame interval.
        for _ in 0..<200 {
            coach.follow(using: turnedRight, measurements: measurements, demoSide: .right, reflected: false)
        }
        let after = coach.worldPositionForTesting

        XCTAssertGreaterThan(
            simd_distance(before, after),
            0.5,
            "the coach stayed put when the user turned — he must orbit to stay in view"
        )

        // He should hold the same angle off the user's *new* forward axis, which is +X.
        let offset = after - SIMD3(0, after.y, 0)
        let offAxisAngle = atan2(abs(simd_dot(offset, SIMD3(0, 0, -1))), simd_dot(offset, SIMD3(1, 0, 0)))
        XCTAssertEqual(offAxisAngle * 180 / .pi, 24, accuracy: 3)
    }

    /// Yaw interpolation has to take the short way round. Lerping raw radians across the ±π seam
    /// spins the coach a full turn in place.
    func testShortestAngleDeltaWrapsAcrossThePiSeam() {
        let almostPi: Float = .pi - 0.1
        let justPastPi: Float = -.pi + 0.1

        let delta = CoachCharacterEntity.shortestAngleDelta(from: almostPi, to: justPastPi)
        XCTAssertEqual(delta, 0.2, accuracy: 1e-4, "should step 0.2 rad forward, not ~6.1 back")

        XCTAssertEqual(
            CoachCharacterEntity.shortestAngleDelta(from: 0.3, to: 0.9),
            0.6,
            accuracy: 1e-5
        )
    }

    // MARK: Asset binding

    func testBaseAssetLoadsWithASkeletonAndAnIdleAnimation() async throws {
        let coach = try await Entity(named: "coach", in: Bundle.main)

        XCTAssertFalse(
            coach.availableAnimations.isEmpty,
            "coach.usdz exposed no animations — the skeleton or SkelAnimation did not survive export"
        )
        XCTAssertNotNil(
            findSkeleton(in: coach),
            "coach.usdz has no skinned mesh; the model would render unrigged"
        )
    }

    func testEveryPunchClipAssetExposesAnAnimation() async throws {
        for file in [
            "coach_jab_left",
            "coach_cross_right",
            "coach_hook_right",
            "coach_uppercut_right"
        ] {
            let holder = try await Entity(named: file, in: Bundle.main)
            let animations = holder.availableAnimations
            XCTAssertFalse(
                animations.isEmpty,
                "\(file).usdz exposed no animation — RealityKit will have nothing to play"
            )
        }
    }

    /// The one that matters: the whole library assembled the way the session uses it.
    func testLoadedCoachExposesEveryClipItNeeds() async throws {
        let coach = CoachCharacterEntity()
        let loaded = await coach.load()
        XCTAssertTrue(loaded, "coach failed to load from the app bundle")
        XCTAssertTrue(coach.isLoaded)

        // Playback returns a duration only when the clip resolved out of the library.
        for technique in Technique.all {
            let resolved = try XCTUnwrap(
                CoachCharacterEntity.resolveClip(technique: technique, side: .left)
            )
            let duration = coach.play(clip: resolved.clip)
            XCTAssertNotNil(
                duration,
                "clip '\(resolved.clip)' for \(technique.id) is missing from the animation library"
            )
            if let duration {
                XCTAssertGreaterThan(duration, 0.2, "'\(resolved.clip)' is suspiciously short")
                XCTAssertLessThan(duration, 10, "'\(resolved.clip)' is suspiciously long")
            }
        }
    }

    private func findSkeleton(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity, model.model?.mesh != nil {
            return model
        }
        for child in entity.children {
            if let found = findSkeleton(in: child) { return found }
        }
        return nil
    }
}
