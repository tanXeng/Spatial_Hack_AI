//
//  AuraCoachingFeedbackTests.swift
//  TestTests
//

import Foundation
import Testing
import simd
@testable import Test

@MainActor
struct AuraCoachingFeedbackTests {
    @Test
    func coachingFocusesOnTheWeakestObservedHandMetric() {
        let pathCue = AuraCoachingFeedback.cue(for: result(
            path: 0.30,
            extensionScore: 0.90,
            extensionRatio: 1,
            guardScore: 0.80
        ))
        #expect(pathCue.focus.contains("ghost-glove path"))
        #expect(!pathCue.focus.localizedCaseInsensitiveContains("speed up"))

        let shortCue = AuraCoachingFeedback.cue(for: result(
            path: 0.90,
            extensionScore: 0.35,
            extensionRatio: 0.70,
            guardScore: 0.80
        ))
        #expect(shortCue.focus.contains("target depth"))
        #expect(shortCue.focus.contains("without adding speed"))

        let guardCue = AuraCoachingFeedback.cue(for: result(
            path: 0.90,
            extensionScore: 0.85,
            extensionRatio: 1,
            guardScore: 0.25
        ))
        #expect(guardCue.focus.contains("non-punching hand"))

        let lowCue = AuraCoachingFeedback.cue(for: result(
            path: 0.30,
            extensionScore: 0.20,
            extensionRatio: 0.70,
            guardScore: 0.10
        ))
        #expect(lowCue.positive == "You completed a controlled extension and return.")
    }

    private func result(
        path: Double,
        extensionScore: Double,
        extensionRatio: Double,
        guardScore: Double
    ) -> AuraPunchRepetitionResult {
        AuraPunchRepetitionResult(
            repetition: 1,
            punch: .jab,
            expectedHand: .left,
            startedAt: 0,
            completedAt: 1,
            averagePathDeviation: 0.02,
            pathScore: path,
            extensionRatio: extensionRatio,
            extensionScore: extensionScore,
            peakSpeed: 0.5,
            relativePeakSpeed: 1,
            speedScore: 1,
            otherHandGuardScore: guardScore,
            trajectoryShapeScore: nil,
            overallScore: path * 0.45
                + extensionScore * 0.30
                + guardScore * 0.25
        )
    }
}
