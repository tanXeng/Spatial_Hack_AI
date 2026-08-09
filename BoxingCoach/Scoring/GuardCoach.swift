import Foundation
import simd

/// Live guard coaching — not scored. Pauses drills until the non-punching hand returns.
enum GuardCoach {
    static let waitMessage = "Bring your guard back up — we're waiting"

    /// Head-relative guard pose for the non-punching hand (matches `ReferencePunchLibrary`).
    static func expectedGuardPosition(inwardSign: Float) -> SIMD3<Float> {
        SIMD3(inwardSign * -0.18, -0.15, 0.23)
    }

    /// `true` = guard up, `false` = dropped, `nil` = not visible (do not pause).
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
        let inward = -guardSide.lateralSign
        let expected = expectedGuardPosition(inwardSign: inward)
        return simd_distance(normalized, expected) <= dropThreshold
    }
}
