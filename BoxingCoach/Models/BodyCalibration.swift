import Foundation
import simd

/// The user's measured body, captured once per launch by Anthropometry and shared by every drill.
///
/// This is the concrete form of the seam described on `BodyMeasurements`. Reactive Strike reads
/// `measuredReach` to size its spawn volume; Aura Punch reads `measurements` so its scoring stops
/// normalizing everyone against `averageAdult`.
///
/// Deliberately in-memory only. A measurement that outlived the launch would silently apply one
/// person's arms to whoever put the headset on next — on a shared demo device that is the common
/// case, not the edge case.
@Observable
@MainActor
final class BodyCalibration {
    private(set) var reaches: [BodySide: Float] = [:]

    /// Guard fist positions in body space, captured alongside the reach. Combination validation
    /// needs these to require each punch to leave guard and return.
    private(set) var guardPositionsBody: [BodySide: SIMD3<Float>] = [:]

    /// How far the calibrated arm chain may deviate from average adult proportions.
    ///
    /// A user who never quite held full extension, or one whose tracking dropped mid-hold, would
    /// otherwise hand the IK solver an arm short enough to visibly detach the ghost silhouette
    /// from their real limb. Clamping keeps a bad measurement merely inaccurate, not broken.
    private static let chainScaleRange: ClosedRange<Float> = 0.80...1.25

    var measuredReach: Float? {
        ReachCalibration.conservativeBilateralReach(reaches)
    }

    var isCalibrated: Bool { measuredReach != nil }

    /// Feeds the measured reach back into the anthropometry every downstream consumer already
    /// reads.
    ///
    /// Only the arm chain is measured, so the remaining proportions stay at their average adult
    /// values and the chain is rescaled to hit the measured total. Note the approximation: the
    /// measurement is forward fist distance from the **shoulder-line center**, whereas `armReach`
    /// is shoulder-joint to fist. For a straight punch these are close, and both are far closer to
    /// the user than assuming an average adult outright.
    var measurements: BodyMeasurements {
        let reference = BodyMeasurements.averageAdult
        guard let measuredReach, measuredReach > 0, reference.armReach > 0 else { return reference }

        let scale = min(
            max(measuredReach / reference.armReach, Self.chainScaleRange.lowerBound),
            Self.chainScaleRange.upperBound
        )

        return BodyMeasurements(
            height: reference.height,
            shoulderWidth: reference.shoulderWidth,
            upperArmLength: reference.upperArmLength * scale,
            forearmLength: reference.forearmLength * scale,
            wristToFistLength: reference.wristToFistLength * scale,
            eyeToShoulderDrop: reference.eyeToShoulderDrop,
            eyeToShoulderSetback: reference.eyeToShoulderSetback
        )
    }

    func store(reaches: [BodySide: Float], guardPositionsBody: [BodySide: SIMD3<Float>]) {
        self.reaches = reaches
        self.guardPositionsBody = guardPositionsBody
    }

    func invalidate() {
        reaches = [:]
        guardPositionsBody = [:]
    }
}
