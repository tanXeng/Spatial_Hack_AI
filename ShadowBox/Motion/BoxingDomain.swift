//
//  BoxingDomain.swift
//  Test
//
//  Pure Swift boxing-domain types. There are deliberately no ARKit,
//  RealityKit, or SwiftUI imports in this file.
//

import Foundation
import simd

enum HandSide: String, CaseIterable, Hashable, Sendable {
    case left
    case right
}

enum PunchKind: String, CaseIterable, Hashable, Sendable {
    case jab
    case cross

    var title: String { rawValue.capitalized }
}

enum Stance: String, CaseIterable, Hashable, Sendable {
    case orthodox
    case southpaw

    var title: String { rawValue.capitalized }
    var leadHand: HandSide { self == .orthodox ? .left : .right }
    var rearHand: HandSide { self == .orthodox ? .right : .left }

    func hand(for punch: PunchKind) -> HandSide {
        punch == .jab ? leadHand : rearHand
    }

    func punch(for hand: HandSide) -> PunchKind {
        hand == leadHand ? .jab : .cross
    }
}

struct HandPose: Equatable, Sendable {
    let fistCenter: SIMD3<Float>
    let wrist: SIMD3<Float>?
    let trackedKnuckleCount: Int
    /// Capture time for this hand anchor on the system monotonic clock.
    let capturedAt: TimeInterval
}

struct HandSample: Equatable, Sendable {
    /// Publish time on the system monotonic clock. Each pose also keeps its own
    /// capture time because left and right anchors update independently.
    let timestamp: TimeInterval
    let left: HandPose?
    let right: HandPose?

    func pose(for hand: HandSide) -> HandPose? {
        hand == .left ? left : right
    }
}

struct HandCalibrationProfile: Equatable, Sendable {
    /// Uncapped session capture used only for the bilateral profile scalar.
    let acceptedFunctionalReach: Float
    /// Separately capped reach used to place interactive targets safely.
    let targetPlacementReach: Float
    let straightPunchDirection: SIMD3<Float>
    /// Peak calibration velocity projected onto `straightPunchDirection`.
    let referenceProjectedPace: Float
}

struct CalibrationProfile: Equatable, Sendable {
    let stance: Stance
    let leftGuard: SIMD3<Float>
    let rightGuard: SIMD3<Float>
    let leftHand: HandCalibrationProfile
    let rightHand: HandCalibrationProfile

    init(
        stance: Stance,
        leftGuard: SIMD3<Float>,
        rightGuard: SIMD3<Float>,
        leftHand: HandCalibrationProfile,
        rightHand: HandCalibrationProfile
    ) {
        self.stance = stance
        self.leftGuard = leftGuard
        self.rightGuard = rightGuard
        self.leftHand = leftHand
        self.rightHand = rightHand
    }

    /// Compatibility initializer for deterministic fixtures that intentionally
    /// use identical calibration on both hands.
    init(
        stance: Stance,
        leftGuard: SIMD3<Float>,
        rightGuard: SIMD3<Float>,
        comfortableReach: Float,
        straightPunchDirection: SIMD3<Float>,
        referenceStraightSpeed: Float
    ) {
        let shared = HandCalibrationProfile(
            acceptedFunctionalReach: comfortableReach,
            targetPlacementReach: comfortableReach,
            straightPunchDirection: straightPunchDirection,
            referenceProjectedPace: referenceStraightSpeed
        )
        self.init(
            stance: stance,
            leftGuard: leftGuard,
            rightGuard: rightGuard,
            leftHand: shared,
            rightHand: shared
        )
    }

    func guardPosition(for hand: HandSide) -> SIMD3<Float> {
        hand == .left ? leftGuard : rightGuard
    }

    func handCalibration(for hand: HandSide) -> HandCalibrationProfile {
        hand == .left ? leftHand : rightHand
    }

    func acceptedFunctionalReach(for hand: HandSide) -> Float {
        handCalibration(for: hand).acceptedFunctionalReach
    }

    func targetPlacementReach(for hand: HandSide) -> Float {
        handCalibration(for: hand).targetPlacementReach
    }

    func straightPunchDirection(for hand: HandSide) -> SIMD3<Float> {
        handCalibration(for: hand).straightPunchDirection
    }

    func referenceProjectedPace(for hand: HandSide) -> Float {
        handCalibration(for: hand).referenceProjectedPace
    }

    var conservativeBilateralFunctionalReach: Float {
        min(
            leftHand.acceptedFunctionalReach,
            rightHand.acceptedFunctionalReach
        )
    }

    func hand(for punch: PunchKind) -> HandSide {
        stance.hand(for: punch)
    }

    func punch(for hand: HandSide) -> PunchKind {
        stance.punch(for: hand)
    }

    func targetPosition(
        for punch: PunchKind,
        configuration: DrillConfiguration
    ) -> SIMD3<Float> {
        let expectedHand = hand(for: punch)
        return guardPosition(for: expectedHand)
            + straightPunchDirection(for: expectedHand)
                * (targetPlacementReach(for: expectedHand)
                    * configuration.targetReachFraction)
            + SIMD3<Float>(0, configuration.targetVerticalOffset, 0)
    }
}

/// Centralized provisional values. They must be tuned on a physical Vision Pro
/// before the drill can be represented as physically validated.
struct DrillConfiguration: Equatable, Sendable {
    var guardHoldDuration: TimeInterval = 2.0
    var reachCaptureDuration: TimeInterval = 3.0
    var countdownDuration: TimeInterval = 3.0
    var roundDuration: TimeInterval = 60.0
    var cueDuration: TimeInterval = 2.0
    var feedbackDuration: TimeInterval = 0.35
    var resumeGuardHoldDuration: TimeInterval = 0.5
    var targetRadius: Float = 0.09
    var fistRadius: Float = 0.035
    var guardReturnRadius: Float = 0.10
    var guardReturnGoal: TimeInterval = 0.8
    var minimumGuardDeparture: Float = 0.11
    var minimumPunchTravel: Float = 0.12
    var minimumOutwardSpeed: Float = 0.45
    var minimumRetractSpeed: Float = 0.15
    var reversalDistance: Float = 0.025
    var maximumSampleInterval: TimeInterval = 0.20
    var minimumFistJointCount: Int = 3
    var minimumComfortableReach: Float = 0.32
    var maximumComfortableReach: Float = 0.75
    var targetReachFraction: Float = 0.82
    var targetVerticalOffset: Float = 0.035
    var minimumReferenceSpeed: Float = 0.50
    var minimumForwardRatio: Float = 0.70
    var maximumGuardSpeed: Float = 0.20

    static let provisional = DrillConfiguration()

    var effectiveTargetRadius: Float { targetRadius + fistRadius }
}

enum FistCenterEstimator {
    static func centroid(
        of joints: [SIMD3<Float>?],
        minimumJointCount: Int
    ) -> SIMD3<Float>? {
        let valid = joints.compactMap { point -> SIMD3<Float>? in
            guard let point,
                  point.x.isFinite,
                  point.y.isFinite,
                  point.z.isFinite else {
                return nil
            }
            return point
        }

        guard valid.count >= minimumJointCount else { return nil }
        return valid.reduce(SIMD3<Float>.zero, +) / Float(valid.count)
    }
}

enum BoxingGeometry {
    static func sweptSegmentIntersectsSphere(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        sphereCenter: SIMD3<Float>,
        sphereRadius: Float,
        movingRadius: Float = 0
    ) -> Bool {
        firstIntersectionFraction(
            from: start,
            to: end,
            sphereCenter: sphereCenter,
            sphereRadius: sphereRadius,
            movingRadius: movingRadius
        ) != nil
    }

    static func firstIntersectionFraction(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        sphereCenter: SIMD3<Float>,
        sphereRadius: Float,
        movingRadius: Float = 0
    ) -> Float? {
        let expandedRadius = max(0, sphereRadius + movingRadius)
        let offset = start - sphereCenter
        let direction = end - start
        let c = simd_dot(offset, offset) - expandedRadius * expandedRadius

        if c <= 0 { return 0 }

        let a = simd_dot(direction, direction)
        guard a > Float.ulpOfOne else { return nil }

        let b = 2 * simd_dot(offset, direction)
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return nil }

        let t = (-b - sqrt(discriminant)) / (2 * a)
        return (0...1).contains(t) ? t : nil
    }
}

struct TargetCue: Identifiable, Equatable, Sendable {
    let id: UUID
    let sequenceIndex: Int
    let expectedPunch: PunchKind
    let center: SIMD3<Float>
    let radius: Float
    let presentedAt: TimeInterval
    let expiresAt: TimeInterval

    init(
        id: UUID = UUID(),
        sequenceIndex: Int,
        expectedPunch: PunchKind,
        center: SIMD3<Float>,
        radius: Float,
        presentedAt: TimeInterval,
        expiresAt: TimeInterval
    ) {
        self.id = id
        self.sequenceIndex = sequenceIndex
        self.expectedPunch = expectedPunch
        self.center = center
        self.radius = radius
        self.presentedAt = presentedAt
        self.expiresAt = expiresAt
    }
}

struct PunchEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let hand: HandSide
    let kind: PunchKind
    let startedAt: TimeInterval
    /// Time the valid punch motion was recognized. For a hit this equals the
    /// interpolated contact time; for a miss it is the last outbound sample.
    let completedAt: TimeInterval
    /// Interpolated target contact time, or nil for a recognized clean miss.
    let contactAt: TimeInterval?
    let segmentStart: SIMD3<Float>
    let segmentEnd: SIMD3<Float>
    /// Peak velocity projected onto this hand's calibrated straight direction.
    let peakSpeed: Float

    init(
        id: UUID = UUID(),
        hand: HandSide,
        kind: PunchKind,
        startedAt: TimeInterval,
        completedAt: TimeInterval,
        contactAt: TimeInterval?,
        segmentStart: SIMD3<Float>,
        segmentEnd: SIMD3<Float>,
        peakSpeed: Float
    ) {
        self.id = id
        self.hand = hand
        self.kind = kind
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.contactAt = contactAt
        self.segmentStart = segmentStart
        self.segmentEnd = segmentEnd
        self.peakSpeed = peakSpeed
    }
}

/// Deterministic per-hand state machine. It evaluates actual consecutive
/// outbound segments against the logical target. A contact emits immediately;
/// an otherwise valid straight punch emits as a miss when retraction begins.
/// At most one event is emitted until that hand returns to guard.
struct PunchDetector: Sendable {
    private enum Phase: Sendable {
        case needsGuard
        case armed
        case extending(
            startedAt: TimeInterval,
            peakSpeed: Float,
            lastOutboundStart: SIMD3<Float>,
            lastOutboundEnd: SIMD3<Float>,
            cueID: UUID?
        )
        case recovering
    }

    private struct HandTrack: Sendable {
        var phase: Phase = .needsGuard
        var previousPosition: SIMD3<Float>?
        var previousTimestamp: TimeInterval?
    }

    private let calibration: CalibrationProfile
    private let configuration: DrillConfiguration
    private var tracks: [HandSide: HandTrack] = [
        .left: HandTrack(),
        .right: HandTrack(),
    ]

    init(
        calibration: CalibrationProfile,
        configuration: DrillConfiguration = .provisional
    ) {
        self.calibration = calibration
        self.configuration = configuration
    }

    mutating func reset() {
        tracks = [.left: HandTrack(), .right: HandTrack()]
    }

    mutating func process(_ sample: HandSample, target: TargetCue?) -> [PunchEvent] {
        HandSide.allCases.compactMap { hand in
            process(hand: hand, pose: sample.pose(for: hand), target: target)
        }
    }

    private mutating func process(
        hand: HandSide,
        pose: HandPose?,
        target: TargetCue?
    ) -> PunchEvent? {
        var track = tracks[hand] ?? HandTrack()
        guard let pose else {
            tracks[hand] = HandTrack()
            return nil
        }

        let timestamp = pose.capturedAt
        let position = pose.fistCenter
        let guardPosition = calibration.guardPosition(for: hand)
        let guardDelta = position - guardPosition
        let distanceToGuard = simd_length(guardDelta)
        let atGuard = distanceToGuard <= configuration.guardReturnRadius

        guard let previousPosition = track.previousPosition,
              let previousTimestamp = track.previousTimestamp else {
            track.phase = atGuard ? .armed : .needsGuard
            track.previousPosition = position
            track.previousTimestamp = timestamp
            tracks[hand] = track
            return nil
        }

        // The other hand can publish a frame with this cached pose. Never
        // advance time or velocity until this hand has a genuinely new anchor.
        guard timestamp > previousTimestamp else { return nil }

        let deltaTime = timestamp - previousTimestamp
        guard deltaTime <= configuration.maximumSampleInterval else {
            track = HandTrack(
                phase: atGuard ? .armed : .needsGuard,
                previousPosition: position,
                previousTimestamp: timestamp
            )
            tracks[hand] = track
            return nil
        }

        let direction = calibration.straightPunchDirection(for: hand)
        let projection = simd_dot(guardDelta, direction)
        let previousProjection = simd_dot(previousPosition - guardPosition, direction)
        let outwardSpeed = (projection - previousProjection) / Float(deltaTime)
        let forwardRatio = projection / max(distanceToGuard, 0.0001)
        var event: PunchEvent?

        switch track.phase {
        case .needsGuard:
            if atGuard {
                track.phase = .armed
            }

        case .armed:
            if atGuard {
                track.phase = .armed
            } else if distanceToGuard >= configuration.minimumGuardDeparture {
                if outwardSpeed >= configuration.minimumOutwardSpeed,
                   forwardRatio >= configuration.minimumForwardRatio {
                    let startedAt = previousTimestamp
                    let cueID = target?.id
                    event = contactEvent(
                        hand: hand,
                        startedAt: startedAt,
                        cueID: cueID,
                        previousPosition: previousPosition,
                        position: position,
                        previousTimestamp: previousTimestamp,
                        timestamp: timestamp,
                        projection: projection,
                        speed: outwardSpeed,
                        target: target
                    )
                    track.phase = event == nil
                        ? .extending(
                            startedAt: startedAt,
                            peakSpeed: outwardSpeed,
                            lastOutboundStart: previousPosition,
                            lastOutboundEnd: position,
                            cueID: cueID
                        )
                        : .recovering
                } else {
                    // Slow or sideways drift outside guard must return before
                    // another extension can arm.
                    track.phase = .recovering
                }
            }

        case .extending(
            let startedAt,
            let priorPeakSpeed,
            let lastOutboundStart,
            let lastOutboundEnd,
            let cueID
        ):
            let peakSpeed = max(priorPeakSpeed, outwardSpeed)
            let isRetracting = projection <= previousProjection - configuration.reversalDistance
                || outwardSpeed <= -configuration.minimumRetractSpeed
            let isStraight = forwardRatio >= configuration.minimumForwardRatio

            if isRetracting || !isStraight {
                event = completedMissEvent(
                    hand: hand,
                    startedAt: startedAt,
                    completedAt: previousTimestamp,
                    cueID: cueID,
                    projection: previousProjection,
                    segmentStart: lastOutboundStart,
                    segmentEnd: lastOutboundEnd,
                    speed: peakSpeed,
                    target: target
                )
                track.phase = .recovering
            } else {
                event = contactEvent(
                    hand: hand,
                    startedAt: startedAt,
                    cueID: cueID,
                    previousPosition: previousPosition,
                    position: position,
                    previousTimestamp: previousTimestamp,
                    timestamp: timestamp,
                    projection: projection,
                    speed: peakSpeed,
                    target: target
                )
                track.phase = event == nil
                    ? .extending(
                        startedAt: startedAt,
                        peakSpeed: peakSpeed,
                        lastOutboundStart: previousPosition,
                        lastOutboundEnd: position,
                        cueID: cueID
                    )
                    : .recovering
            }

        case .recovering:
            if atGuard {
                track.phase = .armed
            }
        }

        track.previousPosition = position
        track.previousTimestamp = timestamp
        tracks[hand] = track
        return event
    }

    private func contactEvent(
        hand: HandSide,
        startedAt: TimeInterval,
        cueID: UUID?,
        previousPosition: SIMD3<Float>,
        position: SIMD3<Float>,
        previousTimestamp: TimeInterval,
        timestamp: TimeInterval,
        projection: Float,
        speed: Float,
        target: TargetCue?
    ) -> PunchEvent? {
        guard projection >= configuration.minimumPunchTravel,
              let target,
              cueID == target.id,
              let fraction = BoxingGeometry.firstIntersectionFraction(
                from: previousPosition,
                to: position,
                sphereCenter: target.center,
                sphereRadius: target.radius,
                movingRadius: configuration.fistRadius
              ) else {
            return nil
        }

        let contactAt = previousTimestamp
            + (timestamp - previousTimestamp) * Double(fraction)
        guard contactAt >= target.presentedAt,
              contactAt <= target.expiresAt else {
            return nil
        }

        return PunchEvent(
            hand: hand,
            kind: calibration.punch(for: hand),
            startedAt: startedAt,
            completedAt: contactAt,
            contactAt: contactAt,
            segmentStart: previousPosition,
            segmentEnd: position,
            peakSpeed: speed
        )
    }

    private func completedMissEvent(
        hand: HandSide,
        startedAt: TimeInterval,
        completedAt: TimeInterval,
        cueID: UUID?,
        projection: Float,
        segmentStart: SIMD3<Float>,
        segmentEnd: SIMD3<Float>,
        speed: Float,
        target: TargetCue?
    ) -> PunchEvent? {
        guard projection >= configuration.minimumPunchTravel,
              let target,
              cueID == target.id,
              completedAt >= target.presentedAt,
              completedAt <= target.expiresAt else {
            return nil
        }

        return PunchEvent(
            hand: hand,
            kind: calibration.punch(for: hand),
            startedAt: startedAt,
            completedAt: completedAt,
            contactAt: nil,
            segmentStart: segmentStart,
            segmentEnd: segmentEnd,
            peakSpeed: speed
        )
    }
}

enum AttemptOutcome: String, Equatable, Sendable {
    case hit
    case miss
    case wrongPunch
    case timeout

    var isHit: Bool { self == .hit }
}

struct AttemptResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let cue: TargetCue
    let outcome: AttemptOutcome
    let resolvedAt: TimeInterval
    let punch: PunchEvent?
    let responseTime: TimeInterval?
    let relativeSpeed: Double?
    var returnedToGuard: Bool?

    init(
        id: UUID = UUID(),
        cue: TargetCue,
        outcome: AttemptOutcome,
        resolvedAt: TimeInterval,
        punch: PunchEvent?,
        responseTime: TimeInterval?,
        relativeSpeed: Double?,
        returnedToGuard: Bool? = nil
    ) {
        self.id = id
        self.cue = cue
        self.outcome = outcome
        self.resolvedAt = resolvedAt
        self.punch = punch
        self.responseTime = responseTime
        self.relativeSpeed = relativeSpeed
        self.returnedToGuard = returnedToGuard
    }
}

struct RoundSummary: Equatable, Sendable {
    let difficulty: TrainingDifficulty
    let completedAttempts: Int
    let hits: Int
    let misses: Int
    let spatialMisses: Int
    let timeouts: Int
    let wrongPunches: Int
    let cancelledCues: Int
    let trackingInterruptions: Int
    let guardReturnsCensored: Int
    let hitRate: Double
    let averageResponseTime: TimeInterval?
    let averageRelativeSpeed: Double?
    let guardReturnConsistency: Double?
    let pausedDuration: TimeInterval

    init(
        attempts: [AttemptResult],
        pausedDuration: TimeInterval,
        cancelledCues: Int = 0,
        trackingInterruptions: Int = 0,
        difficulty: TrainingDifficulty = .defaultValue
    ) {
        self.difficulty = difficulty
        completedAttempts = attempts.count
        hits = attempts.filter { $0.outcome.isHit }.count
        misses = attempts.count - hits
        spatialMisses = attempts.filter { $0.outcome == .miss }.count
        timeouts = attempts.filter { $0.outcome == .timeout }.count
        wrongPunches = attempts.filter { $0.outcome == .wrongPunch }.count
        self.cancelledCues = cancelledCues
        self.trackingInterruptions = trackingInterruptions
        guardReturnsCensored = attempts.filter {
            $0.punch != nil && $0.returnedToGuard == nil
        }.count
        hitRate = attempts.isEmpty ? 0 : Double(hits) / Double(attempts.count)

        let responseTimes = attempts
            .filter { $0.outcome == .hit }
            .compactMap(\.responseTime)
        averageResponseTime = responseTimes.isEmpty
            ? nil
            : responseTimes.reduce(0, +) / Double(responseTimes.count)

        let speeds = attempts.compactMap(\.relativeSpeed)
        averageRelativeSpeed = speeds.isEmpty
            ? nil
            : speeds.reduce(0, +) / Double(speeds.count)

        let guardReturns = attempts.compactMap(\.returnedToGuard)
        guardReturnConsistency = guardReturns.isEmpty
            ? nil
            : Double(guardReturns.filter { $0 }.count) / Double(guardReturns.count)
        self.pausedDuration = pausedDuration
    }
}
