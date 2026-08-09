import Foundation
import simd

/// Normal-round recovery gate for one current tracking identity.
///
/// Competition deliberately uses its separate four-sample gate. This gate releases normal
/// combinations on exactly the third consecutive fresh, closed bilateral guard pair.
nonisolated struct NormalCombinationGuardRecoveryGate: Sendable {
    nonisolated struct Sample: Sendable, Equatable {
        let providerGeneration: UInt64
        let continuityEpoch: UInt64
        let pairTimestamp: TimeInterval?
        let observationsFresh: Bool
        let freshClosedAndGuarded: Bool

        nonisolated init(
            providerGeneration: UInt64,
            continuityEpoch: UInt64,
            pairTimestamp: TimeInterval?,
            observationsFresh: Bool,
            freshClosedAndGuarded: Bool
        ) {
            self.providerGeneration = providerGeneration
            self.continuityEpoch = continuityEpoch
            self.pairTimestamp = pairTimestamp
            self.observationsFresh = observationsFresh
            self.freshClosedAndGuarded = freshClosedAndGuarded
        }
    }

    static let requiredStableSamples = 3

    private var providerGeneration: UInt64?
    private var continuityEpoch: UInt64?
    private var lastPairTimestamp: TimeInterval?
    private(set) var consecutiveStableSamples = 0

    nonisolated mutating func observe(_ sample: Sample) -> Bool {
        let identityChanged = providerGeneration != sample.providerGeneration
            || continuityEpoch != sample.continuityEpoch
        if identityChanged {
            providerGeneration = sample.providerGeneration
            continuityEpoch = sample.continuityEpoch
            lastPairTimestamp = nil
            consecutiveStableSamples = 0
        }

        guard sample.observationsFresh,
              let pairTimestamp = sample.pairTimestamp,
              pairTimestamp.isFinite,
              pairTimestamp >= 0
        else {
            consecutiveStableSamples = 0
            return false
        }

        // Guard loss is a state transition even when asynchronous hand updates leave the older
        // half of the pair (and therefore its minimum timestamp) unchanged.
        guard sample.freshClosedAndGuarded else {
            consecutiveStableSamples = 0
            return false
        }

        if let lastPairTimestamp {
            guard pairTimestamp >= lastPairTimestamp else {
                consecutiveStableSamples = 0
                return false
            }
            // Polling the same still-fresh anchors is not a new pair and cannot advance or break
            // the streak. Once those observations age out, `observationsFresh` resets it above.
            guard pairTimestamp > lastPairTimestamp else { return false }
        }
        lastPairTimestamp = pairTimestamp
        consecutiveStableSamples += 1
        return consecutiveStableSamples >= Self.requiredStableSamples
    }
}

/// Routes tracking interruptions before a combination frame can reach punch admission.
///
/// This policy never scores. Ranked sessions retain their recovery presentation, while normal
/// sessions discard the partial chain and reacquire a fresh bilateral guard before retrying the
/// same authored target.
nonisolated enum CombinationTrackingInterruptionPolicy {
    nonisolated struct Input: Sendable, Equatable {
        let requiredHandAvailable: Bool
        let otherHandAvailable: Bool
        let devicePoseAvailable: Bool
        let expectedGeneration: UInt64
        let currentGeneration: UInt64
        let expectedContinuityEpoch: UInt64
        let currentContinuityEpoch: UInt64

        nonisolated init(
            requiredHandAvailable: Bool,
            otherHandAvailable: Bool,
            devicePoseAvailable: Bool,
            expectedGeneration: UInt64,
            currentGeneration: UInt64,
            expectedContinuityEpoch: UInt64,
            currentContinuityEpoch: UInt64
        ) {
            self.requiredHandAvailable = requiredHandAvailable
            self.otherHandAvailable = otherHandAvailable
            self.devicePoseAvailable = devicePoseAvailable
            self.expectedGeneration = expectedGeneration
            self.currentGeneration = currentGeneration
            self.expectedContinuityEpoch = expectedContinuityEpoch
            self.currentContinuityEpoch = currentContinuityEpoch
        }
    }

    nonisolated enum Decision: Sendable, Equatable {
        case continueAttempt
        case discardAndRetry
        case competitionRecovery

        nonisolated var pausesForFreshGuard: Bool {
            self != .continueAttempt
        }

        nonisolated var recordsMetric: Bool { false }
        nonisolated var flashesTarget: Bool { false }
        nonisolated var advancesStep: Bool { false }
    }

    nonisolated static func decision(
        input: Input,
        capturesCompetitionEvidence: Bool
    ) -> Decision {
        let isCoherent = input.requiredHandAvailable
            && input.otherHandAvailable
            && input.devicePoseAvailable
            && input.currentGeneration == input.expectedGeneration
            && input.currentContinuityEpoch == input.expectedContinuityEpoch
        guard !isCoherent else { return .continueAttempt }
        return capturesCompetitionEvidence ? .competitionRecovery : .discardAndRetry
    }
}

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
