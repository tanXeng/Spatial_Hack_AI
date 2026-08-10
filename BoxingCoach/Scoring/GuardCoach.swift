import Foundation
import simd

/// Live guard coaching — not scored. Pauses drills until the non-punching hand returns.
enum GuardCoach {
    static let waitMessage = "Bring your guard back up — we're waiting"
    static let allowedDrift: Float = 0.18
    static let minimumPunchTravel: Float = 0.04

    /// Identifies the striking hand from fresh outward travel rather than whichever fist happens
    /// to be closest to the target. Proximity alone lets a lowered guard masquerade as the punch.
    static func punchingSide(
        current: [BodySide: SIMD3<Float>],
        starts: [BodySide: SIMD3<Float>],
        target: SIMD3<Float>,
        minimumTravel: Float = minimumPunchTravel
    ) -> BodySide? {
        guard target.isFinite, minimumTravel.isFinite, minimumTravel > 0 else { return nil }

        return [BodySide.left, .right]
            .compactMap { side -> (BodySide, Float)? in
                guard let start = starts[side], let fist = current[side],
                      start.isFinite, fist.isFinite else { return nil }
                let targetVector = target - start
                let targetDistance = simd_length(targetVector)
                guard targetDistance > 1e-4 else { return nil }
                let projectedTravel = simd_dot(fist - start, targetVector / targetDistance)
                guard projectedTravel >= minimumTravel else { return nil }
                return (side, projectedTravel)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Compares with the guard captured from this boxer at the start of the current round. This
    /// avoids imposing an average-adult cheek position on different builds and stances.
    static func isGuardUp(
        guardFistBody: SIMD3<Float>?,
        capturedGuardBody: SIMD3<Float>,
        allowedDrift: Float = GuardCoach.allowedDrift
    ) -> Bool? {
        guard let guardFistBody,
              guardFistBody.isFinite,
              capturedGuardBody.isFinite,
              allowedDrift.isFinite,
              allowedDrift > 0
        else { return nil }
        return simd_distance(guardFistBody, capturedGuardBody) <= allowedDrift
    }

    /// Aura Punch has an authored, anatomy-normalized guard pose rather than a round capture.
    /// Keep that semantic separate from Reactive Strike's personalized captured-guard check.
    static func isGuardUp(
        guardFistWorld: SIMD3<Float>?,
        frame: BodyFrame,
        measurements: BodyMeasurements,
        guardSide: BodySide,
        dropThreshold: Float = 0.46
    ) -> Bool? {
        guard let guardFistWorld else { return nil }
        let reach = max(measurements.armReach, 1e-3)
        let normalized = (frame.toBody(guardFistWorld) - frame.toBody(frame.headPosition)) / reach
        let expected = SIMD3<Float>(guardSide.lateralSign * 0.18, -0.15, 0.23)
        return simd_distance(normalized, expected) <= dropThreshold
    }
}
