//
//  TrainingIntensityTests.swift
//  TestTests
//

import Foundation
import Testing
@testable import Test

struct TrainingIntensityAdvisorTests {
    @Test
    func difficultyClampsToOneThroughFiveAndPaceIsMonotonic() {
        #expect(TrainingDifficulty(clamping: -20) == .guided)
        #expect(TrainingDifficulty(clamping: 20) == .peak)

        let profiles = TrainingDifficulty.allCases.map(\.presentation)
        #expect(profiles.map(\.auraPathPointCount) == [15, 13, 11, 9, 7])
        #expect(profiles.map(\.boardCueDurationMultiplier)
            == [1.40, 1.20, 1, 0.82, 0.68])
        #expect(profiles.map(\.defenseCueDurationMultiplier)
            == [1.50, 1.25, 1, 0.82, 0.70])
    }

    @Test
    func strongCompleteSetSuggestsAtMostOneLevelUp() {
        let recommendation = TrainingIntensityAdvisor.recommendation(
            from: evidence(
                kind: .reactiveBoard,
                difficulty: .steady,
                score: 0.95,
                control: 0.90,
                responseRatio: 0.40
            )
        )

        #expect(recommendation.basedOn == .steady)
        #expect(recommendation.suggested == .balanced)
        #expect(recommendation.reason == .readyForFasterPace)
        #expect(recommendation.proposesChange)
        #expect(
            abs(recommendation.suggested.rawValue - recommendation.basedOn.rawValue)
                <= 1
        )
    }

    @Test
    func difficultSetSuggestsAtMostOneLevelDown() {
        let recommendation = TrainingIntensityAdvisor.recommendation(
            from: evidence(
                kind: .defense,
                difficulty: .sharp,
                score: 0.30,
                responseRatio: 0.95
            )
        )

        #expect(recommendation.suggested == .balanced)
        #expect(recommendation.reason == .reducePaceForControl)
        #expect(
            abs(recommendation.suggested.rawValue - recommendation.basedOn.rawValue)
                <= 1
        )
    }

    @Test
    func interruptionOverridesEvenStrongPerformanceAndHolds() {
        let recommendation = TrainingIntensityAdvisor.recommendation(
            from: evidence(
                kind: .auraPunch,
                difficulty: .balanced,
                score: 1,
                control: 1,
                completed: 3,
                minimum: 3,
                interruptions: 1
            )
        )

        #expect(recommendation.suggested == .balanced)
        #expect(recommendation.reason == .trackingInterrupted)
        #expect(!recommendation.proposesChange)
        #expect(recommendation.explanation.contains("tracking"))
    }

    @Test
    func incompleteSetHoldsForInsufficientEvidence() {
        let recommendation = TrainingIntensityAdvisor.recommendation(
            from: evidence(
                kind: .reactiveBoard,
                difficulty: .balanced,
                score: 1,
                control: 1,
                responseRatio: 0.20,
                completed: 2,
                minimum: 6
            )
        )

        #expect(recommendation.reason == .insufficientEvidence)
        #expect(recommendation.suggested == .balanced)
    }

    @Test
    func recommendationCannotExceedBoundaries() {
        let atMaximum = TrainingIntensityAdvisor.recommendation(
            from: evidence(
                kind: .auraPunch,
                difficulty: .peak,
                score: 1,
                control: 1,
                completed: 3,
                minimum: 3
            )
        )
        let atMinimum = TrainingIntensityAdvisor.recommendation(
            from: evidence(
                kind: .defense,
                difficulty: .guided,
                score: 0
            )
        )

        #expect(atMaximum.suggested == .peak)
        #expect(atMaximum.reason == .alreadyAtMaximum)
        #expect(atMinimum.suggested == .guided)
        #expect(atMinimum.reason == .alreadyAtMinimum)
    }

    private func evidence(
        kind: TrainingSetKind,
        difficulty: TrainingDifficulty,
        score: Double,
        control: Double? = nil,
        responseRatio: Double? = nil,
        completed: Int = 6,
        minimum: Int = 6,
        interruptions: Int = 0
    ) -> TrainingSetEvidence {
        TrainingSetEvidence(
            kind: kind,
            difficulty: difficulty,
            completedOpportunities: completed,
            minimumOpportunities: minimum,
            primaryScore: score,
            controlScore: control,
            responseTimeRatio: responseRatio,
            trackingInterruptions: interruptions
        )
    }
}

@MainActor
struct TrainingSessionSettingsTests {
    @Test
    func recommendationIsOptInAndNeverAutoApplies() {
        let settings = TrainingSessionSettings(difficulty: .steady)
        let evidence = TrainingSetEvidence(
            kind: .auraPunch,
            difficulty: .steady,
            completedOpportunities: 3,
            minimumOpportunities: 3,
            primaryScore: 0.95,
            controlScore: 0.90,
            responseTimeRatio: nil,
            trackingInterruptions: 0
        )

        settings.consider(evidence)
        #expect(settings.recommendation == nil)
        #expect(settings.difficulty == .steady)

        settings.setRecommendationsEnabled(true)
        settings.consider(evidence)
        #expect(settings.recommendation?.suggested == .balanced)
        #expect(settings.difficulty == .steady)

        settings.applyRecommendation()
        #expect(settings.difficulty == .balanced)
        #expect(settings.recommendation == nil)
    }

    @Test
    func manualSelectionAndOptOutClearStaleProposal() {
        let settings = TrainingSessionSettings(difficulty: .balanced)
        settings.setRecommendationsEnabled(true)
        settings.consider(TrainingSetEvidence(
            kind: .defense,
            difficulty: .balanced,
            completedOpportunities: 6,
            minimumOpportunities: 6,
            primaryScore: 1,
            controlScore: nil,
            responseTimeRatio: 0.30,
            trackingInterruptions: 0
        ))
        #expect(settings.recommendation != nil)

        settings.selectDifficulty(.guided)
        #expect(settings.difficulty == .guided)
        #expect(settings.recommendation == nil)

        settings.consider(TrainingSetEvidence(
            kind: .defense,
            difficulty: .guided,
            completedOpportunities: 6,
            minimumOpportunities: 6,
            primaryScore: 1,
            controlScore: nil,
            responseTimeRatio: 0.30,
            trackingInterruptions: 0
        ))
        settings.setRecommendationsEnabled(false)
        #expect(settings.recommendation == nil)
    }

    @Test
    func soundFeedbackDefaultsOnForSessionOnlyInstances() {
        let settings = TrainingSessionSettings()
        #expect(settings.soundFeedbackEnabled)

        settings.setSoundFeedbackEnabled(false)
        #expect(!settings.soundFeedbackEnabled)
    }

    @Test
    func explicitPresentationPreferencesPersistWithoutRecommendationEvidence() {
        let suiteName = "TrainingSessionSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keys = TrainingSessionSettingsKeys(
            difficulty: "test.difficulty",
            recommendationsEnabled: "test.recommendations",
            soundFeedbackEnabled: "test.sound"
        )

        let first = TrainingSessionSettings(defaults: defaults, keys: keys)
        first.selectDifficulty(.sharp)
        first.setRecommendationsEnabled(true)
        first.setSoundFeedbackEnabled(false)
        first.consider(TrainingSetEvidence(
            kind: .auraPunch,
            difficulty: .sharp,
            completedOpportunities: 3,
            minimumOpportunities: 3,
            primaryScore: 0.95,
            controlScore: 0.90,
            responseTimeRatio: nil,
            trackingInterruptions: 0
        ))
        #expect(first.recommendation != nil)

        first.applyRecommendation()
        #expect(first.difficulty == .peak)

        let reloaded = TrainingSessionSettings(defaults: defaults, keys: keys)
        #expect(reloaded.difficulty == .peak)
        #expect(reloaded.recommendationsEnabled)
        #expect(!reloaded.soundFeedbackEnabled)
        #expect(reloaded.recommendation == nil)
    }

    @Test
    func staleSummaryCannotRecommendOrApplyAcrossManualLevelChanges() {
        let settings = TrainingSessionSettings(difficulty: .guided)
        settings.setRecommendationsEnabled(true)

        settings.consider(TrainingSetEvidence(
            kind: .auraPunch,
            difficulty: .balanced,
            completedOpportunities: 3,
            minimumOpportunities: 3,
            primaryScore: 0.95,
            controlScore: 0.90,
            responseTimeRatio: nil,
            trackingInterruptions: 0
        ))

        #expect(settings.recommendation == nil)
        settings.applyRecommendation()
        #expect(settings.difficulty == .guided)
    }
}
