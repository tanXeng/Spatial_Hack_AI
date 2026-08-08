//
//  FunctionalCalibrationReport.swift
//  Test
//
//  Session-only scalar quality reporting for live functional-reach capture.
//  These provisional checks describe repeatability inside one capture session;
//  they are not anatomical, clinical, or device-accuracy measurements.
//

import Foundation

nonisolated enum FunctionalCalibrationGrade: Equatable, Sendable {
    case collecting
    case consistent
    case freshCaptureNeeded

    var title: String {
        switch self {
        case .collecting:
            "Collecting repetitions"
        case .consistent:
            "Repetitions consistent"
        case .freshCaptureNeeded:
            "Fresh capture needed"
        }
    }

    var isAccepted: Bool {
        self == .consistent
    }
}

/// Thresholds are intentionally named provisional. They are conservative MVP
/// interaction rules and must be tuned with on-device sessions before release.
struct FunctionalCalibrationThresholds: Equatable, Sendable {
    let requiredRepetitionCount: Int
    let absoluteSpreadFloorMeters: Float
    let relativeSpreadLimit: Float

    static let provisional = FunctionalCalibrationThresholds(
        requiredRepetitionCount: 2,
        absoluteSpreadFloorMeters: 0.05,
        relativeSpreadLimit: 0.12
    )

    func permittedSpread(for shorterReachMeters: Float) -> Float {
        max(
            absoluteSpreadFloorMeters,
            shorterReachMeters * relativeSpreadLimit
        )
    }
}

struct FunctionalCalibrationReport: Equatable, Sendable {
    let captureCount: Int
    let requiredCaptureCount: Int
    let absoluteSpreadMeters: Float?
    let relativeSpread: Float?
    let permittedSpreadMeters: Float?
    let conservativeReachMeters: Float?
    let grade: FunctionalCalibrationGrade
    let reasons: [String]

    static func evaluate(
        reachMeters: [Float],
        thresholds: FunctionalCalibrationThresholds = .provisional
    ) -> FunctionalCalibrationReport {
        let captures = Array(
            reachMeters
                .filter { $0.isFinite && $0 > 0 }
                .prefix(thresholds.requiredRepetitionCount)
        )
        let count = captures.count

        guard count >= thresholds.requiredRepetitionCount,
              let shorter = captures.min(),
              let longer = captures.max() else {
            let remaining = max(0, thresholds.requiredRepetitionCount - count)
            let reason = remaining == 1
                ? "Complete 1 more controlled extension-and-return with the same hand."
                : "Complete \(remaining) controlled extension-and-return repetitions with one hand."
            return FunctionalCalibrationReport(
                captureCount: count,
                requiredCaptureCount: thresholds.requiredRepetitionCount,
                absoluteSpreadMeters: nil,
                relativeSpread: nil,
                permittedSpreadMeters: nil,
                conservativeReachMeters: nil,
                grade: .collecting,
                reasons: [reason]
            )
        }

        let spread = max(0, longer - shorter)
        let relativeSpread = spread / max(shorter, Float.ulpOfOne)
        let permittedSpread = thresholds.permittedSpread(
            for: shorter
        )
        let accepted = spread <= permittedSpread

        return FunctionalCalibrationReport(
            captureCount: count,
            requiredCaptureCount: thresholds.requiredRepetitionCount,
            absoluteSpreadMeters: spread,
            relativeSpread: relativeSpread,
            permittedSpreadMeters: permittedSpread,
            conservativeReachMeters: accepted ? shorter : nil,
            grade: accepted ? .consistent : .freshCaptureNeeded,
            reasons: accepted
                ? [
                    "The two session captures are within the provisional repeatability limit.",
                    "The shorter capture sets the conservative training reach."
                ]
                : [
                    "The two captures differ by more than the larger of the provisional 5 cm floor and 12% allowance.",
                    "No reach value is accepted; start a fresh two-repetition capture."
                ]
        )
    }
}
