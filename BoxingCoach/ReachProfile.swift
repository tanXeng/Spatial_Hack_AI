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

    /// How far back from full extension a calibrated target may spawn, expressed as a fraction
    /// of measured reach. A value of 0.10 keeps the entire spawn band in the final 10%.
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
    static let minimumForwardSpawn: Float = 0.30

    /// Anchors the far edge to comfortable measured reach and keeps every target in the final
    /// `forwardBandFraction` of that reach. Lateral and vertical bounds are intentionally not
    /// scaled: they describe the authored target volume, not arm length.
    func calibrated(measuredForwardReach: Float) -> ReachProfile {
        let usableReach = min(max(measuredForwardReach, 0.35), 0.95)
        let band = min(max(forwardBandFraction, 0.01), 0.5)

        var result = self
        result.forwardMax = usableReach
        result.forwardMin = max(usableReach * (1 - band), Self.minimumForwardSpawn)
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

/// One accepted extension sample, tagged with its tracking timestamp.
nonisolated struct ReachSample: Sendable, Equatable {
    var forward: Float
    var time: TimeInterval
}

/// Pure calibration rules shared by the live session and its unit tests.
nonisolated enum ReachCalibration {
    static let minimumExtensionFromGuard: Float = 0.18
    static let plausibleForwardRange: ClosedRange<Float> = 0.35...1.10
    static let minimumStableSampleCount = 8
    static let plateauTolerance: Float = 0.015
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

    /// Returns the median reach of a held near-maximum plateau. This avoids finalizing while the
    /// arm is still travelling outward, which made the former timed-percentile approach measure
    /// the ramp rather than comfortable full extension.
    static func settledForwardReach(from samples: [ReachSample]) -> Float? {
        let valid = samples.filter {
            $0.forward.isFinite
                && $0.time.isFinite
                && plausibleForwardRange.contains($0.forward)
        }
        guard valid.count >= minimumStableSampleCount,
              let peak = valid.map(\.forward).max()
        else { return nil }

        let plateauFloor = peak - plateauTolerance
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
              bestDuration >= plateauDuration
        else { return nil }

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
