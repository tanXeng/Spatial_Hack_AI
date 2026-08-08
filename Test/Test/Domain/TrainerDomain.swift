//
//  TrainerDomain.swift
//  Test
//
//  Persistable, scalar-only configuration for the broader Boxing Trainer MVP.
//  World-space transforms, hand samples, and participant traces deliberately do
//  not belong in these models.
//

import Foundation

enum TrainingFeature: String, CaseIterable, Codable, Equatable, Sendable {
    case anthropometry
    case auraPunch
    case reactiveStrike
}

enum ReactiveStrikeMode: String, CaseIterable, Codable, Equatable, Sendable {
    case virtualBoard
    case bagPreview
    case defense
}

enum ImmersiveExperience: String, CaseIterable, Codable, Equatable, Sendable {
    case anthropometryCalibration
    case auraPunch
    case reactiveBoard
    case bagPreview
    case defense

    var title: String {
        switch self {
        case .anthropometryCalibration:
            "Anthropometry Calibration"
        case .auraPunch:
            "Aura Punch"
        case .reactiveBoard:
            "Reactive Board"
        case .bagPreview:
            "Bag Preview"
        case .defense:
            "Defense Lab"
        }
    }
}

/// The display convention selected by the user. All stored measurements remain
/// canonical metres so changing this preference never changes persisted scale.
enum MeasurementUnit: String, CaseIterable, Codable, Equatable, Sendable {
    case metric
    case imperial

    var displayLengthSymbol: String {
        switch self {
        case .metric:
            "cm"
        case .imperial:
            "in"
        }
    }

    func meters(fromDisplayLength value: Double) -> Double {
        switch self {
        case .metric:
            value / 100
        case .imperial:
            value * 0.0254
        }
    }

    func displayLength(fromMeters meters: Double) -> Double {
        switch self {
        case .metric:
            meters * 100
        case .imperial:
            meters / 0.0254
        }
    }
}

enum BagType: String, CaseIterable, Codable, Equatable, Sendable {
    case hanging
    case freestanding
    case reflex
}

enum BagTargetLayout: String, CaseIterable, Codable, Equatable, Sendable {
    case twoTarget
    case fourTarget
    case sixTarget
}

enum TrainingProfileValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(profile: String, version: Int)
    case invalidChoice(field: String, value: String)
    case nonFinite(field: String)
    case outOfRange(field: String, minimum: Double, maximum: Double)
    case inconsistent(field: String, reason: String)
    case invalidName
}

extension TrainingProfileValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let profile, let version):
            "Unsupported \(profile) profile schema version \(version)."
        case .invalidChoice(let field, let value):
            "\(field) has the unsupported value ‘\(value)’."
        case .nonFinite(let field):
            "\(field) must be a finite number."
        case .outOfRange(let field, let minimum, let maximum):
            "\(field) must be between \(minimum) and \(maximum) metres."
        case .inconsistent(let field, let reason):
            "\(field) is inconsistent: \(reason)"
        case .invalidName:
            "The bag name must contain between 1 and 64 visible characters."
        }
    }
}

struct BoxerProfile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var preferredMeasurementUnit: MeasurementUnit

    /// Raw values intentionally mirror `Stance` without requiring that existing
    /// domain enum to become Codable in this isolated slice.
    var stanceRawValue: String
    /// Raw values intentionally mirror `HandSide` for the same reason.
    var dominantHandRawValue: String

    var heightMeters: Double
    var armSpanMeters: Double
    var leftArmLengthMeters: Double
    var rightArmLengthMeters: Double
    var shoulderWidthMeters: Double
    var measuredComfortableReachMeters: Double?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        preferredMeasurementUnit: MeasurementUnit = .metric,
        stanceRawValue: String = "orthodox",
        dominantHandRawValue: String = "right",
        heightMeters: Double,
        armSpanMeters: Double,
        leftArmLengthMeters: Double,
        rightArmLengthMeters: Double,
        shoulderWidthMeters: Double,
        measuredComfortableReachMeters: Double? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.preferredMeasurementUnit = preferredMeasurementUnit
        self.stanceRawValue = stanceRawValue
        self.dominantHandRawValue = dominantHandRawValue
        self.heightMeters = heightMeters
        self.armSpanMeters = armSpanMeters
        self.leftArmLengthMeters = leftArmLengthMeters
        self.rightArmLengthMeters = rightArmLengthMeters
        self.shoulderWidthMeters = shoulderWidthMeters
        self.measuredComfortableReachMeters = measuredComfortableReachMeters
    }

    var averageArmLengthMeters: Double {
        (leftArmLengthMeters + rightArmLengthMeters) / 2
    }

    /// Conservative shoulder-to-fist estimate derived from the two independent
    /// measurements. A live comfortable-reach capture remains the preferred
    /// value for placing targets.
    var estimatedReachMeters: Double {
        min(
            averageArmLengthMeters,
            max(0, (armSpanMeters - shoulderWidthMeters) / 2)
        )
    }

    var effectiveReachMeters: Double {
        measuredComfortableReachMeters ?? estimatedReachMeters
    }

    /// Determines whether a previously captured live reach still belongs to
    /// the body measurements being saved. A material edit invalidates that
    /// scalar instead of silently attaching stale calibration to a new fit.
    func hasEquivalentBodyMeasurements(
        to other: BoxerProfile,
        tolerance: Double = 0.000_5
    ) -> Bool {
        abs(heightMeters - other.heightMeters) <= tolerance
            && abs(armSpanMeters - other.armSpanMeters) <= tolerance
            && abs(leftArmLengthMeters - other.leftArmLengthMeters) <= tolerance
            && abs(rightArmLengthMeters - other.rightArmLengthMeters) <= tolerance
            && abs(shoulderWidthMeters - other.shoulderWidthMeters) <= tolerance
    }

    @discardableResult
    func validated() throws -> BoxerProfile {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TrainingProfileValidationError.unsupportedSchema(
                profile: "boxer",
                version: schemaVersion
            )
        }
        guard ["orthodox", "southpaw"].contains(stanceRawValue) else {
            throw TrainingProfileValidationError.invalidChoice(
                field: "Stance",
                value: stanceRawValue
            )
        }
        guard ["left", "right"].contains(dominantHandRawValue) else {
            throw TrainingProfileValidationError.invalidChoice(
                field: "Dominant hand",
                value: dominantHandRawValue
            )
        }

        try Self.validate(
            heightMeters,
            field: "Height",
            range: 0.90...2.50
        )
        try Self.validate(
            armSpanMeters,
            field: "Arm span",
            range: 0.80...2.70
        )
        try Self.validate(
            leftArmLengthMeters,
            field: "Left arm length",
            range: 0.25...1.10
        )
        try Self.validate(
            rightArmLengthMeters,
            field: "Right arm length",
            range: 0.25...1.10
        )
        try Self.validate(
            shoulderWidthMeters,
            field: "Shoulder width",
            range: 0.18...0.75
        )

        if let measuredComfortableReachMeters {
            try Self.validate(
                measuredComfortableReachMeters,
                field: "Measured comfortable reach",
                range: 0.15...1.10
            )
            let maximumPlausibleReach = max(
                leftArmLengthMeters,
                rightArmLengthMeters
            ) * 1.20
            guard measuredComfortableReachMeters <= maximumPlausibleReach else {
                throw TrainingProfileValidationError.inconsistent(
                    field: "Measured comfortable reach",
                    reason: "it exceeds the configured arm length"
                )
            }
        }

        let spanToHeightRatio = armSpanMeters / heightMeters
        guard (0.65...1.35).contains(spanToHeightRatio) else {
            throw TrainingProfileValidationError.inconsistent(
                field: "Arm span",
                reason: "it is not plausible relative to height"
            )
        }

        guard abs(leftArmLengthMeters - rightArmLengthMeters) <= 0.18 else {
            throw TrainingProfileValidationError.inconsistent(
                field: "Arm lengths",
                reason: "the left/right difference exceeds 0.18 metres"
            )
        }

        let reconstructedSpan = leftArmLengthMeters
            + shoulderWidthMeters
            + rightArmLengthMeters
        let spanTolerance = max(0.20, armSpanMeters * 0.15)
        guard abs(reconstructedSpan - armSpanMeters) <= spanTolerance else {
            throw TrainingProfileValidationError.inconsistent(
                field: "Arm span",
                reason: "it conflicts with the arm and shoulder measurements"
            )
        }

        return self
    }

    private static func validate(
        _ value: Double,
        field: String,
        range: ClosedRange<Double>
    ) throws {
        guard value.isFinite else {
            throw TrainingProfileValidationError.nonFinite(field: field)
        }
        guard range.contains(value) else {
            throw TrainingProfileValidationError.outOfRange(
                field: field,
                minimum: range.lowerBound,
                maximum: range.upperBound
            )
        }
    }
}

struct BagProfile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var name: String
    var type: BagType
    var targetLayout: BagTargetLayout
    var heightMeters: Double
    var diameterMeters: Double

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        name: String,
        type: BagType,
        targetLayout: BagTargetLayout,
        heightMeters: Double,
        diameterMeters: Double
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.type = type
        self.targetLayout = targetLayout
        self.heightMeters = heightMeters
        self.diameterMeters = diameterMeters
    }

    @discardableResult
    func validated() throws -> BagProfile {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TrainingProfileValidationError.unsupportedSchema(
                profile: "bag",
                version: schemaVersion
            )
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 64 else {
            throw TrainingProfileValidationError.invalidName
        }

        try Self.validateFinite(heightMeters, field: "Bag height")
        try Self.validateFinite(diameterMeters, field: "Bag diameter")

        let heightRange: ClosedRange<Double>
        let diameterRange: ClosedRange<Double>
        switch type {
        case .hanging:
            heightRange = 0.60...2.20
            diameterRange = 0.20...0.80
        case .freestanding:
            heightRange = 0.80...2.30
            diameterRange = 0.20...1.00
        case .reflex:
            heightRange = 0.90...2.20
            diameterRange = 0.12...0.50
        }

        guard heightRange.contains(heightMeters) else {
            throw TrainingProfileValidationError.outOfRange(
                field: "Bag height",
                minimum: heightRange.lowerBound,
                maximum: heightRange.upperBound
            )
        }
        guard diameterRange.contains(diameterMeters) else {
            throw TrainingProfileValidationError.outOfRange(
                field: "Bag diameter",
                minimum: diameterRange.lowerBound,
                maximum: diameterRange.upperBound
            )
        }

        return self
    }

    private static func validateFinite(_ value: Double, field: String) throws {
        guard value.isFinite else {
            throw TrainingProfileValidationError.nonFinite(field: field)
        }
    }
}
