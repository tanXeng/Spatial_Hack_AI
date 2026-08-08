//
//  TrajectoryAlignmentTests.swift
//  TestTests
//

import Foundation
import Testing
import simd
@testable import Test

struct TrajectoryAlignmentTests {
    private let guardPosition = SIMD3<Float>(0, 1.25, -0.30)

    @Test
    func identicalShapeIsInvariantToTranslationReachAndSpeed() throws {
        let fractions: [Float] = [0, 0.25, 0.50, 0.75, 1, 0.75, 0.50, 0.25, 0]
        let reference = trajectory(
            fractions: fractions,
            guardPosition: guardPosition,
            reach: 0.40,
            timestamps: [0, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40]
        )
        let translatedGuard = SIMD3<Float>(2.5, -0.4, 1.8)
        let slowerAttempt = trajectory(
            fractions: fractions,
            guardPosition: translatedGuard,
            reach: 0.72,
            timestamps: [10, 10.12, 10.24, 10.36, 10.48, 10.60, 10.72, 10.84, 10.96]
        )

        let diagnostic = try success(
            FistTrajectoryAlignment.compare(
                reference: reference,
                referenceGuard: guardPosition,
                referenceReach: 0.40,
                attempt: slowerAttempt,
                attemptGuard: translatedGuard,
                attemptReach: 0.72
            )
        )

        #expect(abs(diagnostic.shapeScore - 1) < 0.000_001)
        #expect(diagnostic.meanNormalizedDistance < 0.000_001)
        #expect(abs(diagnostic.referenceDuration - 0.40) < 0.000_001)
        #expect(abs(diagnostic.attemptDuration - 0.96) < 0.000_001)
    }

    @Test
    func identicalShapeIsInvariantToUnequalSamplingDensity() throws {
        let denseFractions: [Float] = (0...24).map { index in
            let progress = Float(index) / 24
            return progress <= 0.5 ? progress * 2 : (1 - progress) * 2
        }
        let sparseFractions: [Float] = [0, 0.20, 0.55, 1, 0.60, 0.25, 0]
        let reference = trajectory(
            fractions: denseFractions,
            guardPosition: guardPosition,
            reach: 0.50
        )
        let attempt = trajectory(
            fractions: sparseFractions,
            guardPosition: guardPosition,
            reach: 0.50,
            timestamps: [1, 1.04, 1.08, 1.12, 1.16, 1.20, 1.24]
        )

        let diagnostic = try success(FistTrajectoryAlignment.compare(
            reference: reference,
            referenceGuard: guardPosition,
            referenceReach: 0.50,
            attempt: attempt,
            attemptGuard: guardPosition,
            attemptReach: 0.50
        ))

        #expect(abs(diagnostic.shapeScore - 1) < 0.000_001)
        #expect(diagnostic.referenceSampleCount == 25)
        #expect(diagnostic.attemptSampleCount == 7)
    }

    @Test
    func lateralLoopScoresBelowStraightOutAndBackPath() throws {
        let fractions: [Float] = [0, 0.25, 0.50, 0.75, 1, 0.75, 0.50, 0.25, 0]
        let reference = trajectory(
            fractions: fractions,
            guardPosition: guardPosition,
            reach: 0.50
        )
        let clean = trajectory(
            fractions: fractions,
            guardPosition: guardPosition,
            reach: 0.50
        )
        var looped = clean
        for index in 2...6 {
            let original = looped[index]
            looped[index] = FistTrajectorySample(
                timestamp: original.timestamp,
                position: original.position + SIMD3<Float>(0.16, 0, 0)
            )
        }

        let cleanDiagnostic = try success(FistTrajectoryAlignment.compare(
            reference: reference,
            referenceGuard: guardPosition,
            referenceReach: 0.50,
            attempt: clean,
            attemptGuard: guardPosition,
            attemptReach: 0.50
        ))
        let loopedDiagnostic = try success(FistTrajectoryAlignment.compare(
            reference: reference,
            referenceGuard: guardPosition,
            referenceReach: 0.50,
            attempt: looped,
            attemptGuard: guardPosition,
            attemptReach: 0.50
        ))

        #expect(loopedDiagnostic.meanNormalizedDistance > cleanDiagnostic.meanNormalizedDistance)
        #expect(loopedDiagnostic.shapeScore < cleanDiagnostic.shapeScore)
    }

    @Test
    func temporalHoldingDoesNotChangeTheGeometricShapeScore() throws {
        let referenceFractions: [Float] = [0, 0.25, 0.50, 0.75, 1, 0.75, 0.50, 0.25, 0]
        let delayedFractions: [Float] = [0, 0, 0, 0.25, 0.50, 0.75, 1, 0.25, 0]
        let reference = trajectory(
            fractions: referenceFractions,
            guardPosition: guardPosition,
            reach: 0.50
        )
        let delayed = trajectory(
            fractions: delayedFractions,
            guardPosition: guardPosition,
            reach: 0.50
        )

        let diagonalOnly = try success(FistTrajectoryAlignment.compare(
            reference: reference,
            referenceGuard: guardPosition,
            referenceReach: 0.50,
            attempt: delayed,
            attemptGuard: guardPosition,
            attemptReach: 0.50,
            configuration: TrajectoryAlignmentConfiguration(
                warpingBandFraction: 0
            )
        ))
        let widerBand = try success(FistTrajectoryAlignment.compare(
            reference: reference,
            referenceGuard: guardPosition,
            referenceReach: 0.50,
            attempt: delayed,
            attemptGuard: guardPosition,
            attemptReach: 0.50,
            configuration: TrajectoryAlignmentConfiguration(
                warpingBandFraction: 0.50
            )
        ))

        #expect(diagonalOnly.maximumWarpFraction < 0.000_001)
        #expect(abs(diagonalOnly.shapeScore - 1) < 0.000_001)
        #expect(abs(widerBand.shapeScore - diagonalOnly.shapeScore) < 0.000_001)
    }

    @Test
    func duplicateAndDecreasingTimestampsAreRejected() {
        var duplicate = validTrajectory()
        duplicate[4] = FistTrajectorySample(
            timestamp: duplicate[3].timestamp,
            position: duplicate[4].position
        )
        expectAttemptIssue(.nonIncreasingTimestamp(index: 4), samples: duplicate)

        var decreasing = validTrajectory()
        decreasing[5] = FistTrajectorySample(
            timestamp: decreasing[4].timestamp - 0.01,
            position: decreasing[5].position
        )
        expectAttemptIssue(.nonIncreasingTimestamp(index: 5), samples: decreasing)
    }

    @Test
    func nonFiniteInputIsRejected() {
        var nonFiniteTime = validTrajectory()
        nonFiniteTime[2] = FistTrajectorySample(
            timestamp: .infinity,
            position: nonFiniteTime[2].position
        )
        expectAttemptIssue(.nonFiniteTimestamp(index: 2), samples: nonFiniteTime)

        var nonFinitePosition = validTrajectory()
        nonFinitePosition[3] = FistTrajectorySample(
            timestamp: nonFinitePosition[3].timestamp,
            position: SIMD3<Float>(.nan, 0, 0)
        )
        expectAttemptIssue(.nonFinitePosition(index: 3), samples: nonFinitePosition)

        let result = FistTrajectoryAlignment.compare(
            reference: validTrajectory(),
            referenceGuard: guardPosition,
            referenceReach: 0.50,
            attempt: validTrajectory(),
            attemptGuard: guardPosition,
            attemptReach: .nan
        )
        #expect(result == .failure(.invalidAttempt(.invalidReach)))
    }

    @Test
    func unsafeGapIsRejectedWithoutInterpolation() {
        var samples = validTrajectory()
        for index in 4..<samples.count {
            samples[index] = FistTrajectorySample(
                timestamp: samples[index].timestamp + 0.30,
                position: samples[index].position
            )
        }

        expectAttemptIssue(.unsafeSampleGap(index: 4), samples: samples)
    }

    @Test
    func insufficientCountAndDurationAreRejected() {
        let short = Array(validTrajectory().prefix(5))
        expectAttemptIssue(
            .tooFewSamples(actual: 5, minimum: 7),
            samples: short
        )

        let brief = trajectory(
            fractions: [0, 0.25, 0.50, 0.75, 1, 0.50, 0],
            guardPosition: guardPosition,
            reach: 0.50,
            timestamps: [0, 0.005, 0.010, 0.015, 0.020, 0.025, 0.030]
        )
        expectAttemptIssue(.durationTooShort, samples: brief)
    }

    @Test
    func incompleteOutAndBackCoverageIsRejected() {
        var startsAway = validTrajectory()
        startsAway[0] = FistTrajectorySample(
            timestamp: startsAway[0].timestamp,
            position: guardPosition + SIMD3<Float>(0, 0, -0.20)
        )
        expectAttemptIssue(.startOutsideGuard, samples: startsAway)

        var endsAway = validTrajectory()
        let lastIndex = endsAway.count - 1
        endsAway[lastIndex] = FistTrajectorySample(
            timestamp: endsAway[lastIndex].timestamp,
            position: guardPosition + SIMD3<Float>(0, 0, -0.20)
        )
        expectAttemptIssue(.endOutsideGuard, samples: endsAway)

        let underExtended = trajectory(
            fractions: [0, 0.10, 0.20, 0.30, 0.40, 0.20, 0],
            guardPosition: guardPosition,
            reach: 0.50
        )
        expectAttemptIssue(.insufficientExtension, samples: underExtended)
    }

    @Test
    func invalidReferenceIsDistinguishedFromInvalidAttempt() {
        let result = FistTrajectoryAlignment.compare(
            reference: [],
            referenceGuard: guardPosition,
            referenceReach: 0.50,
            attempt: validTrajectory(),
            attemptGuard: guardPosition,
            attemptReach: 0.50
        )

        #expect(result == .failure(.invalidReference(
            .tooFewSamples(actual: 0, minimum: 7)
        )))
    }

    private func validTrajectory() -> [FistTrajectorySample] {
        trajectory(
            fractions: [0, 0.25, 0.50, 0.75, 1, 0.75, 0.50, 0.25, 0],
            guardPosition: guardPosition,
            reach: 0.50
        )
    }

    private func trajectory(
        fractions: [Float],
        guardPosition: SIMD3<Float>,
        reach: Float,
        timestamps: [TimeInterval]? = nil
    ) -> [FistTrajectorySample] {
        let resolvedTimestamps = timestamps
            ?? fractions.indices.map { Double($0) * 0.05 }
        return zip(fractions, resolvedTimestamps).map { pair in
            let (fraction, timestamp) = pair
            return FistTrajectorySample(
                timestamp: timestamp,
                position: guardPosition + SIMD3<Float>(0, 0, -reach * fraction)
            )
        }
    }

    private func success(
        _ result: Result<TrajectoryShapeDiagnostic, TrajectoryAlignmentFailure>
    ) throws -> TrajectoryShapeDiagnostic {
        switch result {
        case .success(let diagnostic):
            diagnostic
        case .failure(let failure):
            Issue.record("Expected a trajectory diagnostic, got \(failure)")
            throw failure
        }
    }

    private func expectAttemptIssue(
        _ expected: TrajectoryValidationIssue,
        samples: [FistTrajectorySample]
    ) {
        let result = FistTrajectoryAlignment.compare(
            reference: validTrajectory(),
            referenceGuard: guardPosition,
            referenceReach: 0.50,
            attempt: samples,
            attemptGuard: guardPosition,
            attemptReach: 0.50
        )
        #expect(result == .failure(.invalidAttempt(expected)))
    }
}
