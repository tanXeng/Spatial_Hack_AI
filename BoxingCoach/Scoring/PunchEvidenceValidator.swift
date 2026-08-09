import Foundation
import simd

/// Pure admission state machine for one outbound-contact-return punch.
///
/// Positions must share one metric coordinate space. The reducer owns no ARKit or session state;
/// callers bind every frame and the final coverage result to one provider generation and one
/// continuity epoch before semantic punch evidence can be created.
nonisolated struct PunchEvidenceValidator: Sendable {
    nonisolated struct Configuration: Sendable {
        let technique: Technique
        let stance: Stance
        let requiredHand: BodySide
        let guardPosition: SIMD3<Float>
        let targetPosition: SIMD3<Float>
        let targetRadius: Float
        let generation: UInt64
        let continuityEpoch: UInt64

        nonisolated init(
            technique: Technique,
            stance: Stance,
            requiredHand: BodySide? = nil,
            guardPosition: SIMD3<Float>,
            targetPosition: SIMD3<Float>,
            targetRadius: Float,
            generation: UInt64,
            continuityEpoch: UInt64
        ) {
            self.technique = technique
            self.stance = stance
            if let requiredHand {
                self.requiredHand = requiredHand
            } else {
                switch technique.hand {
                case .lead, .either:
                    self.requiredHand = stance.leadSide
                case .rear:
                    self.requiredHand = stance.rearSide
                }
            }
            self.guardPosition = guardPosition
            self.targetPosition = targetPosition
            self.targetRadius = targetRadius
            self.generation = generation
            self.continuityEpoch = continuityEpoch
        }
    }

    nonisolated struct HandSample: Sendable {
        let side: BodySide
        let fistPosition: SIMD3<Float>
        let fistState: TrackedFistState
        let acquisitionTimestamp: TimeInterval
        let quality: MeasurementQuality

        nonisolated init(
            side: BodySide,
            fistPosition: SIMD3<Float>,
            fistState: TrackedFistState,
            acquisitionTimestamp: TimeInterval,
            quality: MeasurementQuality
        ) {
            self.side = side
            self.fistPosition = fistPosition
            self.fistState = fistState
            self.acquisitionTimestamp = acquisitionTimestamp
            self.quality = quality
        }
    }

    nonisolated struct Frame: Sendable {
        let now: TimeInterval
        let deviceTimestamp: TimeInterval
        let generation: UInt64
        let continuityEpoch: UInt64
        let hands: [HandSample]

        nonisolated init(
            now: TimeInterval,
            deviceTimestamp: TimeInterval,
            generation: UInt64,
            continuityEpoch: UInt64,
            hands: [HandSample]
        ) {
            self.now = now
            self.deviceTimestamp = deviceTimestamp
            self.generation = generation
            self.continuityEpoch = continuityEpoch
            self.hands = hands
        }
    }

    /// Coverage produced by the recorder for the exact chain that drove this reducer.
    nonisolated struct Coverage: Sendable {
        let trackedFraction: Float
        let generation: UInt64
        let continuityEpoch: UInt64

        nonisolated init(
            trackedFraction: Float,
            generation: UInt64,
            continuityEpoch: UInt64
        ) {
            self.trackedFraction = trackedFraction
            self.generation = generation
            self.continuityEpoch = continuityEpoch
        }
    }

    nonisolated enum Phase: Sendable, Equatable {
        case waitingForGuard
        case trackingOutbound
        case trackingRetraction
        case awaitingCoverage
        case complete
    }

    nonisolated enum InvalidReason: Sendable, Equatable {
        case invalidConfiguration
        case invalidPhase
        case nonFinite(field: String)
        case invalidTimestamp(field: String)
        case duplicateHand(side: BodySide)
        case missingRequiredHand(side: BodySide)
        case wrongHand(expected: BodySide, actual: BodySide)
        case ambiguousHandSelection
        case fistNotClosed(side: BodySide, state: TrackedFistState)
        case stationaryInsideTarget(side: BodySide)
        case staleSample(side: BodySide, age: TimeInterval, maximumAge: TimeInterval)
        case staleDevice(age: TimeInterval, maximumAge: TimeInterval)
        case overSkewed(side: BodySide, skew: TimeInterval, maximumSkew: TimeInterval)
        case sampleGap(duration: TimeInterval, maximumGap: TimeInterval)
        case generationMismatch(expected: UInt64, actual: UInt64)
        case continuityEpochMismatch(expected: UInt64, actual: UInt64)
        case missingGuardDeparture
        case insufficientOutboundTravel(actual: Float, minimum: Float)
        case insufficientOutwardVelocity(actual: Float, minimum: Float)
        case missingRetraction
        case missingTrackingCoverage
        case insufficientTrackingCoverage(actual: Float, minimum: Float)
    }

    nonisolated enum Event: Sendable, Equatable {
        case waiting(Phase)
        case armed
        case contact
        case readyForCoverage
        case invalid(InvalidReason)
        case validated(ValidatedPunchEvidence)
    }

    static let guardRadius: Float = 0.14
    static let minimumOutboundTravel: Float = 0.10
    static let minimumOutwardVelocity: Float = 0.20
    static let maximumSampleAge: TimeInterval = 0.100
    static let maximumHandDeviceSkew: TimeInterval = 0.033
    static let maximumSampleGap: TimeInterval = 0.200
    static let minimumTrackedFraction: Float = 0.45

    let configuration: Configuration
    private(set) var phase: Phase = .waitingForGuard

    private let hasValidConfiguration: Bool
    private var previousHands: [BodySide: HandSample] = [:]
    private var previousRequiredSample: HandSample?
    private var acquiredGuardPosition: SIMD3<Float>?
    private var outwardDirection: SIMD3<Float>?
    private var guardTimestamp: TimeInterval?
    private var startedAt: TimeInterval?
    private var landedAt: TimeInterval?
    private var returnedAt: TimeInterval?
    private var maximumTravel: Float = 0
    private var maximumVelocity: Float = 0
    private var landingError: Float = 0
    private var returnError: Float = 0
    private var previousDistanceToGuard: Float?
    private var movedTowardGuard = false
    private var quality: MeasurementQuality = .measured

    nonisolated init(configuration: Configuration) {
        self.configuration = configuration

        let guardToTarget = configuration.targetPosition - configuration.guardPosition
        let distance = simd_length(guardToTarget)
        let handMatchesTechnique: Bool
        switch configuration.technique.hand {
        case .lead:
            handMatchesTechnique = configuration.requiredHand == configuration.stance.leadSide
        case .rear:
            handMatchesTechnique = configuration.requiredHand == configuration.stance.rearSide
        case .either:
            handMatchesTechnique = true
        }
        let valid = Self.isFinite(configuration.guardPosition)
            && Self.isFinite(configuration.targetPosition)
            && configuration.targetRadius.isFinite
            && configuration.targetRadius > 0
            && distance.isFinite
            && distance > max(Self.guardRadius, Self.minimumOutboundTravel)
            && handMatchesTechnique
        hasValidConfiguration = valid
        outwardDirection = nil
    }

    /// Admits one time-coherent frame. Every invalid transition discards the partial punch.
    nonisolated mutating func observe(_ frame: Frame) -> Event {
        guard phase != .complete else { return .waiting(.complete) }
        guard hasValidConfiguration else { return invalidate(.invalidConfiguration) }
        if let reason = validate(frame) { return invalidate(reason) }

        var samples: [BodySide: HandSample] = [:]
        for hand in frame.hands { samples[hand.side] = hand }

        if let wrongHandReason = wrongHandContact(in: samples) {
            return invalidate(wrongHandReason)
        }

        guard let required = samples[configuration.requiredHand] else {
            return phase == .waitingForGuard
                ? .waiting(.waitingForGuard)
                : invalidate(.missingRequiredHand(side: configuration.requiredHand))
        }
        guard required.fistState == .closed else {
            return invalidate(
                .fistNotClosed(side: required.side, state: required.fistState)
            )
        }

        if let previousRequiredSample,
           required.acquisitionTimestamp == previousRequiredSample.acquisitionTimestamp {
            guard required.fistPosition == previousRequiredSample.fistPosition,
                  required.fistState == previousRequiredSample.fistState
            else {
                return invalidate(
                    .invalidTimestamp(field: "handTimestamp.\(required.side.rawValue)")
                )
            }
            previousHands = samples
            return currentProgressEvent
        }

        if required.quality == .inferred { quality = .inferred }

        let event: Event
        switch phase {
        case .waitingForGuard:
            event = acquireGuard(with: required)
        case .trackingOutbound:
            event = trackOutbound(with: required)
        case .trackingRetraction:
            event = trackRetraction(with: required)
        case .awaitingCoverage:
            event = .waiting(.awaitingCoverage)
        case .complete:
            event = .waiting(.complete)
        }

        if case .invalid = event {
            // `invalidate` already discarded the entire chain. Never let a rejected frame become
            // the starting endpoint for a swept contact in the next attempt.
        } else {
            previousHands = samples
        }
        return event
    }

    /// Ends an unfinished attempt with the most specific available typed reason.
    nonisolated mutating func finish() -> Event {
        switch phase {
        case .waitingForGuard:
            return invalidate(
                .insufficientOutboundTravel(
                    actual: maximumTravel,
                    minimum: Self.minimumOutboundTravel
                )
            )
        case .trackingOutbound:
            if maximumTravel < Self.minimumOutboundTravel {
                return invalidate(
                    .insufficientOutboundTravel(
                        actual: maximumTravel,
                        minimum: Self.minimumOutboundTravel
                    )
                )
            }
            if maximumVelocity < Self.minimumOutwardVelocity {
                return invalidate(
                    .insufficientOutwardVelocity(
                        actual: maximumVelocity,
                        minimum: Self.minimumOutwardVelocity
                    )
                )
            }
            return invalidate(.missingRetraction)
        case .trackingRetraction:
            return invalidate(.missingRetraction)
        case .awaitingCoverage:
            return invalidate(.missingTrackingCoverage)
        case .complete:
            return invalidate(.invalidPhase)
        }
    }

    /// Completes admission only with recorder coverage from this exact tracking chain.
    nonisolated mutating func complete(coverage: Coverage) -> Event {
        guard phase == .awaitingCoverage else { return invalidate(.invalidPhase) }
        guard coverage.generation == configuration.generation else {
            return invalidate(
                .generationMismatch(
                    expected: configuration.generation,
                    actual: coverage.generation
                )
            )
        }
        guard coverage.continuityEpoch == configuration.continuityEpoch else {
            return invalidate(
                .continuityEpochMismatch(
                    expected: configuration.continuityEpoch,
                    actual: coverage.continuityEpoch
                )
            )
        }
        guard coverage.trackedFraction.isFinite else {
            return invalidate(.nonFinite(field: "trackedFraction"))
        }
        guard (0...1).contains(coverage.trackedFraction) else {
            return invalidate(.insufficientTrackingCoverage(
                actual: coverage.trackedFraction,
                minimum: Self.minimumTrackedFraction
            ))
        }
        guard coverage.trackedFraction >= Self.minimumTrackedFraction else {
            return invalidate(
                .insufficientTrackingCoverage(
                    actual: coverage.trackedFraction,
                    minimum: Self.minimumTrackedFraction
                )
            )
        }
        guard let startedAt, let landedAt, let returnedAt else {
            return invalidate(.invalidPhase)
        }

        do {
            let evidence = try ValidatedPunchEvidence(
                technique: configuration.technique,
                stance: configuration.stance,
                side: configuration.requiredHand,
                generation: configuration.generation,
                startedAt: startedAt,
                landedAt: landedAt,
                returnedAt: returnedAt,
                outboundTravel: maximumTravel,
                landingError: landingError,
                returnError: returnError,
                trackedFraction: coverage.trackedFraction,
                quality: quality
            )
            phase = .complete
            return .validated(evidence)
        } catch {
            return invalidate(.invalidPhase)
        }
    }

    nonisolated private func validate(_ frame: Frame) -> InvalidReason? {
        guard frame.generation == configuration.generation else {
            return .generationMismatch(
                expected: configuration.generation,
                actual: frame.generation
            )
        }
        guard frame.continuityEpoch == configuration.continuityEpoch else {
            return .continuityEpochMismatch(
                expected: configuration.continuityEpoch,
                actual: frame.continuityEpoch
            )
        }
        guard frame.now.isFinite else { return .nonFinite(field: "now") }
        guard frame.deviceTimestamp.isFinite else {
            return .nonFinite(field: "deviceTimestamp")
        }
        guard frame.now >= 0, frame.deviceTimestamp >= 0,
              frame.deviceTimestamp <= frame.now
        else { return .invalidTimestamp(field: "deviceTimestamp") }

        var seenSides: Set<BodySide> = []
        for hand in frame.hands {
            guard seenSides.insert(hand.side).inserted else {
                return .duplicateHand(side: hand.side)
            }
            guard Self.isFinite(hand.fistPosition) else {
                return .nonFinite(field: "fistPosition.\(hand.side.rawValue)")
            }
            guard hand.acquisitionTimestamp.isFinite else {
                return .nonFinite(field: "handTimestamp.\(hand.side.rawValue)")
            }
            guard hand.acquisitionTimestamp >= 0,
                  hand.acquisitionTimestamp <= frame.now
            else { return .invalidTimestamp(field: "handTimestamp.\(hand.side.rawValue)") }

            let age = frame.now - hand.acquisitionTimestamp
            guard age <= Self.maximumSampleAge + Self.timeTolerance else {
                return .staleSample(
                    side: hand.side,
                    age: age,
                    maximumAge: Self.maximumSampleAge
                )
            }
        }

        // Prefer the most local typed cause when both a hand and its matched device pose have
        // aged out together. A separately stale device pose still wins over derived skew below.
        let deviceAge = frame.now - frame.deviceTimestamp
        guard deviceAge <= Self.maximumSampleAge + Self.timeTolerance else {
            return .staleDevice(age: deviceAge, maximumAge: Self.maximumSampleAge)
        }

        for hand in frame.hands {
            let skew = abs(hand.acquisitionTimestamp - frame.deviceTimestamp)
            guard skew <= Self.maximumHandDeviceSkew + Self.timeTolerance else {
                return .overSkewed(
                    side: hand.side,
                    skew: skew,
                    maximumSkew: Self.maximumHandDeviceSkew
                )
            }
        }

        if let previousTimestamp = previousRequiredSample?.acquisitionTimestamp,
           let required = frame.hands.first(where: { $0.side == configuration.requiredHand }) {
            let gap = required.acquisitionTimestamp - previousTimestamp
            guard gap.isFinite, gap >= 0 else {
                return .invalidTimestamp(field: "handTimestamp.\(required.side.rawValue)")
            }
            guard gap <= Self.maximumSampleGap + Self.timeTolerance else {
                return .sampleGap(duration: gap, maximumGap: Self.maximumSampleGap)
            }
        }
        return nil
    }

    nonisolated private var currentProgressEvent: Event {
        switch phase {
        case .waitingForGuard, .trackingOutbound:
            let isArmed = maximumTravel >= Self.minimumOutboundTravel
                && maximumVelocity >= Self.minimumOutwardVelocity
            return isArmed ? .armed : .waiting(phase)
        case .trackingRetraction, .awaitingCoverage, .complete:
            return .waiting(phase)
        }
    }

    nonisolated private func wrongHandContact(
        in samples: [BodySide: HandSample]
    ) -> InvalidReason? {
        let otherSide = configuration.requiredHand.opposite
        guard let current = samples[otherSide] else { return nil }

        let touchesTarget: Bool
        if let previous = previousHands[otherSide] {
            touchesTarget = Self.segmentDistance(
                from: previous.fistPosition,
                to: current.fistPosition,
                point: configuration.targetPosition
            ).distance <= configuration.targetRadius
        } else {
            touchesTarget = simd_distance(current.fistPosition, configuration.targetPosition)
                <= configuration.targetRadius
        }
        guard touchesTarget else { return nil }
        guard current.fistState == .closed else {
            return .fistNotClosed(side: otherSide, state: current.fistState)
        }
        return .wrongHand(expected: configuration.requiredHand, actual: otherSide)
    }

    nonisolated private mutating func acquireGuard(with sample: HandSample) -> Event {
        if simd_distance(sample.fistPosition, configuration.targetPosition)
            <= configuration.targetRadius {
            return invalidate(.stationaryInsideTarget(side: sample.side))
        }
        guard simd_distance(sample.fistPosition, configuration.guardPosition)
            <= Self.guardRadius else {
            return .waiting(.waitingForGuard)
        }

        previousRequiredSample = sample
        acquiredGuardPosition = sample.fistPosition
        let guardToTarget = configuration.targetPosition - sample.fistPosition
        let distanceToTarget = simd_length(guardToTarget)
        guard distanceToTarget.isFinite, distanceToTarget > Float.ulpOfOne else {
            return invalidate(.invalidConfiguration)
        }
        outwardDirection = guardToTarget / distanceToTarget
        guardTimestamp = sample.acquisitionTimestamp
        previousDistanceToGuard = simd_distance(sample.fistPosition, configuration.guardPosition)
        phase = .trackingOutbound
        return .waiting(.trackingOutbound)
    }

    nonisolated private mutating func trackOutbound(with sample: HandSample) -> Event {
        guard let previous = previousRequiredSample,
              let acquiredGuardPosition,
              let outwardDirection
        else {
            return invalidate(.invalidPhase)
        }

        let deltaTime = sample.acquisitionTimestamp - previous.acquisitionTimestamp
        let totalTravel = simd_dot(
            sample.fistPosition - acquiredGuardPosition,
            outwardDirection
        )
        let stepTravel = simd_dot(sample.fistPosition - previous.fistPosition, outwardDirection)
        let velocity = stepTravel / Float(deltaTime)
        guard totalTravel.isFinite, stepTravel.isFinite, velocity.isFinite else {
            return invalidate(.nonFinite(field: "outboundMotion"))
        }

        if startedAt == nil,
           simd_distance(sample.fistPosition, configuration.guardPosition) > Self.guardRadius {
            startedAt = guardTimestamp ?? previous.acquisitionTimestamp
        }

        let segmentContact = Self.segmentDistance(
            from: previous.fistPosition,
            to: sample.fistPosition,
            point: configuration.targetPosition
        )
        let entryParameter = Self.segmentSphereEntryParameter(
            from: previous.fistPosition,
            to: sample.fistPosition,
            center: configuration.targetPosition,
            radius: configuration.targetRadius
        )

        if let entryParameter {
            let entryPosition = previous.fistPosition
                + (sample.fistPosition - previous.fistPosition) * entryParameter
            let entryTravel = simd_dot(
                entryPosition - acquiredGuardPosition,
                outwardDirection
            )
            guard entryTravel + Self.distanceTolerance >= Self.minimumOutboundTravel else {
                return invalidate(
                    .insufficientOutboundTravel(
                        actual: max(0, entryTravel),
                        minimum: Self.minimumOutboundTravel
                    )
                )
            }
            guard simd_distance(entryPosition, configuration.guardPosition)
                > Self.guardRadius + Self.distanceTolerance
            else {
                return invalidate(.missingGuardDeparture)
            }
            guard velocity + Self.distanceTolerance >= Self.minimumOutwardVelocity else {
                return invalidate(
                    .insufficientOutwardVelocity(
                        actual: max(0, velocity),
                        minimum: Self.minimumOutwardVelocity
                    )
                )
            }

            maximumTravel = max(maximumTravel, totalTravel)
            maximumVelocity = max(maximumVelocity, velocity)
            startedAt = startedAt ?? (guardTimestamp ?? previous.acquisitionTimestamp)
            landedAt = previous.acquisitionTimestamp
                + (sample.acquisitionTimestamp - previous.acquisitionTimestamp)
                    * TimeInterval(entryParameter)
            landingError = segmentContact.distance
            previousRequiredSample = sample
            previousDistanceToGuard = simd_distance(
                sample.fistPosition,
                configuration.guardPosition
            )
            phase = .trackingRetraction
            return .contact
        }

        maximumTravel = max(maximumTravel, totalTravel)
        maximumVelocity = max(maximumVelocity, velocity)
        let isArmed = maximumTravel >= Self.minimumOutboundTravel
            && maximumVelocity >= Self.minimumOutwardVelocity

        previousRequiredSample = sample
        previousDistanceToGuard = simd_distance(sample.fistPosition, configuration.guardPosition)
        return isArmed ? .armed : .waiting(.trackingOutbound)
    }

    nonisolated private mutating func trackRetraction(with sample: HandSample) -> Event {
        guard let previous = previousRequiredSample else {
            return invalidate(.invalidPhase)
        }
        let previousDistance = previousDistanceToGuard
            ?? simd_distance(previous.fistPosition, configuration.guardPosition)
        let distance = simd_distance(sample.fistPosition, configuration.guardPosition)
        if distance + Self.distanceTolerance < previousDistance {
            movedTowardGuard = true
        }

        previousRequiredSample = sample
        previousDistanceToGuard = distance

        guard movedTowardGuard, distance <= Self.guardRadius else {
            return .waiting(.trackingRetraction)
        }

        returnedAt = sample.acquisitionTimestamp
        returnError = distance
        phase = .awaitingCoverage
        return .readyForCoverage
    }

    @discardableResult
    nonisolated private mutating func invalidate(_ reason: InvalidReason) -> Event {
        reset()
        return .invalid(reason)
    }

    nonisolated private mutating func reset() {
        phase = .waitingForGuard
        previousHands.removeAll(keepingCapacity: true)
        previousRequiredSample = nil
        acquiredGuardPosition = nil
        outwardDirection = nil
        guardTimestamp = nil
        startedAt = nil
        landedAt = nil
        returnedAt = nil
        maximumTravel = 0
        maximumVelocity = 0
        landingError = 0
        returnError = 0
        previousDistanceToGuard = nil
        movedTowardGuard = false
        quality = .measured
    }

    nonisolated private static func segmentDistance(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        point: SIMD3<Float>
    ) -> (distance: Float, parameter: Float) {
        let segment = end - start
        let lengthSquared = simd_length_squared(segment)
        guard lengthSquared.isFinite, lengthSquared > Float.ulpOfOne else {
            return (simd_distance(start, point), 0)
        }
        let parameter = min(1, max(0, simd_dot(point - start, segment) / lengthSquared))
        let closest = start + segment * parameter
        return (simd_distance(closest, point), parameter)
    }

    /// Returns the first point at which an outbound segment enters the target sphere.
    nonisolated private static func segmentSphereEntryParameter(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        center: SIMD3<Float>,
        radius: Float
    ) -> Float? {
        let segment = end - start
        let offset = start - center
        let a = simd_dot(segment, segment)
        guard a.isFinite, a > Float.ulpOfOne else {
            return simd_distance(start, center) <= radius ? 0 : nil
        }

        let c = simd_dot(offset, offset) - radius * radius
        if c <= 0 { return 0 }

        let b = 2 * simd_dot(offset, segment)
        let discriminant = b * b - 4 * a * c
        guard discriminant.isFinite, discriminant >= 0 else { return nil }

        let parameter = (-b - sqrt(discriminant)) / (2 * a)
        guard parameter >= 0, parameter <= 1 else { return nil }
        return parameter
    }

    nonisolated private static func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static let timeTolerance: TimeInterval = 0.000_000_001
    private static let distanceTolerance: Float = 0.000_001
}

/// Identity captured at the same instant a session clears and starts its motion recorder.
///
/// Sessions must ask this value to stamp recorder coverage at completion. A provider restart or
/// continuity reset therefore discards the recorder result instead of relabeling stale samples as
/// evidence from the new chain.
nonisolated struct PunchEvidenceCaptureChain: Sendable, Equatable {
    let generation: UInt64
    let continuityEpoch: UInt64

    nonisolated init(generation: UInt64, continuityEpoch: UInt64) {
        self.generation = generation
        self.continuityEpoch = continuityEpoch
    }

    nonisolated func coverage(
        trackedFraction: Float,
        currentGeneration: UInt64,
        currentContinuityEpoch: UInt64
    ) -> PunchEvidenceValidator.Coverage? {
        guard currentGeneration == generation,
              currentContinuityEpoch == continuityEpoch
        else { return nil }
        return PunchEvidenceValidator.Coverage(
            trackedFraction: trackedFraction,
            generation: generation,
            continuityEpoch: continuityEpoch
        )
    }
}

/// Session-facing admission policy derived from reducer events.
///
/// Invalid evidence is deliberately represented as `retry`, never as a miss or a lower-quality
/// hit. Only fully validated evidence can cross the metric/ranking boundary.
nonisolated enum PunchEvidenceAttemptAction: Sendable, Equatable {
    case waiting(PunchEvidenceValidator.Phase)
    case armed
    case contact
    case completeCoverage
    case retry(PunchEvidenceValidator.InvalidReason)
    case admit(ValidatedPunchEvidence)

    nonisolated init(event: PunchEvidenceValidator.Event) {
        switch event {
        case let .waiting(phase):
            self = .waiting(phase)
        case .armed:
            self = .armed
        case .contact:
            self = .contact
        case .readyForCoverage:
            self = .completeCoverage
        case let .invalid(reason):
            self = .retry(reason)
        case let .validated(evidence):
            self = .admit(evidence)
        }
    }

    nonisolated var canBeDeferredByGuard: Bool {
        switch self {
        case .waiting(.waitingForGuard), .waiting(.trackingOutbound), .armed:
            return true
        case .waiting, .contact, .completeCoverage, .retry, .admit:
            return false
        }
    }

    nonisolated var recordsMetric: Bool {
        if case .admit = self { return true }
        return false
    }

    nonisolated var isRankable: Bool { recordsMetric }

    nonisolated var advancesScoredSlot: Bool { recordsMetric }
}

/// Reactive-target adapter that identifies a physical hand by validated outbound motion once,
/// then keeps that requirement fixed through contact, retraction, and completion.
nonisolated struct PunchEvidenceSideSelector: Sendable {
    nonisolated enum Event: Sendable, Equatable {
        case waiting
        case invalid(PunchEvidenceValidator.InvalidReason)
        case selected(side: BodySide, event: PunchEvidenceValidator.Event)
    }

    private var validators: [BodySide: PunchEvidenceValidator]
    private(set) var requiredHand: BodySide?

    nonisolated init(
        technique: Technique,
        stance: Stance,
        guardPositions: [BodySide: SIMD3<Float>],
        targetPosition: SIMD3<Float>,
        targetRadius: Float,
        generation: UInt64,
        continuityEpoch: UInt64
    ) {
        var validators: [BodySide: PunchEvidenceValidator] = [:]
        for side in [BodySide.left, .right] {
            guard let guardPosition = guardPositions[side] else { continue }
            validators[side] = PunchEvidenceValidator(
                configuration: .init(
                    technique: technique,
                    stance: stance,
                    requiredHand: side,
                    guardPosition: guardPosition,
                    targetPosition: targetPosition,
                    targetRadius: targetRadius,
                    generation: generation,
                    continuityEpoch: continuityEpoch
                )
            )
        }
        self.validators = validators
    }

    nonisolated mutating func observe(_ frame: PunchEvidenceValidator.Frame) -> Event {
        if let requiredHand {
            guard var validator = validators[requiredHand] else { return .waiting }
            let event = validator.observe(frame)
            validators[requiredHand] = validator
            return .selected(side: requiredHand, event: event)
        }

        var events: [BodySide: PunchEvidenceValidator.Event] = [:]
        for side in [BodySide.left, .right] {
            guard var validator = validators[side] else { continue }
            events[side] = validator.observe(frame)
            validators[side] = validator
        }

        let selectableSides = [BodySide.left, .right].filter { side in
            events[side].map(Self.selectsSide) ?? false
        }
        if selectableSides.count > 1 {
            resetSpeculation()
            return .invalid(.ambiguousHandSelection)
        }
        if let side = selectableSides.first,
           let event = events[side],
           let selectedValidator = validators[side] {
            requiredHand = side
            // The other speculative reducer is no longer part of this punch chain.
            validators = [side: selectedValidator]
            return .selected(side: side, event: event)
        }

        let invalidReasons = [BodySide.left, .right].compactMap { side -> PunchEvidenceValidator.InvalidReason? in
            guard case let .invalid(reason)? = events[side] else { return nil }
            return reason
        }
        if let reason = invalidReasons.first {
            resetSpeculation()
            return .invalid(reason)
        }
        return .waiting
    }

    nonisolated mutating func complete(
        coverage: PunchEvidenceValidator.Coverage
    ) -> Event {
        guard let requiredHand, var validator = validators[requiredHand] else {
            return .waiting
        }
        let event = validator.complete(coverage: coverage)
        validators[requiredHand] = validator
        return .selected(side: requiredHand, event: event)
    }

    nonisolated mutating func finish() -> Event {
        guard let requiredHand, var validator = validators[requiredHand] else {
            return .waiting
        }
        let event = validator.finish()
        validators[requiredHand] = validator
        return .selected(side: requiredHand, event: event)
    }

    nonisolated private static func selectsSide(
        _ event: PunchEvidenceValidator.Event
    ) -> Bool {
        switch event {
        case .armed, .contact, .readyForCoverage, .validated:
            return true
        case .waiting, .invalid:
            return false
        }
    }

    nonisolated private mutating func resetSpeculation() {
        validators = validators.mapValues {
            PunchEvidenceValidator(configuration: $0.configuration)
        }
        requiredHand = nil
    }
}

/// Visible copy derived from typed punch admission outcomes.
nonisolated enum PunchEvidenceFeedback {
    nonisolated enum ReturnStyle: Sendable {
        case `return`
        case snap
    }

    nonisolated static func strikeNow(side: BodySide) -> String {
        "\(side.rawValue.capitalized) hand · strike now"
    }

    nonisolated static func returnToGuard(
        side: BodySide,
        style: ReturnStyle
    ) -> String {
        switch style {
        case .return:
            return "Return your \(side.rawValue) hand to guard"
        case .snap:
            return "Snap your \(side.rawValue) hand back to guard"
        }
    }

    nonisolated static func message(
        for reason: PunchEvidenceValidator.InvalidReason
    ) -> String {
        switch reason {
        case let .wrongHand(expected, _):
            return "Wrong hand · use your \(expected.rawValue) hand"
        case .ambiguousHandSelection:
            return "Use one hand at a time"
        case .fistNotClosed:
            return "Keep your fist closed through the full punch"
        case .staleSample, .staleDevice, .overSkewed, .sampleGap,
             .generationMismatch, .continuityEpochMismatch:
            return "Tracking changed · punch discarded"
        case .insufficientOutboundTravel:
            return "Start at guard and punch at least 10 cm outward"
        case .insufficientOutwardVelocity:
            return "Punch outward with a clear strike motion"
        case .missingGuardDeparture:
            return "Leave guard before reaching the target"
        case .missingRetraction:
            return "Return the punching hand to guard"
        case .missingTrackingCoverage, .insufficientTrackingCoverage:
            return "Keep the punching hand visible through the full rep"
        case .invalidConfiguration, .invalidPhase, .nonFinite, .invalidTimestamp,
             .duplicateHand, .missingRequiredHand, .stationaryInsideTarget:
            return "Punch evidence was invalid · reset in guard"
        }
    }
}
