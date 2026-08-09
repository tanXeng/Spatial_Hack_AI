import Foundation
import simd

/// Reactive Strike modes from the project brief.
enum ReactiveStrikeMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case air
    case combination

    var id: String { rawValue }

    var title: String {
        switch self {
        case .air: return "Air Mode"
        case .combination: return "Combination Mode"
        }
    }

    var subtitle: String {
        switch self {
        case .air: return "Targets float in front of you"
        case .combination: return "Throw a stance-aware punch sequence"
        }
    }

    var reachProfile: ReachProfile {
        switch self {
        case .air, .combination: return .air
        }
    }
}

/// Body-relative spawn bounds for Reactive Strike targets.
///
/// Positions are expressed in the same body frame as Aura Punch: +X is the user's right,
/// +Y is relative to the shoulder line, and +Z points where the user is facing. Keeping the
/// bounds out of world space means turning or moving in the room does not move the drill to a
/// different wall.
struct ReachProfile: Sendable, Equatable {
    /// Forward distance from the estimated shoulder-line center (meters).
    var forwardMin: Float
    var forwardMax: Float
    /// Lateral offset (meters). Negative = left, positive = right.
    var lateralMin: Float
    var lateralMax: Float
    /// Vertical offset from the estimated shoulder line (meters).
    var verticalMin: Float
    var verticalMax: Float

    /// How far back from full extension a calibrated target may spawn, as a fraction of measured
    /// reach. 0.10 means the whole spawn band sits in the last 10% of the user's reach.
    ///
    /// A fraction rather than a fixed distance so the band means the same thing to a long-armed
    /// and a short-armed user: 10% of 0.50 m is 5 cm, 10% of 0.80 m is 8 cm, and both land every
    /// target at 90–100% of that person's extension.
    var forwardBandFraction: Float = 0.10

    static let `default` = air

    /// Wider floating volume in front of the user.
    static let air = ReachProfile(
        forwardMin: 0.62,
        forwardMax: 0.75,
        lateralMin: -0.35,
        lateralMax: 0.35,
        verticalMin: -0.22,
        verticalMax: 0.24,
        forwardBandFraction: 0.10
    )

    /// Returns a random target in body space. Convert it through the current `BodyFrame` before
    /// handing it to RealityKit.
    func randomBodyTargetPosition() -> SIMD3<Float> {
        let forward = Float.random(in: forwardMin...forwardMax)
        let lateral = Float.random(in: lateralMin...lateralMax)
        let vertical = Float.random(in: verticalMin...verticalMax)
        return SIMD3(lateral, vertical, forward)
    }

    /// Nothing may spawn closer than this to the shoulder line, whatever the measurement says.
    /// A target inside this radius is on the user's chest, not in front of it.
    static let minimumForwardSpawn: Float = 0.30

    /// Anchors this exact profile to a measured forward reach while preserving its shape.
    ///
    /// **Every target lands in the last `forwardBandFraction` of the user's reach**, so the drill
    /// always demands something close to full extension — which is the technique being coached. A
    /// wide forward band let targets spawn well inside the user's range, where a half-extended arm
    /// scores a hit.
    ///
    /// The authored `forwardMin`/`forwardMax` are only the uncalibrated fallback; once a
    /// measurement exists the band is derived from it, not scaled from those literals. Scaling them
    /// proportionally (`usableReach / forwardMax`) is what previously shrank the near edge faster
    /// than the far edge and collapsed Air's band to roughly two-thirds of true reach.
    func calibrated(measuredForwardReach: Float) -> ReachProfile {
        let usableReach = min(max(measuredForwardReach, 0.35), 0.95)
        let band = min(max(forwardBandFraction, 0.01), 0.5)

        var result = self
        result.forwardMax = usableReach
        result.forwardMin = max(usableReach * (1 - band), ReachProfile.minimumForwardSpawn)
        // Lateral bounds are deliberately left alone. How wide a user can punch has no dimensional
        // relationship to how far forward they reach, so scaling it by the forward ratio only
        // narrowed the volume for no reason.
        return result
    }

    /// Moves the near edge beyond the freshly captured guard so a raised, stationary hand cannot
    /// overlap a newly spawned target. Returns `nil` when the measured reach leaves no usable
    /// space beyond guard; the session then asks the user to recalibrate rather than spawning an
    /// unreachable or auto-hit target.
    func placingTargetsBeyondGuard(
        maximumGuardForward: Float,
        hitRadius: Float,
        clearance: Float = 0.02
    ) -> ReachProfile? {
        guard maximumGuardForward.isFinite,
              hitRadius.isFinite,
              clearance.isFinite,
              hitRadius > 0,
              clearance >= 0
        else { return nil }

        let safeMinimum = maximumGuardForward + hitRadius + clearance
        guard safeMinimum < forwardMax else { return nil }

        var result = self
        result.forwardMin = max(forwardMin, safeMinimum)
        return result
    }
}

/// One accepted extension sample, tagged with the tracking timestamp it was observed at.
struct ReachSample: Sendable, Equatable {
    var forward: Float
    var time: TimeInterval
}

/// Pure calibration rules shared by the live session and its unit tests.
enum ReachCalibration {
    static let minimumExtensionFromGuard: Float = 0.18
    static let plausibleForwardRange: ClosedRange<Float> = 0.35...1.10
    static let minimumStableSampleCount = 8

    /// How close to the peak a sample must sit to count as part of the same held extension.
    static let plateauTolerance: Float = 0.015
    /// How long that hold must last before it is trusted as real extension rather than transit.
    static let plateauDuration: TimeInterval = 0.30

    /// A sample is accepted only after the fist has actually travelled outward from guard. This
    /// prevents an already-extended, stationary hand from auto-completing calibration.
    static func candidateForwardReach(
        guardPosition: SIMD3<Float>,
        fistPosition: SIMD3<Float>
    ) -> Float? {
        guard guardPosition.isFinite, fistPosition.isFinite else { return nil }
        let outwardTravel = fistPosition.z - guardPosition.z
        guard outwardTravel >= minimumExtensionFromGuard,
              plausibleForwardRange.contains(fistPosition.z) else { return nil }
        return fistPosition.z
    }

    /// A high-but-robust estimate of a held extension. The 75th percentile follows the user's
    /// settled near-maximum reach without allowing one finite tracking spike to set every target
    /// for the rest of the session.
    static func robustForwardReach(from samples: [Float]) -> Float? {
        let valid = samples
            .filter { $0.isFinite && plausibleForwardRange.contains($0) }
            .sorted()
        guard valid.count >= minimumStableSampleCount else { return nil }
        let index = Int((Double(valid.count - 1) * 0.75).rounded(.down))
        return valid[index]
    }

    /// The reach the user actually **held**, rather than one they happened to be passing through.
    ///
    /// The old rule finalized 0.25 s after the fist first cleared guard and then took the 75th
    /// percentile of everything captured. Both halves measured the outbound ramp: a punch needs
    /// ~0.3–0.5 s to reach lockout, so the window closed mid-flight and the percentile then landed
    /// somewhere inside that already-truncated travel. Targets spawned far too close as a result.
    ///
    /// Instead: find the peak, collect the runs of samples that stay within `plateauTolerance` of
    /// it, and require the longest such run to span `plateauDuration`. A stationary arm at full
    /// extension produces that signature; an arm still travelling does not.
    static func settledForwardReach(from samples: [ReachSample]) -> Float? {
        let valid = samples.filter {
            $0.forward.isFinite && $0.time.isFinite && plausibleForwardRange.contains($0.forward)
        }
        guard valid.count >= minimumStableSampleCount,
              let peak = valid.map(\.forward).max() else { return nil }

        let plateauFloor = peak - plateauTolerance

        // Scan every contiguous run near the peak, not just the first. A brief early touch that
        // then drops away must not hide the real hold that follows it.
        var best: ArraySlice<ReachSample>?
        var bestDuration: TimeInterval = -1
        var index = valid.startIndex

        while index < valid.endIndex {
            guard valid[index].forward >= plateauFloor else {
                index += 1
                continue
            }

            var end = index
            while end + 1 < valid.endIndex, valid[end + 1].forward >= plateauFloor {
                end += 1
            }

            let run = valid[index...end]
            if let first = run.first, let last = run.last {
                let duration = last.time - first.time
                if duration > bestDuration {
                    bestDuration = duration
                    best = run
                }
            }
            index = end + 1
        }

        guard let plateau = best,
              plateau.count >= minimumStableSampleCount,
              bestDuration >= plateauDuration else { return nil }

        // Median of the hold. Taking the peak itself would re-admit exactly the single-frame
        // tracking spike that `robustForwardReach` was written to reject.
        let sorted = plateau.map(\.forward).sorted()
        return sorted[sorted.count / 2]
    }

    /// Uses the shorter of two successfully measured arms. Reactive targets are intentionally
    /// reachable by either hand; Combination Mode then remains accessible when one arm has a
    /// smaller comfortable range than the other.
    static func conservativeBilateralReach(
        _ reaches: [BodySide: Float]
    ) -> Float? {
        guard let left = reaches[.left],
              let right = reaches[.right],
              plausibleForwardRange.contains(left),
              plausibleForwardRange.contains(right)
        else { return nil }
        return min(left, right)
    }
}
