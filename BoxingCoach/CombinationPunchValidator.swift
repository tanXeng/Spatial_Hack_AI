import Foundation
import simd

/// Combination-specific adapter around the single transferable punch evidence reducer.
///
/// This wrapper resolves number-notation punch metadata. All temporal, hand-shape, motion,
/// contact, retraction, and coverage admission remains owned by `PunchEvidenceValidator`.
nonisolated struct CombinationPunchValidator: Sendable {
    typealias Phase = PunchEvidenceValidator.Phase
    typealias Event = PunchEvidenceValidator.Event

    static let guardRadius = PunchEvidenceValidator.guardRadius
    static let minimumOutwardTravel = PunchEvidenceValidator.minimumOutboundTravel
    static let minimumOutwardVelocity = PunchEvidenceValidator.minimumOutwardVelocity
    static let maximumSampleInterval = PunchEvidenceValidator.maximumSampleGap

    let target: CombinationTarget
    let stance: Stance
    let technique: Technique
    let requiredHand: BodySide
    let guardPosition: SIMD3<Float>
    let hitRadius: Float

    private var reducer: PunchEvidenceValidator

    var phase: Phase { reducer.phase }
    var isValidConfiguration: Bool {
        target.requiredHand == target.punch.requiredHand(for: stance)
            && Self.isFinite(target.position)
            && Self.isFinite(guardPosition)
            && hitRadius.isFinite
            && hitRadius > 0
            && simd_distance(target.position, guardPosition)
                > max(Self.guardRadius, Self.minimumOutwardTravel)
    }

    nonisolated init(
        target: CombinationTarget,
        stance: Stance,
        guardPosition: SIMD3<Float>,
        hitRadius: Float,
        generation: UInt64,
        continuityEpoch: UInt64
    ) {
        let technique = Self.technique(for: target.punch)
        self.target = target
        self.stance = stance
        self.technique = technique
        requiredHand = target.requiredHand
        self.guardPosition = guardPosition
        self.hitRadius = hitRadius
        reducer = PunchEvidenceValidator(
            configuration: .init(
                technique: technique,
                stance: stance,
                requiredHand: target.requiredHand,
                guardPosition: guardPosition,
                targetPosition: target.position,
                targetRadius: hitRadius,
                generation: generation,
                continuityEpoch: continuityEpoch
            )
        )
    }

    nonisolated mutating func observe(_ frame: PunchEvidenceValidator.Frame) -> Event {
        guard isValidConfiguration else { return .invalid(.invalidConfiguration) }
        return reducer.observe(frame)
    }

    nonisolated mutating func complete(
        coverage: PunchEvidenceValidator.Coverage
    ) -> Event {
        guard isValidConfiguration else { return .invalid(.invalidConfiguration) }
        return reducer.complete(coverage: coverage)
    }

    nonisolated mutating func finish() -> Event {
        guard isValidConfiguration else { return .invalid(.invalidConfiguration) }
        return reducer.finish()
    }

    /// Pure geometry used only by calibration/recovery gates, never as punch admission.
    nonisolated static func isRetracted(
        fist: SIMD3<Float>,
        guardPosition: SIMD3<Float>,
        radius: Float
    ) -> Bool {
        guard isFinite(fist), isFinite(guardPosition), radius.isFinite, radius > 0 else {
            return false
        }
        let distance = simd_distance(fist, guardPosition)
        return distance.isFinite && distance <= radius
    }

    nonisolated private static func technique(for punch: PunchType) -> Technique {
        switch punch {
        case .jab:
            return .jab
        case .cross:
            return .cross
        case .leadHook, .rearHook:
            return .hook
        case .leadUppercut, .rearUppercut:
            return .uppercut
        }
    }

    nonisolated private static func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}
