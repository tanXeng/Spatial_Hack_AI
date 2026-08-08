import Foundation
import simd

/// A reference punch: the "correct" motion the user is trying to match.
///
/// Stored entirely in **normalized space** (shoulder-relative, arm-reach units — see the header
/// of `ArmPoseSolver.swift`), which is what lets one authored trajectory drive the ghost arm for
/// users of any size.
struct ReferencePunch: Sendable {
    let techniqueID: String
    let side: BodySide
    let samples: [MotionSample]

    var duration: TimeInterval {
        samples.last?.time ?? 0
    }

    /// Reach at the moment of full extension. The follow-along guide holds the ghost here, and
    /// the user's own reach is judged against it rather than against a hardcoded 1.0 — a hook
    /// peaks near 0.70 by design, so an absolute threshold would be unreachable for it.
    var peakReach: Float {
        samples.map(\.reachFraction).max() ?? 1
    }

    /// Time of full extension — the boundary between the outward and return halves of the punch.
    var peakTime: TimeInterval {
        guard let peak = samples.max(by: { $0.reachFraction < $1.reachFraction }) else { return 0 }
        return peak.time
    }

    /// Interpolated pose at an arbitrary time. Used to drive the demo silhouette, which renders
    /// at the display's refresh rate rather than at the trajectory's authoring rate.
    func sample(at time: TimeInterval) -> MotionSample? {
        guard !samples.isEmpty else { return nil }
        if time <= samples[0].time { return samples[0] }
        guard let last = samples.last else { return nil }
        if time >= last.time { return last }

        // Trajectories are short (<1 s at 60 Hz, so ~40 samples). A linear scan is cheaper than
        // a binary search at this size and keeps the intent obvious.
        for index in 1..<samples.count where samples[index].time >= time {
            let previous = samples[index - 1]
            let next = samples[index]
            let span = next.time - previous.time
            let t = span > 0 ? Float((time - previous.time) / span) : 0
            return MotionSample(
                time: time,
                fist: simd_mix(previous.fist, next.fist, SIMD3(repeating: t)),
                elbow: simd_mix(previous.elbow, next.elbow, SIMD3(repeating: t)),
                guardHand: previous.guardHand.flatMap { a in
                    next.guardHand.map { b in simd_mix(a, b, SIMD3(repeating: t)) }
                },
                isTracked: true
            )
        }
        return last
    }
}

/// One authored pose in a reference trajectory.
///
/// Only the **fist** path and an elbow *pole hint* are authored. The elbow itself is solved with
/// the same `ArmPoseSolver.twoBoneElbow` used on live tracking data, which guarantees the
/// reference obeys the user's bone lengths — and means the elbow-alignment sub-metric compares
/// two punches rather than two different solvers.
private struct ReferenceKeyframe {
    /// Seconds from the start of the punch.
    var time: TimeInterval
    /// Punching fist, shoulder-relative, arm-reach units. +X user's right, +Y up, +Z forward.
    var fist: SIMD3<Float>
    /// Rough direction the elbow bends. Perpendicularized by the IK; magnitude is ignored.
    var elbowPole: SIMD3<Float>
    /// Non-punching fist, head-relative, arm-reach units.
    var guardHand: SIMD3<Float>
}

/// Builds reference trajectories for each technique.
///
/// **Authoring note:** these are hand-authored
/// from boxing fundamentals rather than recorded, so the pipeline works with no capture session.
/// `recordedPunch(for:)` is the seam for swapping in real captured data later; when a JSON file
/// exists in the bundle it wins over the synthetic version automatically, so recording a team
/// member becomes a drop-in upgrade rather than a code change.
enum ReferencePunchLibrary {
    /// Playback/authoring rate. Matches the rate the recorder captures at, so DTW is comparing
    /// sequences of similar density.
    static let sampleRate: Double = 60

    /// - Parameter side: Overrides which arm the trajectory is mirrored onto. Scoring passes the
    ///   hand the user *actually* threw with, so a jab thrown off the wrong arm is still compared
    ///   against a correctly mirrored jab — the hand fault is then reported as a hand fault
    ///   instead of being smeared across every geometry sub-metric.
    static func punch(
        for technique: Technique,
        stance: Stance,
        measurements: BodyMeasurements,
        side overrideSide: BodySide? = nil
    ) -> ReferencePunch {
        let side = overrideSide ?? technique.hand.side(for: stance)

        if let recorded = recordedPunch(for: technique, side: side) {
            return recorded
        }

        let keyframes = keyframes(for: technique, side: side, measurements: measurements)
        return ReferencePunch(
            techniqueID: technique.id,
            side: side,
            samples: resample(keyframes, side: side, measurements: measurements)
        )
    }

    // MARK: - Authored trajectories
    //
    // Shared conventions across every technique below:
    //   • `lateral` is the sign of the *punching* side (+1 right, −1 left). Multiplying by it
    //     mirrors a trajectory authored for one side onto the other, so orthodox and southpaw
    //     both work from one set of numbers.
    //   • `inward` points from the punching shoulder toward the body's midline.
    //   • A fist magnitude of 1.0 would be a fully locked-out arm. Real punches land at ~0.95
    //     for straights and ~0.70 for hooks — nobody hyperextends, and scoring against 1.0
    //     would mark a technically correct punch down.

    private static func keyframes(
        for technique: Technique,
        side: BodySide,
        measurements: BodyMeasurements
    ) -> [ReferenceKeyframe] {
        let lateral = side.lateralSign
        let inward = -lateral

        // Hands-up guard, shoulder-relative: fist at cheek height, forward of the shoulder and
        // tucked toward the midline. Every punch starts and ends here.
        let guardFist = SIMD3<Float>(inward * 0.15, 0.18, 0.30)

        // The *other* hand, head-relative — the one the guard sub-metric watches. It should
        // barely move during a correct punch, which is why it is near-constant below.
        let guardHand = SIMD3<Float>(inward * -0.18, -0.15, 0.23)

        // Elbow hanging under the arm: the default for straight punches.
        let elbowDown = SIMD3<Float>(lateral * 0.20, -1.0, -0.15)

        switch technique.id {
        case "jab":
            // Straight, fast, minimal wind-up. Out and back along the same line — the path
            // sub-metric penalizes any loop, so the reference must itself be dead straight.
            let extended = SIMD3<Float>(inward * 0.10, 0.15, 0.95)
            return [
                ReferenceKeyframe(time: 0.00, fist: guardFist, elbowPole: elbowDown, guardHand: guardHand),
                ReferenceKeyframe(time: 0.20, fist: extended, elbowPole: elbowDown, guardHand: guardHand),
                ReferenceKeyframe(time: 0.28, fist: extended, elbowPole: elbowDown, guardHand: guardHand),
                ReferenceKeyframe(time: 0.50, fist: guardFist, elbowPole: elbowDown, guardHand: guardHand)
            ]

        case "cross":
            // Rear hand, slightly longer to land and crossing further past the midline than the
            // jab because the rear shoulder rotates through the shot.
            let extended = SIMD3<Float>(inward * 0.18, 0.13, 0.96)
            return [
                ReferenceKeyframe(time: 0.00, fist: guardFist, elbowPole: elbowDown, guardHand: guardHand),
                ReferenceKeyframe(time: 0.24, fist: extended, elbowPole: elbowDown, guardHand: guardHand),
                ReferenceKeyframe(time: 0.34, fist: extended, elbowPole: elbowDown, guardHand: guardHand),
                ReferenceKeyframe(time: 0.60, fist: guardFist, elbowPole: elbowDown, guardHand: guardHand)
            ]

        case "hook":
            // Tight horizontal arc at chin height: elbow flares to the side at shoulder level
            // while the fist sweeps forward across the face. No outward wind-up past the shoulder
            // (that read as looping over the head on device) and no skyward elbow pole.
            let elbowFlared = SIMD3<Float>(lateral * 0.70, 0.08, -0.08)
            let elbowRising = SIMD3<Float>(lateral * 0.45, 0.02, -0.12)
            let hookPeak = SIMD3<Float>(inward * 0.20, 0.20, 0.64)
            return [
                ReferenceKeyframe(time: 0.00, fist: guardFist, elbowPole: elbowDown, guardHand: guardHand),
                ReferenceKeyframe(
                    time: 0.10,
                    fist: SIMD3(guardFist.x + inward * 0.02, 0.19, 0.38),
                    elbowPole: elbowRising,
                    guardHand: guardHand
                ),
                ReferenceKeyframe(time: 0.22, fist: hookPeak, elbowPole: elbowFlared, guardHand: guardHand),
                ReferenceKeyframe(time: 0.32, fist: hookPeak, elbowPole: elbowFlared, guardHand: guardHand),
                ReferenceKeyframe(time: 0.58, fist: guardFist, elbowPole: elbowDown, guardHand: guardHand)
            ]

        case "uppercut", "left-uppercut", "right-uppercut":
            // Small dip, then drive upward. The elbow stays pinned near the ribs throughout —
            // hence a pole pointing down and *inward* rather than down and outward. The peak X
            // exactly cancels this side's half-shoulder offset, so both hands land on the same
            // body centerline instead of remaining displaced left or right.
            let elbowTucked = SIMD3<Float>(inward * 0.30, -1.0, -0.20)
            let centerlineX = inward * (measurements.shoulderWidth * 0.5 / max(measurements.armReach, 1e-3))
            let dipX = guardFist.x + (centerlineX - guardFist.x) * 0.55
            return [
                ReferenceKeyframe(time: 0.00, fist: guardFist, elbowPole: elbowTucked, guardHand: guardHand),
                ReferenceKeyframe(time: 0.14, fist: SIMD3(dipX, -0.08, 0.32), elbowPole: elbowTucked, guardHand: guardHand),
                ReferenceKeyframe(time: 0.34, fist: SIMD3(centerlineX, 0.48, 0.56), elbowPole: elbowTucked, guardHand: guardHand),
                ReferenceKeyframe(time: 0.44, fist: SIMD3(centerlineX, 0.46, 0.54), elbowPole: elbowTucked, guardHand: guardHand),
                ReferenceKeyframe(time: 0.70, fist: guardFist, elbowPole: elbowTucked, guardHand: guardHand)
            ]

        default:
            return [
                ReferenceKeyframe(time: 0.00, fist: guardFist, elbowPole: elbowDown, guardHand: guardHand),
                ReferenceKeyframe(time: 0.50, fist: guardFist, elbowPole: elbowDown, guardHand: guardHand)
            ]
        }
    }

    // MARK: - Resampling

    /// Expands keyframes into a fixed-rate sample stream, solving the elbow at each step.
    private static func resample(
        _ keyframes: [ReferenceKeyframe],
        side: BodySide,
        measurements: BodyMeasurements
    ) -> [MotionSample] {
        guard let last = keyframes.last, keyframes.count > 1 else { return [] }

        // Bone lengths expressed in arm-reach units, since the trajectory is normalized.
        //
        // The forearm bone absorbs the wrist→fist length because the authored path tracks the
        // *fist*, not the wrist. During a punch the hand is essentially collinear with the
        // forearm, so folding them into one bone moves the solved elbow by a negligible amount
        // while keeping the authoring simple.
        let reach = max(measurements.armReach, 1e-3)
        let upperArm = measurements.upperArmLength / reach
        let forearm = (measurements.forearmLength + measurements.wristToFistLength) / reach

        let step = 1.0 / sampleRate
        var samples: [MotionSample] = []
        var time: TimeInterval = 0

        while time <= last.time + 1e-6 {
            let (previous, next, t) = bracket(keyframes, at: time)

            // Ease the time parameter, not the path. Easing the position would bend the straight
            // line between two keyframes into a curve — which for a jab would mean the reference
            // itself looping, exactly the fault the path sub-metric exists to catch.
            let eased = smoothstep(t)

            let fist = simd_mix(previous.fist, next.fist, SIMD3(repeating: eased))
            let pole = simd_mix(previous.elbowPole, next.elbowPole, SIMD3(repeating: eased))
            let guardHand = simd_mix(previous.guardHand, next.guardHand, SIMD3(repeating: eased))

            let elbow = ArmPoseSolver.twoBoneElbow(
                shoulder: .zero,          // normalized space is shoulder-origined by definition
                wrist: fist,
                upperArm: upperArm,
                forearm: forearm,
                poleDirection: pole
            )

            samples.append(
                MotionSample(
                    time: time,
                    fist: fist,
                    elbow: elbow,
                    guardHand: guardHand,
                    isTracked: true
                )
            )
            time += step
        }

        return samples
    }

    /// Finds the keyframe pair surrounding `time` and the 0...1 position between them.
    private static func bracket(
        _ keyframes: [ReferenceKeyframe],
        at time: TimeInterval
    ) -> (ReferenceKeyframe, ReferenceKeyframe, Float) {
        for index in 1..<keyframes.count where keyframes[index].time >= time {
            let previous = keyframes[index - 1]
            let next = keyframes[index]
            let span = next.time - previous.time
            let t = span > 0 ? Float((time - previous.time) / span) : 0
            return (previous, next, min(max(t, 0), 1))
        }
        let last = keyframes[keyframes.count - 1]
        return (last, last, 1)
    }

    private static func smoothstep(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    // MARK: - Recorded data

    /// Loads a captured trajectory from the bundle, if one has been recorded for this technique.
    ///
    /// Nothing ships one today, so this always returns `nil` and the synthetic path is used.
    /// It exists so that recording a real boxer becomes an asset drop rather than a rewrite —
    /// export `[MotionSample]` as JSON to `ReferencePunches/<techniqueID>.json` and it takes over.
    private static func recordedPunch(for technique: Technique, side: BodySide) -> ReferencePunch? {
        guard let url = Bundle.main.url(
            forResource: technique.id,
            withExtension: "json",
            subdirectory: "ReferencePunches"
        ) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let samples = try JSONDecoder().decode([MotionSample].self, from: data)
            guard !samples.isEmpty else { return nil }
            return ReferencePunch(techniqueID: technique.id, side: side, samples: samples)
        } catch {
            // A malformed recording must not take the demo down — fall back to the synthetic one.
            return nil
        }
    }
}
