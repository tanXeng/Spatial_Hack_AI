//
//  TrainingSessionSettings.swift
//  Test
//
//  Local presentation preferences plus session-only recommendation evidence.
//  No result, motion trace, transform, or recommendation is persisted.
//

import Foundation
import Observation

struct TrainingSessionSettingsKeys: Equatable, Sendable {
    var difficulty: String
    var recommendationsEnabled: String
    var soundFeedbackEnabled: String

    nonisolated static let standard = TrainingSessionSettingsKeys(
        difficulty: "shadowbox.training.presentation-level.v1",
        recommendationsEnabled: "shadowbox.training.recommendations-enabled.v1",
        soundFeedbackEnabled: "shadowbox.training.sound-enabled.v1"
    )
}

@MainActor
@Observable
final class TrainingSessionSettings {
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let keys: TrainingSessionSettingsKeys

    private(set) var difficulty: TrainingDifficulty
    private(set) var recommendationsEnabled = false
    private(set) var soundFeedbackEnabled = true
    private(set) var recommendation: TrainingIntensityRecommendation?

    /// Session-only initializer used by deterministic tests and previews.
    init(difficulty: TrainingDifficulty = .defaultValue) {
        defaults = nil
        keys = .standard
        self.difficulty = difficulty
    }

    /// App initializer. Only explicit UI preferences are stored locally;
    /// aggregate evidence and recommendations remain memory-only.
    init(
        defaults: UserDefaults,
        keys: TrainingSessionSettingsKeys = .standard
    ) {
        self.defaults = defaults
        self.keys = keys

        if let storedLevel = defaults.object(forKey: keys.difficulty) as? Int {
            difficulty = TrainingDifficulty(clamping: storedLevel)
        } else {
            difficulty = .defaultValue
        }
        recommendationsEnabled = defaults.object(
            forKey: keys.recommendationsEnabled
        ) as? Bool ?? false
        soundFeedbackEnabled = defaults.object(
            forKey: keys.soundFeedbackEnabled
        ) as? Bool ?? true
    }

    func selectDifficulty(_ difficulty: TrainingDifficulty) {
        self.difficulty = difficulty
        recommendation = nil
        defaults?.set(difficulty.rawValue, forKey: keys.difficulty)
    }

    func setRecommendationsEnabled(_ enabled: Bool) {
        recommendationsEnabled = enabled
        defaults?.set(enabled, forKey: keys.recommendationsEnabled)
        if !enabled {
            recommendation = nil
        }
    }

    func setSoundFeedbackEnabled(_ enabled: Bool) {
        soundFeedbackEnabled = enabled
        defaults?.set(enabled, forKey: keys.soundFeedbackEnabled)
    }

    func consider(_ evidence: TrainingSetEvidence) {
        guard recommendationsEnabled,
              evidence.difficulty == difficulty else {
            recommendation = nil
            return
        }
        recommendation = TrainingIntensityAdvisor.recommendation(from: evidence)
    }

    /// A recommendation is a user-visible proposal only. This explicit action
    /// is the sole path that changes the shared selection from a proposal.
    func applyRecommendation() {
        guard recommendationsEnabled,
              let recommendation,
              difficulty == recommendation.basedOn,
              recommendation.proposesChange else {
            self.recommendation = nil
            return
        }
        difficulty = recommendation.suggested
        defaults?.set(difficulty.rawValue, forKey: keys.difficulty)
        self.recommendation = nil
    }
}
