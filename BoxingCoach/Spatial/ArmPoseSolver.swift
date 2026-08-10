import Foundation
import simd

// MARK: - Coordinate spaces
//
// Three frames matter in this file. Mixing them up is the single most likely way for this
// feature to break, so they are named explicitly everywhere rather than left to inference.
//
// 1. WORLD SPACE — ARKit's immersive space origin. Right-handed, +Y up, and by RealityKit
//    convention an unrotated entity faces −Z. Everything ARKit hands us is in this frame.
//
// 2. BODY SPACE — origin at the center of the shoulder line, axes from the user's torso.
//    +X = user's right, +Y = world up, **+Z = the direction the user faces**.
//
//    ⚠️ Note the sign: body-space +Z is FORWARD, the opposite of RealityKit's −Z-forward
//    convention. This is deliberate — "a jab travels in +Z" is far easier to reason about in
//    the scoring code than "a jab travels in −Z". Every conversion goes through `BodyFrame`,
//    so the flip happens in exactly one place. Do not hand-roll the conversion elsewhere.
//
// 3. NORMALIZED SPACE — body space, re-origined onto the *punching shoulder* and divided by
//    the user's arm reach. Dimensionless. This is what the scorer compares, and it is what
//    makes a 1.6 m user's jab and a 1.95 m user's jab land on the same numbers.

/// The user's torso frame, reconstructed from the head pose.
///
/// visionOS gives us no torso tracking at all, so this is an *estimate* built from the device
/// transform plus `BodyMeasurements`. It is only as good as those measurements — which is the
/// entire reason the Anthropometry feature exists.
nonisolated struct BodyFrame: Sendable {
    /// Center of the shoulder line, in world space.
    var origin: SIMD3<Float>
    /// Unit vector pointing to the user's right, in world space.
    var right: SIMD3<Float>
    /// Unit vector pointing up (always world up — the torso frame does not roll).
    var up: SIMD3<Float>
    /// Unit vector pointing where the user faces, in world space.
    var forward: SIMD3<Float>

    /// Head position in world space, kept for guard-hand scoring ("is the fist near the chin?").
    var headPosition: SIMD3<Float>

    /// World → body space.
    func toBody(_ world: SIMD3<Float>) -> SIMD3<Float> {
        let v = world - origin
        return SIMD3(simd_dot(v, right), simd_dot(v, up), simd_dot(v, forward))
    }

    /// Body → world space.
    func toWorld(_ body: SIMD3<Float>) -> SIMD3<Float> {
        origin + right * body.x + up * body.y + forward * body.z
    }

    /// Rotates a direction from body space to world space, ignoring translation.
    func directionToWorld(_ body: SIMD3<Float>) -> SIMD3<Float> {
        right * body.x + up * body.y + forward * body.z
    }

    /// World-space position of a shoulder joint.
    func shoulder(_ side: BodySide, measurements: BodyMeasurements) -> SIMD3<Float> {
        origin + right * (side.lateralSign * measurements.shoulderWidth * 0.5)
    }
}

/// A fully reconstructed arm at one instant, in world space.
struct ArmPose: Sendable {
    var side: BodySide
    var shoulder: SIMD3<Float>
    var elbow: SIMD3<Float>
    var wrist: SIMD3<Float>
    var fist: SIMD3<Float>
    var timestamp: TimeInterval

    /// False when this pose was extrapolated through a tracking dropout rather than measured.
    var isTracked: Bool
}

/// Reconstructs `(shoulder, elbow, wrist)` from what visionOS actually provides.
///
/// The problem this solves: ARKit gives us the **head** and the **hand**, but a punch is judged
/// on the **shoulder and elbow**, which are not tracked. So:
///
/// - **Shoulder** is estimated from the head pose plus body measurements.
/// - **Wrist** comes straight from hand tracking.
/// - **Elbow** is solved with two-bone IK, using the tracked `forearmArm` joint as a *hint*
///   rather than as the answer (see `solveElbow` for why).
///
/// Everything here is pure and stateless except the dropout smoothing in `ArmPoseTracker`.
struct ArmPoseSolver: Sendable {
    var measurements: BodyMeasurements

    init(measurements: BodyMeasurements = .averageAdult) {
        self.measurements = measurements
    }

    // MARK: Body frame

    /// Builds the torso frame from the head transform.
    ///
    /// Only the head's **yaw** is used. Pitch and roll are deliberately discarded: during a punch
    /// drill the user looks down at their hands almost continuously, and if the torso frame
    /// inherited that pitch the estimated shoulders would swing forward and up every time they
    /// glanced down — the ghost arm would visibly detach from the real one.
    func bodyFrame(headTransform: simd_float4x4) -> BodyFrame? {
        let headPosition = headTransform.translation
        guard headPosition.isFinite else { return nil }

        let worldUp = SIMD3<Float>(0, 1, 0)

        // RealityKit convention: an entity's forward is its −Z axis.
        let headForward = -SIMD3(
            headTransform.columns.2.x,
            headTransform.columns.2.y,
            headTransform.columns.2.z
        )
        let headUp = SIMD3(
            headTransform.columns.1.x,
            headTransform.columns.1.y,
            headTransform.columns.1.z
        )

        // Flatten head-forward onto the horizontal plane to extract yaw.
        var flat = SIMD3<Float>(headForward.x, 0, headForward.z)

        if simd_length(flat) < 0.05 {
            // Degenerate case: the user is looking almost straight up or straight down, so
            // head-forward carries almost no yaw information. The head's *up* axis does.
            //
            // Looking down, the head's up vector rotates to point along body-forward; looking
            // up, it rotates to point backward — hence the sign flip.
            var alternate = SIMD3<Float>(headUp.x, 0, headUp.z)
            if headForward.y > 0 { alternate = -alternate }
            flat = alternate
        }

        guard simd_length(flat) > 1e-4 else { return nil }
        let forward = simd_normalize(flat)

        // Right-handed cross product: facing −Z with +Y up yields +X on the right.
        let right = simd_normalize(simd_cross(forward, worldUp))

        // Walk from the eyes down to the shoulder line, and back, since the device sits at the
        // front of the face while the shoulder joints sit lower and meaningfully further back.
        let shoulderCenter = headPosition
            - worldUp * measurements.eyeToShoulderDrop
            - forward * measurements.eyeToShoulderSetback

        return BodyFrame(
            origin: shoulderCenter,
            right: right,
            up: worldUp,
            forward: forward,
            headPosition: headPosition
        )
    }

    // MARK: Arm reconstruction

    /// Reconstructs one arm. Returns `nil` if the hand is not currently tracked.
    func solve(hand: HandObservation, frame: BodyFrame) -> ArmPose {
        let shoulder = frame.shoulder(hand.side, measurements: measurements)
        let elbow = solveElbow(
            shoulder: shoulder,
            wrist: hand.wristPosition,
            hint: hand.elbowHint,
            side: hand.side,
            frame: frame
        )

        return ArmPose(
            side: hand.side,
            shoulder: shoulder,
            elbow: elbow,
            wrist: hand.wristPosition,
            fist: hand.fistPosition,
            timestamp: hand.timestamp,
            isTracked: true
        )
    }

    /// Places the elbow using two-bone IK, with the tracked joint supplying the pole vector.
    ///
    /// Why not just use the tracked `forearmArm` joint directly? Because it is extrapolated from
    /// the hand rather than observed, so its *distance* from the shoulder drifts — and when it
    /// drifts, the ghost arm's bones visibly stretch and shrink. IK guarantees the bones keep
    /// their length no matter what.
    ///
    /// But IK alone has a genuine ambiguity: for any shoulder and wrist, the elbow can sit
    /// anywhere on a circle around the shoulder-to-wrist axis. Something has to choose a point
    /// on that circle. That "something" is the pole vector — and the tracked joint, unreliable
    /// as its distance is, points in very much the right *direction*.
    ///
    /// So: tracked joint decides **where around the circle**, IK decides **how far along**. Each
    /// input is used only for what it is actually good at.
    func solveElbow(
        shoulder: SIMD3<Float>,
        wrist: SIMD3<Float>,
        hint: SIMD3<Float>?,
        side: BodySide,
        frame: BodyFrame
    ) -> SIMD3<Float> {
        // Preferred pole: toward the tracked forearm joint. Only its direction is trusted.
        //
        // Fallback, used whenever `forearmArm` is not tracked — common at the end of a fully
        // extended punch, when the elbow leaves the downward cameras' view. Anatomically the
        // elbow hangs below the arm axis, tucked slightly behind and out to the side; a boxer's
        // elbow in particular stays low until the punch extends.
        let pole: SIMD3<Float>
        if let hint, hint.isFinite {
            pole = hint - shoulder
        } else {
            pole = -frame.up
                + frame.right * (side.lateralSign * 0.35)
                - frame.forward * 0.25
        }

        return Self.twoBoneElbow(
            shoulder: shoulder,
            wrist: wrist,
            upperArm: measurements.upperArmLength,
            forearm: measurements.forearmLength,
            poleDirection: pole,
            fallbackDown: -frame.up
        )
    }

    /// Pure two-bone IK: places the elbow given the shoulder, the wrist, and both bone lengths.
    ///
    /// Unit-agnostic — callers pass either meters (live tracking) or arm-reach units (authoring
    /// reference punches). Keeping one implementation for both matters: the reference and the
    /// user's attempt must have their elbows derived the *same* way, or the elbow-alignment
    /// sub-metric would be measuring the difference between two solvers rather than between two
    /// punches.
    ///
    /// `poleDirection` need not be perpendicular or normalized; it is projected and normalized
    /// internally. It resolves the one genuine ambiguity in the problem — the elbow can lie
    /// anywhere on a circle around the shoulder→wrist axis, and the pole picks the point.
    nonisolated static func twoBoneElbow(
        shoulder: SIMD3<Float>,
        wrist: SIMD3<Float>,
        upperArm: Float,
        forearm: Float,
        poleDirection: SIMD3<Float>,
        fallbackDown: SIMD3<Float> = SIMD3(0, -1, 0)
    ) -> SIMD3<Float> {
        let toWrist = wrist - shoulder
        let reach = simd_length(toWrist)

        // Shoulder and wrist coincident — no axis to solve around. Drop the elbow straight down.
        guard reach > 1e-4 else {
            return shoulder + simd_normalize(fallbackDown) * upperArm
        }

        let axis = toWrist / reach

        // Law of cosines: distance from the shoulder to the elbow's projection onto the axis.
        //
        // When the punch is fully extended, `reach` approaches `upperArm + forearm` and this
        // collapses toward `upperArm` — the elbow lands on the axis and the arm is straight,
        // which is exactly right. If our measurements are too short for this user, `reach` can
        // exceed the chain length; then `offAxis` clamps to zero and the arm simply reads as
        // fully straight rather than producing a NaN.
        let alongAxis = (reach * reach + upperArm * upperArm - forearm * forearm) / (2 * reach)
        let offAxis = (upperArm * upperArm - alongAxis * alongAxis).squareRoot()
        let offAxisDistance = offAxis.isFinite ? max(0, offAxis) : 0

        // Strip the along-axis component so the pole becomes a pure perpendicular.
        let projected = poleDirection - axis * simd_dot(poleDirection, axis)
        let projectedLength = simd_length(projected)

        let perpendicular: SIMD3<Float>
        if projectedLength > 1e-4, projected.isFinite {
            perpendicular = projected / projectedLength
        } else {
            // The pole points almost exactly along the arm, so it selects no point on the
            // circle. Any perpendicular will do; build one from whichever world axis is least
            // parallel to the arm to avoid a second degeneracy.
            let leastParallel: SIMD3<Float> = abs(axis.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
            perpendicular = simd_normalize(simd_cross(axis, leastParallel))
        }

        return shoulder + axis * alongAxis + perpendicular * offAxisDistance
    }

    // MARK: Normalization

    /// Converts a world-space arm pose into the dimensionless space the scorer compares in.
    ///
    /// Two things happen here, and both are needed for the comparison to mean anything:
    /// 1. Re-origin onto the punching shoulder, so the score does not change when the user
    ///    walks across the room or turns to face a different wall.
    /// 2. Divide by arm reach, so users of different sizes produce comparable numbers.
    func normalize(
        pose: ArmPose,
        guardHand: SIMD3<Float>?,
        frame: BodyFrame,
        startTime: TimeInterval
    ) -> MotionSample {
        let reach = max(measurements.armReach, 1e-3)
        let shoulderBody = frame.toBody(pose.shoulder)

        /// World → body → shoulder-relative → scale-free.
        func normalized(_ world: SIMD3<Float>) -> SIMD3<Float> {
            (frame.toBody(world) - shoulderBody) / reach
        }

        // The guard hand is scored against the *head*, not the shoulder: the question being
        // asked is "is the spare fist protecting the chin?", which is a head-relative question.
        let normalizedGuard = guardHand.map { world in
            (frame.toBody(world) - frame.toBody(frame.headPosition)) / reach
        }

        return MotionSample(
            time: pose.timestamp - startTime,
            fist: normalized(pose.fist),
            elbow: normalized(pose.elbow),
            guardHand: normalizedGuard,
            isTracked: pose.isTracked
        )
    }

    /// Inverse of `normalize`: normalized shoulder-relative coordinates back into world space.
    ///
    /// This is what turns stored reference-punch data into something renderable — it is how the
    /// ghost arm knows where to put itself on *this* user's body.
    ///
    /// Derivation: `normalize` computes `n = (body(p) − body(shoulder)) / reach`. Rearranging,
    /// `body(p) = body(shoulder) + n · reach`, and since `toWorld` is affine that is just the
    /// world shoulder plus the *rotated* offset — no translation term, hence
    /// `directionToWorld` rather than `toWorld` on the right-hand side.
    func denormalize(
        _ normalized: SIMD3<Float>,
        side: BodySide,
        frame: BodyFrame
    ) -> SIMD3<Float> {
        let shoulder = frame.shoulder(side, measurements: measurements)
        return shoulder + frame.directionToWorld(normalized * measurements.armReach)
    }
}

/// One frame of a punch, in normalized space. The unit the recorder collects and the scorer
/// compares. See the coordinate-space note at the top of this file for what the axes mean.
nonisolated struct MotionSample: Sendable, Codable, Equatable {
    /// Seconds since the attempt began.
    var time: TimeInterval
    /// Punching fist, relative to the punching shoulder, in arm-reach units.
    /// Roughly: +X out to the side, +Y up, +Z forward. A full extension reaches ~1.0 in +Z.
    var fist: SIMD3<Float>
    /// Punching elbow, same frame as `fist`.
    var elbow: SIMD3<Float>
    /// Non-punching fist relative to the head. `nil` when that hand is not tracked.
    var guardHand: SIMD3<Float>?
    /// False when interpolated across a tracking dropout.
    var isTracked: Bool

    /// How far the fist is from the shoulder, in arm-reach units. `1.0` is full extension.
    var reachFraction: Float {
        simd_length(fist)
    }
}
