//
//  TrajectoryAlignment.swift
//  Test
//
//  A license-clean, deterministic hand-path comparison utility.
//
//  IMPORTANT: This output is diagnostic only. It compares the geometric shape
//  of two observed fist paths after translation and reach normalization. It is
//  not a boxing-technique grade and provides no evidence about shoulders,
//  elbows, torso rotation, hips, feet, force, or injury risk.
//

import Foundation
import simd

/// One observed fist position on a monotonic clock.
nonisolated struct FistTrajectorySample: Equatable, Sendable {
    let timestamp: TimeInterval
    let position: SIMD3<Float>
}

/// Transparent provisional limits for accepting a complete out-and-back path.
///
/// Missing tracking gaps are never bridged. A discontinuity that exceeds
/// `maximumSampleGap` rejects the entire diagnostic; only accepted adjacent
/// observations are later resampled for density-neutral comparison.
nonisolated struct TrajectoryAlignmentConfiguration: Equatable, Sendable {
    let minimumSampleCount: Int
    let minimumDuration: TimeInterval
    let maximumSampleGap: TimeInterval
    let comparisonSampleCount: Int
    let maximumGuardBoundaryDistance: Float
    let minimumPeakExtension: Float
    let warpingBandFraction: Float
    let zeroScoreMeanDistance: Float

    nonisolated static let diagnosticDefault = TrajectoryAlignmentConfiguration()

    init(
        minimumSampleCount: Int = 7,
        minimumDuration: TimeInterval = 0.08,
        maximumSampleGap: TimeInterval = 0.20,
        comparisonSampleCount: Int = 49,
        maximumGuardBoundaryDistance: Float = 0.25,
        minimumPeakExtension: Float = 0.50,
        warpingBandFraction: Float = 0.30,
        zeroScoreMeanDistance: Float = 0.35
    ) {
        self.minimumSampleCount = max(2, minimumSampleCount)
        self.minimumDuration = max(0, minimumDuration)
        self.maximumSampleGap = max(0.001, maximumSampleGap)
        self.comparisonSampleCount = max(3, comparisonSampleCount)
        self.maximumGuardBoundaryDistance = max(
            0,
            maximumGuardBoundaryDistance
        )
        self.minimumPeakExtension = max(0, minimumPeakExtension)
        self.warpingBandFraction = min(1, max(0, warpingBandFraction))
        self.zeroScoreMeanDistance = max(
            Float.ulpOfOne,
            zeroScoreMeanDistance
        )
    }
}

/// Why a raw trajectory was refused before comparison.
nonisolated enum TrajectoryValidationIssue: Error, Equatable, Sendable {
    case invalidReach
    case nonFiniteGuard
    case tooFewSamples(actual: Int, minimum: Int)
    case nonFiniteTimestamp(index: Int)
    case nonFinitePosition(index: Int)
    case nonIncreasingTimestamp(index: Int)
    case unsafeSampleGap(index: Int)
    case durationTooShort
    case startOutsideGuard
    case endOutsideGuard
    case insufficientExtension
}

nonisolated enum TrajectoryAlignmentFailure: Error, Equatable, Sendable {
    case invalidReference(TrajectoryValidationIssue)
    case invalidAttempt(TrajectoryValidationIssue)
    case alignmentUnavailable
}

/// A speed-independent geometric comparison in reach-normalized units.
///
/// `shapeScore` is a transparent 0...1 visualization aid. It must not be
/// presented as authoritative coaching or combined with technique claims until
/// its thresholds have been calibrated on physical hardware with expert review.
nonisolated struct TrajectoryShapeDiagnostic: Equatable, Sendable {
    let shapeScore: Double
    let meanNormalizedDistance: Float
    let alignedPairCount: Int
    let maximumWarpFraction: Double
    let referenceSampleCount: Int
    let attemptSampleCount: Int
    let referenceDuration: TimeInterval
    let attemptDuration: TimeInterval
}

/// Validates, normalizes, and compares complete fist paths using constrained
/// Dynamic Time Warping (DTW).
///
/// Normalization removes world-space translation and reach scale:
/// `(position - calibratedGuard) / calibratedReach`. Each already-validated,
/// contiguous polyline is then sampled at equal cumulative-distance intervals
/// so camera/provider rate and execution pace do not become a shape score. DTW
/// permits local geometric variation while a Sakoe-Chiba-style band prevents
/// arbitrarily distant portions of the two paths from being matched.
nonisolated enum FistTrajectoryAlignment {
    static func compare(
        reference: [FistTrajectorySample],
        referenceGuard: SIMD3<Float>,
        referenceReach: Float,
        attempt: [FistTrajectorySample],
        attemptGuard: SIMD3<Float>,
        attemptReach: Float,
        configuration: TrajectoryAlignmentConfiguration = .diagnosticDefault
    ) -> Result<TrajectoryShapeDiagnostic, TrajectoryAlignmentFailure> {
        let normalizedReference: ValidatedTrajectory
        switch validateAndNormalize(
            reference,
            guardPosition: referenceGuard,
            reach: referenceReach,
            configuration: configuration
        ) {
        case .success(let trajectory):
            normalizedReference = trajectory
        case .failure(let issue):
            return .failure(.invalidReference(issue))
        }

        let normalizedAttempt: ValidatedTrajectory
        switch validateAndNormalize(
            attempt,
            guardPosition: attemptGuard,
            reach: attemptReach,
            configuration: configuration
        ) {
        case .success(let trajectory):
            normalizedAttempt = trajectory
        case .failure(let issue):
            return .failure(.invalidAttempt(issue))
        }

        guard let comparisonReference = resampleByArcLength(
            normalizedReference.points,
            count: configuration.comparisonSampleCount
        ), let comparisonAttempt = resampleByArcLength(
            normalizedAttempt.points,
            count: configuration.comparisonSampleCount
        ), let alignment = constrainedAlignment(
            reference: comparisonReference,
            attempt: comparisonAttempt,
            bandFraction: configuration.warpingBandFraction
        ) else {
            return .failure(.alignmentUnavailable)
        }

        let rawScore = 1 - alignment.meanDistance
            / configuration.zeroScoreMeanDistance
        let shapeScore = Double(min(1, max(0, rawScore)))

        return .success(
            TrajectoryShapeDiagnostic(
                shapeScore: shapeScore,
                meanNormalizedDistance: alignment.meanDistance,
                alignedPairCount: alignment.pairCount,
                maximumWarpFraction: alignment.maximumWarpFraction,
                referenceSampleCount: normalizedReference.points.count,
                attemptSampleCount: normalizedAttempt.points.count,
                referenceDuration: normalizedReference.duration,
                attemptDuration: normalizedAttempt.duration
            )
        )
    }

    /// Produces a fixed-density representation of an already validated path.
    /// This does not bridge missing tracking: the validation pass has already
    /// rejected every source interval above `maximumSampleGap`. Interpolation
    /// happens only within those accepted adjacent observations.
    private static func resampleByArcLength(
        _ points: [SIMD3<Float>],
        count: Int
    ) -> [SIMD3<Float>]? {
        guard points.count > 1, count > 1 else { return nil }

        var cumulativeDistance = [Float](
            repeating: 0,
            count: points.count
        )
        for index in 1..<points.count {
            let segmentLength = simd_distance(
                points[index - 1],
                points[index]
            )
            guard segmentLength.isFinite else { return nil }
            cumulativeDistance[index]
                = cumulativeDistance[index - 1] + segmentLength
        }

        guard let totalDistance = cumulativeDistance.last,
              totalDistance.isFinite,
              totalDistance > Float.ulpOfOne else {
            return nil
        }

        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)
        var upperIndex = 1

        for sampleIndex in 0..<count {
            let targetDistance = totalDistance
                * Float(sampleIndex) / Float(count - 1)
            while upperIndex < points.count - 1,
                  cumulativeDistance[upperIndex] < targetDistance {
                upperIndex += 1
            }

            let lowerIndex = upperIndex - 1
            let lowerDistance = cumulativeDistance[lowerIndex]
            let upperDistance = cumulativeDistance[upperIndex]
            let segmentDistance = upperDistance - lowerDistance

            if segmentDistance <= Float.ulpOfOne {
                result.append(points[upperIndex])
            } else {
                let fraction = (targetDistance - lowerDistance)
                    / segmentDistance
                result.append(
                    points[lowerIndex]
                        + (points[upperIndex] - points[lowerIndex])
                        * fraction
                )
            }
        }

        return result
    }

    private struct ValidatedTrajectory {
        let points: [SIMD3<Float>]
        let duration: TimeInterval
    }

    private struct Alignment {
        let meanDistance: Float
        let pairCount: Int
        let maximumWarpFraction: Double
    }

    private static func validateAndNormalize(
        _ samples: [FistTrajectorySample],
        guardPosition: SIMD3<Float>,
        reach: Float,
        configuration: TrajectoryAlignmentConfiguration
    ) -> Result<ValidatedTrajectory, TrajectoryValidationIssue> {
        guard reach.isFinite, reach > Float.ulpOfOne else {
            return .failure(.invalidReach)
        }
        guard guardPosition.hasFiniteComponents else {
            return .failure(.nonFiniteGuard)
        }
        guard samples.count >= configuration.minimumSampleCount else {
            return .failure(
                .tooFewSamples(
                    actual: samples.count,
                    minimum: configuration.minimumSampleCount
                )
            )
        }

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(samples.count)
        var previousTimestamp: TimeInterval?

        for (index, sample) in samples.enumerated() {
            guard sample.timestamp.isFinite else {
                return .failure(.nonFiniteTimestamp(index: index))
            }
            guard sample.position.hasFiniteComponents else {
                return .failure(.nonFinitePosition(index: index))
            }

            if let previousTimestamp {
                guard sample.timestamp > previousTimestamp else {
                    return .failure(.nonIncreasingTimestamp(index: index))
                }
                guard sample.timestamp - previousTimestamp
                        <= configuration.maximumSampleGap else {
                    return .failure(.unsafeSampleGap(index: index))
                }
            }

            let normalized = (sample.position - guardPosition) / reach
            guard normalized.hasFiniteComponents else {
                return .failure(.nonFinitePosition(index: index))
            }
            points.append(normalized)
            previousTimestamp = sample.timestamp
        }

        guard let firstTimestamp = samples.first?.timestamp,
              let lastTimestamp = samples.last?.timestamp else {
            return .failure(
                .tooFewSamples(
                    actual: samples.count,
                    minimum: configuration.minimumSampleCount
                )
            )
        }

        let duration = lastTimestamp - firstTimestamp
        guard duration >= configuration.minimumDuration else {
            return .failure(.durationTooShort)
        }
        guard let firstPoint = points.first,
              simd_length(firstPoint)
                <= configuration.maximumGuardBoundaryDistance else {
            return .failure(.startOutsideGuard)
        }
        guard let lastPoint = points.last,
              simd_length(lastPoint)
                <= configuration.maximumGuardBoundaryDistance else {
            return .failure(.endOutsideGuard)
        }

        let peakExtension = points.map { simd_length($0) }.max() ?? 0
        guard peakExtension >= configuration.minimumPeakExtension else {
            return .failure(.insufficientExtension)
        }

        return .success(
            ValidatedTrajectory(points: points, duration: duration)
        )
    }

    /// Banded DTW over equal-distance 3D samples. Total duration is deliberately
    /// absent from the cost function, making execution pace neutral to shape.
    private static func constrainedAlignment(
        reference: [SIMD3<Float>],
        attempt: [SIMD3<Float>],
        bandFraction: Float
    ) -> Alignment? {
        let referenceCount = reference.count
        let attemptCount = attempt.count
        guard referenceCount > 1, attemptCount > 1 else { return nil }

        let columnCount = attemptCount + 1
        let infinity = Float.infinity
        var costs = [Float](
            repeating: infinity,
            count: (referenceCount + 1) * columnCount
        )

        func index(_ referenceIndex: Int, _ attemptIndex: Int) -> Int {
            referenceIndex * columnCount + attemptIndex
        }

        costs[index(0, 0)] = 0
        let proportionalBand = Int(
            ceil(Double(max(referenceCount, attemptCount)) * Double(bandFraction))
        )
        // Unequal sequence lengths require at least their count difference to
        // keep the final cell reachable.
        let bandWidth = max(
            abs(referenceCount - attemptCount),
            proportionalBand
        )
        let slope = Double(attemptCount) / Double(referenceCount)

        for referenceIndex in 1...referenceCount {
            let center = Int((Double(referenceIndex) * slope).rounded())
            let lower = max(1, center - bandWidth)
            let upper = min(attemptCount, center + bandWidth)
            guard lower <= upper else { continue }

            for attemptIndex in lower...upper {
                let localDistance = simd_distance(
                    reference[referenceIndex - 1],
                    attempt[attemptIndex - 1]
                )
                let predecessor = min(
                    costs[index(referenceIndex - 1, attemptIndex - 1)],
                    costs[index(referenceIndex - 1, attemptIndex)],
                    costs[index(referenceIndex, attemptIndex - 1)]
                )
                if predecessor.isFinite {
                    costs[index(referenceIndex, attemptIndex)]
                        = predecessor + localDistance
                }
            }
        }

        guard costs[index(referenceCount, attemptCount)].isFinite else {
            return nil
        }

        var referenceIndex = referenceCount
        var attemptIndex = attemptCount
        var distanceTotal: Float = 0
        var pairCount = 0
        var maximumWarpFraction = 0.0

        while referenceIndex > 0, attemptIndex > 0 {
            distanceTotal += simd_distance(
                reference[referenceIndex - 1],
                attempt[attemptIndex - 1]
            )
            pairCount += 1

            let referenceFraction = Double(referenceIndex - 1)
                / Double(referenceCount - 1)
            let attemptFraction = Double(attemptIndex - 1)
                / Double(attemptCount - 1)
            maximumWarpFraction = max(
                maximumWarpFraction,
                abs(referenceFraction - attemptFraction)
            )

            let diagonal = costs[index(referenceIndex - 1, attemptIndex - 1)]
            let referenceOnly = costs[index(referenceIndex - 1, attemptIndex)]
            let attemptOnly = costs[index(referenceIndex, attemptIndex - 1)]

            // Prefer a diagonal step on ties so identical paths use the
            // shortest, least-distorted alignment.
            if diagonal <= referenceOnly, diagonal <= attemptOnly {
                referenceIndex -= 1
                attemptIndex -= 1
            } else if referenceOnly <= attemptOnly {
                referenceIndex -= 1
            } else {
                attemptIndex -= 1
            }
        }

        guard referenceIndex == 0,
              attemptIndex == 0,
              pairCount > 0 else {
            return nil
        }

        return Alignment(
            meanDistance: distanceTotal / Float(pairCount),
            pairCount: pairCount,
            maximumWarpFraction: maximumWarpFraction
        )
    }
}

private extension SIMD3 where Scalar == Float {
    nonisolated var hasFiniteComponents: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
