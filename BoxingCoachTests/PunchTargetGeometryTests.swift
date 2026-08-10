import XCTest
import simd
@testable import BoxingCoach

/// Where the orange target ball actually ends up in the room.
///
/// The uppercut's target was reported as "not appearing". It was being spawned every time — the
/// authored landing simply sat 0.18 m from the user's eyes, and with a 0.07 m sphere that puts the
/// ball's near face ~0.11 m out, close enough to be unviewable. Nothing in the codebase related the
/// authored trajectory to *how far from the face the ball lands*, so nothing caught it.
///
/// These tests close that gap. They assert the property the user actually experiences — can I see
/// the ball? — rather than the keyframe numbers that produce it.
@MainActor
final class PunchTargetGeometryTests: XCTestCase {

    /// Below this the ball is in the user's face: too close to converge on, and with the sphere's
    /// own radius subtracted, at or inside the near plane.
    private let minimumViewingDistance: Float = 0.25

    /// A punch that lands further away than the user can reach is a different bug, but worth
    /// bounding from the same test.
    private let maximumViewingDistance: Float = 0.95

    /// Head at 1.6 m looking down -Z, which is the shape ARKit hands back for a user facing
    /// forward. Built through the real solver so the shoulder/eye offsets are the shipping ones.
    private func standingFrame(solver: ArmPoseSolver) throws -> BodyFrame {
        var head = matrix_identity_float4x4
        head.columns.3 = SIMD4(0, 1.6, 0, 1)
        return try XCTUnwrap(solver.bodyFrame(headTransform: head))
    }

    private func landingDistanceFromHead(
        technique: Technique,
        side: BodySide,
        measurements: BodyMeasurements
    ) throws -> Float {
        let solver = ArmPoseSolver(measurements: measurements)
        let frame = try standingFrame(solver: solver)
        let reference = ReferencePunchLibrary.punch(
            for: technique,
            stance: .orthodox,
            measurements: measurements,
            side: side
        )
        let landing = try XCTUnwrap(reference.sample(at: reference.peakTime))
        let world = solver.denormalize(landing.fist, side: side, frame: frame)
        return simd_distance(world, frame.headPosition)
    }

    /// The regression itself: every punch must put its ball somewhere the user can actually look at.
    func testEveryTechniqueLandsItsTargetAtAViewableDistance() throws {
        for technique in Technique.all {
            for side in [BodySide.left, .right] {
                let distance = try landingDistanceFromHead(
                    technique: technique,
                    side: side,
                    measurements: .averageAdult
                )
                XCTAssertGreaterThan(
                    distance,
                    minimumViewingDistance,
                    "\(technique.id)/\(side.rawValue) lands \(distance) m from the eyes — the ball is in the user's face"
                )
                XCTAssertLessThan(
                    distance,
                    maximumViewingDistance,
                    "\(technique.id)/\(side.rawValue) lands \(distance) m from the eyes — beyond reach"
                )
            }
        }
    }

    /// The uppercut is the shortest of the three, so it should land nearest — but still clearly
    /// further out than the failure it replaced, and in the same neighbourhood as the hook.
    func testUppercutLandsJustInsideTheHookRatherThanAtTheUsersChin() throws {
        let uppercut = try landingDistanceFromHead(
            technique: .uppercut,
            side: .left,
            measurements: .averageAdult
        )
        let hook = try landingDistanceFromHead(
            technique: .hook,
            side: .left,
            measurements: .averageAdult
        )
        let jab = try landingDistanceFromHead(
            technique: .jab,
            side: .left,
            measurements: .averageAdult
        )

        XCTAssertLessThan(uppercut, hook, "the uppercut is a shorter punch than the hook")
        XCTAssertLessThan(hook, jab, "the hook is a shorter punch than the jab")
        XCTAssertGreaterThan(
            uppercut,
            hook * 0.8,
            "the uppercut should be near the hook, not a fraction of it — this is the original bug"
        )
    }

    /// Landings scale with the measured arm, but the eye-to-shoulder offsets do not — so a small
    /// user's targets sit closer to their face than an average adult's. `BodyCalibration` clamps
    /// the chain to 0.80...1.25, and the ball has to stay viewable across that whole range.
    func testTargetsStayViewableAcrossTheCalibrationClampRange() throws {
        let reference = BodyMeasurements.averageAdult

        for scale in [Float(0.80), 1.0, 1.25] {
            let scaled = BodyMeasurements(
                height: reference.height,
                shoulderWidth: reference.shoulderWidth,
                upperArmLength: reference.upperArmLength * scale,
                forearmLength: reference.forearmLength * scale,
                wristToFistLength: reference.wristToFistLength * scale,
                eyeToShoulderDrop: reference.eyeToShoulderDrop,
                eyeToShoulderSetback: reference.eyeToShoulderSetback
            )

            for technique in Technique.all {
                let distance = try landingDistanceFromHead(
                    technique: technique,
                    side: .left,
                    measurements: scaled
                )
                // The smallest arm is the demanding case; allow it closer than an average adult
                // but never inside the sphere-plus-near-plane budget.
                XCTAssertGreaterThan(
                    distance,
                    0.20,
                    "\(technique.id) at chain scale \(scale) lands \(distance) m from the eyes"
                )
            }
        }
    }
}
