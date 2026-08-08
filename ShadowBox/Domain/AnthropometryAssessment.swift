//
//  AnthropometryAssessment.swift
//  Test
//
//  Deterministic, non-clinical quality checks for manually entered body
//  dimensions. These checks assess internal consistency only; they never
//  change or claim to improve ARKit tracking accuracy.
//

import Foundation

enum AnthropometryCheckLevel: Int, Comparable, Equatable, Sendable {
    case consistent
    case caution
    case recheck

    static func < (
        lhs: AnthropometryCheckLevel,
        rhs: AnthropometryCheckLevel
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum AnthropometryCheckKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case armSpanClosure
    case sideAsymmetry
    case armSpanToHeight
    case shoulderWidthToHeight
    case armLengthToHeight
}

struct AnthropometryCheck: Equatable, Sendable {
    var kind: AnthropometryCheckKind
    var level: AnthropometryCheckLevel
}

enum AnthropometryQualityGrade: Equatable, Sendable {
    case strong
    case usable
    case recheck
}

/// A transparent consistency report derived from one saved set of manual
/// measurements. Thresholds are intentionally broad heuristics for catching
/// entry/technique errors, not reference ranges or a diagnosis of anatomy.
struct AnthropometryAssessment: Equatable, Sendable {
    /// Arm span reconstructed from left arm + shoulder width + right arm.
    var reconstructedArmSpanMeters: Double
    /// Absolute disagreement between entered and reconstructed arm span.
    var armSpanClosureErrorMeters: Double
    var armSpanClosureErrorRatio: Double

    var armLengthAsymmetryMeters: Double
    var armLengthAsymmetryRatio: Double

    var armSpanToHeightRatio: Double
    var shoulderWidthToHeightRatio: Double
    var averageArmLengthToHeightRatio: Double

    /// The shortest of the left-arm, right-arm, and span-derived reach
    /// proxies. Live comfortable-reach capture remains authoritative.
    var conservativeReachMeters: Double

    /// A transparent heuristic allowance: 2 cm manual baseline plus half of
    /// span-closure disagreement and half of the side difference, capped at
    /// 15 cm. It is not a statistical confidence interval.
    var reachUncertaintyMeters: Double

    var checks: [AnthropometryCheck]
    var qualityGrade: AnthropometryQualityGrade

    init(profile: BoxerProfile) {
        reconstructedArmSpanMeters = profile.leftArmLengthMeters
            + profile.shoulderWidthMeters
            + profile.rightArmLengthMeters
        armSpanClosureErrorMeters = abs(
            profile.armSpanMeters - reconstructedArmSpanMeters
        )
        armSpanClosureErrorRatio = Self.safeRatio(
            armSpanClosureErrorMeters,
            profile.armSpanMeters
        )

        armLengthAsymmetryMeters = abs(
            profile.leftArmLengthMeters - profile.rightArmLengthMeters
        )
        armLengthAsymmetryRatio = Self.safeRatio(
            armLengthAsymmetryMeters,
            profile.averageArmLengthMeters
        )

        armSpanToHeightRatio = Self.safeRatio(
            profile.armSpanMeters,
            profile.heightMeters
        )
        shoulderWidthToHeightRatio = Self.safeRatio(
            profile.shoulderWidthMeters,
            profile.heightMeters
        )
        averageArmLengthToHeightRatio = Self.safeRatio(
            profile.averageArmLengthMeters,
            profile.heightMeters
        )

        let spanDerivedReach = max(
            0,
            (profile.armSpanMeters - profile.shoulderWidthMeters) / 2
        )
        conservativeReachMeters = max(
            0,
            min(
                profile.leftArmLengthMeters,
                profile.rightArmLengthMeters,
                spanDerivedReach
            )
        )
        reachUncertaintyMeters = min(
            0.15,
            0.02
                + (armSpanClosureErrorMeters / 2)
                + (armLengthAsymmetryMeters / 2)
        )

        checks = [
            AnthropometryCheck(
                kind: .armSpanClosure,
                level: Self.maximumLevel(
                    ratio: armSpanClosureErrorRatio,
                    consistentThrough: 0.03,
                    cautionThrough: 0.07
                )
            ),
            AnthropometryCheck(
                kind: .sideAsymmetry,
                level: Self.maximumLevel(
                    ratio: armLengthAsymmetryRatio,
                    consistentThrough: 0.05,
                    cautionThrough: 0.10
                )
            ),
            AnthropometryCheck(
                kind: .armSpanToHeight,
                level: Self.bandLevel(
                    value: armSpanToHeightRatio,
                    consistent: 0.85...1.15,
                    caution: 0.75...1.25
                )
            ),
            AnthropometryCheck(
                kind: .shoulderWidthToHeight,
                level: Self.bandLevel(
                    value: shoulderWidthToHeightRatio,
                    consistent: 0.12...0.30,
                    caution: 0.10...0.36
                )
            ),
            AnthropometryCheck(
                kind: .armLengthToHeight,
                level: Self.bandLevel(
                    value: averageArmLengthToHeightRatio,
                    consistent: 0.30...0.48,
                    caution: 0.25...0.55
                )
            ),
        ]

        let highestLevel = checks.map(\.level).max() ?? .recheck
        switch highestLevel {
        case .consistent:
            qualityGrade = .strong
        case .caution:
            qualityGrade = .usable
        case .recheck:
            qualityGrade = .recheck
        }
    }

    func check(_ kind: AnthropometryCheckKind) -> AnthropometryCheck {
        checks.first(where: { $0.kind == kind })
            ?? AnthropometryCheck(kind: kind, level: .recheck)
    }

    private static func safeRatio(_ numerator: Double, _ denominator: Double) -> Double {
        guard numerator.isFinite,
              denominator.isFinite,
              denominator > 0 else {
            return .infinity
        }
        return numerator / denominator
    }

    private static func maximumLevel(
        ratio: Double,
        consistentThrough: Double,
        cautionThrough: Double
    ) -> AnthropometryCheckLevel {
        guard ratio.isFinite else { return .recheck }
        if ratio <= consistentThrough { return .consistent }
        if ratio <= cautionThrough { return .caution }
        return .recheck
    }

    private static func bandLevel(
        value: Double,
        consistent: ClosedRange<Double>,
        caution: ClosedRange<Double>
    ) -> AnthropometryCheckLevel {
        guard value.isFinite else { return .recheck }
        if consistent.contains(value) { return .consistent }
        if caution.contains(value) { return .caution }
        return .recheck
    }
}

extension BoxerProfile {
    var anthropometryAssessment: AnthropometryAssessment {
        AnthropometryAssessment(profile: self)
    }
}
