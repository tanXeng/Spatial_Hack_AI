import Foundation
import simd

/// Pure state machine for validating one `CombinationTarget` in a consistent metric space.
///
/// The caller supplies the fist belonging to `target.requiredHand` separately from the other
/// fist, so this type never guesses hand identity from target proximity. A valid punch must:
///
/// 1. Put the required fist near guard.
/// 2. Move meaningfully out from guard with positive velocity toward the target.
/// 3. Contact the target with the required fist on a later sample.
///
/// Contact from the other physical hand is reported distinctly and never advances validation.
nonisolated struct CombinationPunchValidator: Sendable {
    nonisolated enum Phase: Sendable, Equatable {
        case waitingForGuard
        case trackingOutbound
        case armed
        case hit
    }

    /// Result of one frame. `waiting` covers both waiting for guard and accumulating enough
    /// outbound motion; inspect `phase` when the UI needs to distinguish those two states.
    nonisolated enum Event: Sendable, Equatable {
        case waiting
        case armed
        case wrongHand
        case hit
    }

    /// Motion thresholds shared by production and tests.
    static let guardRadius: Float = 0.14
    static let minimumOutwardTravel: Float = 0.10
    static let minimumOutwardVelocity: Float = 0.20
    static let minimumSampleInterval: TimeInterval = 0.0001
    static let maximumSampleInterval: TimeInterval = 0.20

    let target: CombinationTarget
    let guardPosition: SIMD3<Float>
    let hitRadius: Float

    private(set) var phase: Phase = .waitingForGuard
    var isValidConfiguration: Bool { hasValidConfiguration }

    private let outwardDirection: SIMD3<Float>?
    private let hasValidConfiguration: Bool
    private var previousRequiredFist: SIMD3<Float>?
    private var previousRequiredTimestamp: TimeInterval?
    private var wrongHandWasInsideTarget = false
    private var previousOtherFist: SIMD3<Float>?

    /// Creates a validator for one resolved combination target.
    ///
    /// Invalid or non-finite geometry fails closed: `observe` remains in `.waiting` rather than
    /// trapping or producing a hit. Positions must all share one coordinate frame. Tests use body
    /// space; the live session transforms the resolved body target and guard into the target's
    /// fixed world frame so a small head turn cannot separate validation from the visible sphere.
    init(
        target: CombinationTarget,
        guardPosition: SIMD3<Float>,
        hitRadius: Float
    ) {
        self.target = target
        self.guardPosition = guardPosition
        self.hitRadius = hitRadius

        let guardToTarget = target.position - guardPosition
        let distance = simd_length(guardToTarget)
        let isValid = Self.isFinite(target.position)
            && Self.isFinite(guardPosition)
            && hitRadius.isFinite
            && hitRadius > 0
            && distance.isFinite
            // The target center must be outside guard and beyond the arming distance, but those
            // regions do not need to be added together: both are measured from the same captured
            // guard center. Summing them rejects valid shorter-reach calibrations even though the
            // fist can leave guard, travel 10 cm, and then enter the target in that order.
            && distance > max(max(Self.guardRadius, Self.minimumOutwardTravel), hitRadius)

        hasValidConfiguration = isValid
        outwardDirection = isValid ? guardToTarget / distance : nil
    }

    /// Observes one timestamped frame of body-space fist positions.
    ///
    /// - Parameters:
    ///   - requiredFist: Position of `target.requiredHand`, or `nil` when that hand is untracked.
    ///   - otherFist: Position of the opposite physical hand, or `nil` when it is untracked.
    ///   - timestamp: Monotonic sample time, such as `HandObservation.timestamp`.
    ///
    /// Non-finite, duplicate, and out-of-order timing cannot generate velocity. A tracking gap
    /// longer than `maximumSampleInterval` discards partial outbound motion and requires guard
    /// again, preventing a stale, already-extended fist from arming after a dropout.
    mutating func observe(
        requiredFist: SIMD3<Float>?,
        otherFist: SIMD3<Float>?,
        timestamp: TimeInterval
    ) -> Event {
        guard phase != .hit else { return .hit }
        guard hasValidConfiguration, timestamp.isFinite else { return currentEvent }

        let otherHandIsInsideTarget: Bool
        if let otherFist, Self.isFinite(otherFist) {
            let distanceToTarget = simd_distance(otherFist, target.position)
            otherHandIsInsideTarget = (distanceToTarget.isFinite && distanceToTarget <= hitRadius)
                || previousOtherFist.map {
                    Self.segmentIntersectsSphere(
                        from: $0, to: otherFist, center: target.position, radius: hitRadius
                    )
                } == true
            previousOtherFist = otherFist
        } else {
            otherHandIsInsideTarget = false
            previousOtherFist = nil
        }

        let wrongHandEnteredTarget = otherHandIsInsideTarget && !wrongHandWasInsideTarget
        wrongHandWasInsideTarget = otherHandIsInsideTarget
        if wrongHandEnteredTarget {
            return .wrongHand
        }

        guard let requiredFist, Self.isFinite(requiredFist) else { return currentEvent }

        switch phase {
        case .waitingForGuard:
            observeGuard(requiredFist, timestamp: timestamp)
            return .waiting

        case .trackingOutbound:
            return trackOutbound(requiredFist, timestamp: timestamp)

        case .armed:
            if let previousTimestamp = previousRequiredTimestamp {
                let deltaTime = timestamp - previousTimestamp
                guard deltaTime.isFinite, deltaTime > 0 else { return .armed }
                if deltaTime > Self.maximumSampleInterval {
                    resetToGuard()
                    observeGuard(requiredFist, timestamp: timestamp)
                    return .waiting
                }
                guard deltaTime >= Self.minimumSampleInterval else { return .armed }
            }
            let previousFist = previousRequiredFist
            previousRequiredFist = requiredFist
            previousRequiredTimestamp = timestamp
            let distanceToTarget = simd_distance(requiredFist, target.position)
            let crossedTarget = previousFist.map {
                Self.segmentIntersectsSphere(
                    from: $0, to: requiredFist, center: target.position, radius: hitRadius
                )
            } ?? false
            guard (distanceToTarget.isFinite && distanceToTarget <= hitRadius) || crossedTarget
            else { return .armed }
            phase = .hit
            return .hit

        case .hit:
            return .hit
        }
    }

    /// Pure return-to-guard check for gating the next step, especially a repeated-hand step such
    /// as the second jab in a double-jab. Invalid input fails closed.
    static func isRetracted(
        fist: SIMD3<Float>,
        guardPosition: SIMD3<Float>,
        radius: Float
    ) -> Bool {
        guard isFinite(fist),
              isFinite(guardPosition),
              radius.isFinite,
              radius > 0
        else { return false }

        let distanceToGuard = simd_distance(fist, guardPosition)
        return distanceToGuard.isFinite && distanceToGuard <= radius
    }

    private var currentEvent: Event {
        phase == .armed ? .armed : .waiting
    }

    private mutating func observeGuard(
        _ requiredFist: SIMD3<Float>,
        timestamp: TimeInterval
    ) {
        guard Self.isRetracted(
            fist: requiredFist,
            guardPosition: guardPosition,
            radius: Self.guardRadius
        ) else { return }

        previousRequiredFist = requiredFist
        previousRequiredTimestamp = timestamp
        phase = .trackingOutbound
    }

    private mutating func trackOutbound(
        _ requiredFist: SIMD3<Float>,
        timestamp: TimeInterval
    ) -> Event {
        guard let direction = outwardDirection,
              let previousFist = previousRequiredFist,
              let previousTimestamp = previousRequiredTimestamp
        else {
            resetToGuard()
            return .waiting
        }

        let deltaTime = timestamp - previousTimestamp
        guard deltaTime.isFinite, deltaTime > 0 else { return .waiting }

        if deltaTime > Self.maximumSampleInterval {
            resetToGuard()
            observeGuard(requiredFist, timestamp: timestamp)
            return .waiting
        }

        guard deltaTime >= Self.minimumSampleInterval else { return .waiting }

        previousRequiredFist = requiredFist
        previousRequiredTimestamp = timestamp

        let totalOutwardTravel = simd_dot(requiredFist - guardPosition, direction)
        let outwardStep = simd_dot(requiredFist - previousFist, direction)
        guard totalOutwardTravel.isFinite, outwardStep.isFinite else { return .waiting }

        let outwardVelocity = outwardStep / Float(deltaTime)
        guard outwardVelocity.isFinite,
              totalOutwardTravel >= Self.minimumOutwardTravel,
              outwardVelocity >= Self.minimumOutwardVelocity
        else { return .waiting }

        phase = .armed
        return .armed
    }

    private mutating func resetToGuard() {
        phase = .waitingForGuard
        previousRequiredFist = nil
        previousRequiredTimestamp = nil
    }

    private static func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    static func segmentIntersectsSphere(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        center: SIMD3<Float>,
        radius: Float
    ) -> Bool {
        guard isFinite(start), isFinite(end), isFinite(center), radius.isFinite, radius > 0
        else { return false }
        let segment = end - start
        let squaredLength = simd_length_squared(segment)
        guard squaredLength.isFinite else { return false }
        if squaredLength <= .ulpOfOne { return simd_distance(start, center) <= radius }
        let projection = simd_dot(center - start, segment) / squaredLength
        let t = min(max(projection, 0), 1)
        return simd_distance(start + segment * t, center) <= radius
    }
}
