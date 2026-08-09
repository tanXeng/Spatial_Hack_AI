import Foundation
import simd

/// Whether a value came directly from tracking or from a documented derivation.
nonisolated enum MeasurementQuality: String, Hashable, Sendable, Codable {
    case measured
    case inferred
}

/// Typed admission failures for the validated tracking boundary.
nonisolated enum TrackingRejectionReason: Error, Hashable, Sendable, Codable {
    case nonFinite(field: String)
    case invalidRange(field: String)
    case untracked(side: BodySide)
    case stale(age: TimeInterval, maximumAge: TimeInterval)
    case overSkewed(skew: TimeInterval, maximumSkew: TimeInterval)
    case generationMismatch(expected: UInt64, actual: UInt64)
    case missingHandEvidence
    case duplicateHand(side: BodySide)
    case invalidPhaseOrder
}

/// A hand sample admitted after tracking, finiteness, and range validation.
nonisolated struct ValidatedHandObservation: Hashable, Sendable, Codable {
    private enum CodingKeys: String, CodingKey {
        case side
        case wristPosition
        case wristOrientation
        case elbowPosition
        case elbowQuality
        case fistPosition
        case fistState
        case fistClosureRatio
        case timestamp
        case generation
        case quality
    }

    let side: BodySide
    let wristPosition: SIMD3<Float>
    let wristOrientation: SIMD4<Float>
    let elbowPosition: SIMD3<Float>?
    let elbowQuality: MeasurementQuality?
    let fistPosition: SIMD3<Float>
    let fistState: TrackedFistState
    let fistClosureRatio: Float
    let timestamp: TimeInterval
    let generation: UInt64
    let quality: MeasurementQuality

    init(
        side: BodySide,
        isTracked: Bool,
        wristPosition: SIMD3<Float>,
        wristOrientation: SIMD4<Float>,
        elbowPosition: SIMD3<Float>?,
        elbowQuality: MeasurementQuality?,
        fistPosition: SIMD3<Float>,
        fistState: TrackedFistState,
        fistClosureRatio: Float,
        timestamp: TimeInterval,
        generation: UInt64,
        quality: MeasurementQuality
    ) throws {
        guard isTracked else { throw TrackingRejectionReason.untracked(side: side) }
        try TrackingEvidenceValidation.requireFinite(wristPosition, field: "wristPosition")
        try TrackingEvidenceValidation.requireFinite(wristOrientation, field: "wristOrientation")
        try TrackingEvidenceValidation.requireOrientation(wristOrientation, field: "wristOrientation")
        if let elbowPosition {
            try TrackingEvidenceValidation.requireFinite(elbowPosition, field: "elbowPosition")
            guard elbowQuality != nil else {
                throw TrackingRejectionReason.invalidRange(field: "elbowQuality")
            }
        } else if elbowQuality != nil {
            throw TrackingRejectionReason.invalidRange(field: "elbowQuality")
        }
        try TrackingEvidenceValidation.requireFinite(fistPosition, field: "fistPosition")
        try TrackingEvidenceValidation.requireFinite(fistClosureRatio, field: "fistClosureRatio")
        guard (0...1).contains(fistClosureRatio) else {
            throw TrackingRejectionReason.invalidRange(field: "fistClosureRatio")
        }
        try TrackingEvidenceValidation.requireFinite(timestamp, field: "timestamp")
        guard timestamp >= 0 else {
            throw TrackingRejectionReason.invalidRange(field: "timestamp")
        }

        self.side = side
        self.wristPosition = wristPosition
        self.wristOrientation = wristOrientation
        self.elbowPosition = elbowPosition
        self.elbowQuality = elbowQuality
        self.fistPosition = fistPosition
        self.fistState = fistState
        self.fistClosureRatio = fistClosureRatio
        self.timestamp = timestamp
        self.generation = generation
        self.quality = quality
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            side: values.decode(BodySide.self, forKey: .side),
            isTracked: true,
            wristPosition: values.decode(SIMD3<Float>.self, forKey: .wristPosition),
            wristOrientation: values.decode(SIMD4<Float>.self, forKey: .wristOrientation),
            elbowPosition: values.decodeIfPresent(SIMD3<Float>.self, forKey: .elbowPosition),
            elbowQuality: values.decodeIfPresent(MeasurementQuality.self, forKey: .elbowQuality),
            fistPosition: values.decode(SIMD3<Float>.self, forKey: .fistPosition),
            fistState: values.decode(TrackedFistState.self, forKey: .fistState),
            fistClosureRatio: values.decode(Float.self, forKey: .fistClosureRatio),
            timestamp: values.decode(TimeInterval.self, forKey: .timestamp),
            generation: values.decode(UInt64.self, forKey: .generation),
            quality: values.decode(MeasurementQuality.self, forKey: .quality)
        )
    }
}

/// A time-coherent device/hand snapshot from one tracking generation.
nonisolated struct ValidatedTrackingSnapshot: Hashable, Sendable {
    static let hardMaximumAge: TimeInterval = 0.1
    static let hardMaximumSkew: TimeInterval = 0.033
    static let defaultMaximumAge = hardMaximumAge
    static let defaultMaximumSkew: TimeInterval = 0.03

    let generation: UInt64
    let capturedAt: TimeInterval
    let devicePosition: SIMD3<Float>
    let deviceOrientation: SIMD4<Float>
    let deviceTimestamp: TimeInterval
    let deviceQuality: MeasurementQuality
    let hands: [ValidatedHandObservation]

    init(
        generation: UInt64,
        capturedAt: TimeInterval,
        now: TimeInterval,
        devicePosition: SIMD3<Float>,
        deviceOrientation: SIMD4<Float>,
        deviceTimestamp: TimeInterval,
        deviceQuality: MeasurementQuality,
        hands: [ValidatedHandObservation],
        maximumAge: TimeInterval = Self.defaultMaximumAge,
        maximumSkew: TimeInterval = Self.defaultMaximumSkew
    ) throws {
        try TrackingEvidenceValidation.requireFinite(capturedAt, field: "capturedAt")
        try TrackingEvidenceValidation.requireFinite(now, field: "now")
        try TrackingEvidenceValidation.requireFinite(devicePosition, field: "devicePosition")
        try TrackingEvidenceValidation.requireFinite(deviceOrientation, field: "deviceOrientation")
        try TrackingEvidenceValidation.requireOrientation(deviceOrientation, field: "deviceOrientation")
        try TrackingEvidenceValidation.requireFinite(deviceTimestamp, field: "deviceTimestamp")
        try TrackingEvidenceValidation.requireFinite(maximumAge, field: "maximumAge")
        try TrackingEvidenceValidation.requireFinite(maximumSkew, field: "maximumSkew")
        guard capturedAt >= 0, now >= 0, deviceTimestamp >= 0 else {
            throw TrackingRejectionReason.invalidRange(field: "timestamp")
        }
        guard (0...Self.hardMaximumAge).contains(maximumAge) else {
            throw TrackingRejectionReason.invalidRange(field: "maximumAge")
        }
        guard (0...Self.hardMaximumSkew).contains(maximumSkew) else {
            throw TrackingRejectionReason.invalidRange(field: "maximumSkew")
        }
        guard !hands.isEmpty else { throw TrackingRejectionReason.missingHandEvidence }

        var seenSides: Set<BodySide> = []
        for hand in hands {
            guard seenSides.insert(hand.side).inserted else {
                throw TrackingRejectionReason.duplicateHand(side: hand.side)
            }
            guard hand.generation == generation else {
                throw TrackingRejectionReason.generationMismatch(
                    expected: generation,
                    actual: hand.generation
                )
            }
        }

        try Self.requireFresh(
            timestamp: capturedAt,
            field: "capturedAt",
            now: now,
            maximumAge: maximumAge
        )
        try Self.requireFresh(
            timestamp: deviceTimestamp,
            field: "deviceTimestamp",
            now: now,
            maximumAge: maximumAge
        )
        for hand in hands {
            try Self.requireFresh(
                timestamp: hand.timestamp,
                field: "handTimestamp.\(hand.side.rawValue)",
                now: now,
                maximumAge: maximumAge
            )
        }

        let timestamps = hands.map(\.timestamp) + [deviceTimestamp]
        let earliest = timestamps.min() ?? deviceTimestamp
        let latest = timestamps.max() ?? deviceTimestamp
        let skew = latest - earliest
        guard skew <= maximumSkew else {
            throw TrackingRejectionReason.overSkewed(skew: skew, maximumSkew: maximumSkew)
        }

        self.generation = generation
        self.capturedAt = capturedAt
        self.devicePosition = devicePosition
        self.deviceOrientation = deviceOrientation
        self.deviceTimestamp = deviceTimestamp
        self.deviceQuality = deviceQuality
        self.hands = hands.sorted { $0.side == .left && $1.side == .right }
    }

    func hand(for side: BodySide) -> ValidatedHandObservation? {
        hands.first { $0.side == side }
    }

    private static func requireFresh(
        timestamp: TimeInterval,
        field: String,
        now: TimeInterval,
        maximumAge: TimeInterval
    ) throws {
        guard timestamp <= now else {
            throw TrackingRejectionReason.invalidRange(field: field)
        }
        let age = now - timestamp
        guard age <= maximumAge else {
            throw TrackingRejectionReason.stale(age: age, maximumAge: maximumAge)
        }
    }

}

/// Serializable snapshot data that must re-enter admission before becoming trusted evidence.
nonisolated struct UntrustedTrackingSnapshot: Hashable, Sendable, Codable {
    let generation: UInt64
    let capturedAt: TimeInterval
    let devicePosition: SIMD3<Float>
    let deviceOrientation: SIMD4<Float>
    let deviceTimestamp: TimeInterval
    let deviceQuality: MeasurementQuality
    let hands: [ValidatedHandObservation]

    init(_ snapshot: ValidatedTrackingSnapshot) {
        generation = snapshot.generation
        capturedAt = snapshot.capturedAt
        devicePosition = snapshot.devicePosition
        deviceOrientation = snapshot.deviceOrientation
        deviceTimestamp = snapshot.deviceTimestamp
        deviceQuality = snapshot.deviceQuality
        hands = snapshot.hands
    }

    func validated(
        now: TimeInterval,
        maximumAge: TimeInterval = ValidatedTrackingSnapshot.defaultMaximumAge,
        maximumSkew: TimeInterval = ValidatedTrackingSnapshot.defaultMaximumSkew
    ) throws -> ValidatedTrackingSnapshot {
        try ValidatedTrackingSnapshot(
            generation: generation,
            capturedAt: capturedAt,
            now: now,
            devicePosition: devicePosition,
            deviceOrientation: deviceOrientation,
            deviceTimestamp: deviceTimestamp,
            deviceQuality: deviceQuality,
            hands: hands,
            maximumAge: maximumAge,
            maximumSkew: maximumSkew
        )
    }
}

/// Accepted semantic evidence for one complete outbound-land-return punch.
nonisolated struct ValidatedPunchEvidence: Hashable, Sendable, Codable {
    private enum CodingKeys: String, CodingKey {
        case technique
        case stance
        case side
        case generation
        case startedAt
        case landedAt
        case returnedAt
        case outboundTravel
        case landingError
        case returnError
        case trackedFraction
        case quality
    }

    let technique: Technique
    let stance: Stance
    let side: BodySide
    let generation: UInt64
    let startedAt: TimeInterval
    let landedAt: TimeInterval
    let returnedAt: TimeInterval
    let outboundTravel: Float
    let landingError: Float
    let returnError: Float
    let trackedFraction: Float
    let quality: MeasurementQuality

    init(
        technique: Technique,
        stance: Stance,
        side: BodySide,
        generation: UInt64,
        startedAt: TimeInterval,
        landedAt: TimeInterval,
        returnedAt: TimeInterval,
        outboundTravel: Float,
        landingError: Float,
        returnError: Float,
        trackedFraction: Float,
        quality: MeasurementQuality
    ) throws {
        try TrackingEvidenceValidation.requireFinite(startedAt, field: "startedAt")
        try TrackingEvidenceValidation.requireFinite(landedAt, field: "landedAt")
        try TrackingEvidenceValidation.requireFinite(returnedAt, field: "returnedAt")
        try TrackingEvidenceValidation.requireFinite(outboundTravel, field: "outboundTravel")
        try TrackingEvidenceValidation.requireFinite(landingError, field: "landingError")
        try TrackingEvidenceValidation.requireFinite(returnError, field: "returnError")
        try TrackingEvidenceValidation.requireFinite(trackedFraction, field: "trackedFraction")
        guard startedAt >= 0, startedAt < landedAt, landedAt < returnedAt else {
            throw TrackingRejectionReason.invalidPhaseOrder
        }
        guard outboundTravel > 0 else {
            throw TrackingRejectionReason.invalidRange(field: "outboundTravel")
        }
        guard landingError >= 0 else {
            throw TrackingRejectionReason.invalidRange(field: "landingError")
        }
        guard returnError >= 0 else {
            throw TrackingRejectionReason.invalidRange(field: "returnError")
        }
        guard (0...1).contains(trackedFraction) else {
            throw TrackingRejectionReason.invalidRange(field: "trackedFraction")
        }

        self.technique = technique
        self.stance = stance
        self.side = side
        self.generation = generation
        self.startedAt = startedAt
        self.landedAt = landedAt
        self.returnedAt = returnedAt
        self.outboundTravel = outboundTravel
        self.landingError = landingError
        self.returnError = returnError
        self.trackedFraction = trackedFraction
        self.quality = quality
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            technique: values.decode(Technique.self, forKey: .technique),
            stance: values.decode(Stance.self, forKey: .stance),
            side: values.decode(BodySide.self, forKey: .side),
            generation: values.decode(UInt64.self, forKey: .generation),
            startedAt: values.decode(TimeInterval.self, forKey: .startedAt),
            landedAt: values.decode(TimeInterval.self, forKey: .landedAt),
            returnedAt: values.decode(TimeInterval.self, forKey: .returnedAt),
            outboundTravel: values.decode(Float.self, forKey: .outboundTravel),
            landingError: values.decode(Float.self, forKey: .landingError),
            returnError: values.decode(Float.self, forKey: .returnError),
            trackedFraction: values.decode(Float.self, forKey: .trackedFraction),
            quality: values.decode(MeasurementQuality.self, forKey: .quality)
        )
    }
}

nonisolated private enum TrackingEvidenceValidation {
    static func requireFinite(_ value: Float, field: String) throws {
        guard value.isFinite else { throw TrackingRejectionReason.nonFinite(field: field) }
    }

    static func requireFinite(_ value: TimeInterval, field: String) throws {
        guard value.isFinite else { throw TrackingRejectionReason.nonFinite(field: field) }
    }

    static func requireFinite(_ value: SIMD3<Float>, field: String) throws {
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
            throw TrackingRejectionReason.nonFinite(field: field)
        }
    }

    static func requireFinite(_ value: SIMD4<Float>, field: String) throws {
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite, value.w.isFinite else {
            throw TrackingRejectionReason.nonFinite(field: field)
        }
    }

    static func requireOrientation(_ value: SIMD4<Float>, field: String) throws {
        let lengthSquared = value.x * value.x + value.y * value.y
            + value.z * value.z + value.w * value.w
        guard lengthSquared > Float.ulpOfOne else {
            throw TrackingRejectionReason.invalidRange(field: field)
        }
    }
}
