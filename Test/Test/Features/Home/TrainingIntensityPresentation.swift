//
//  TrainingIntensityPresentation.swift
//  Test
//
//  Shared local preferences and opt-in, session-only recommendation UI.
//

import SwiftUI

extension ContentView {
    func trainingIntensityCard(for setKind: TrainingSetKind) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Training intensity", systemImage: "dial.medium")
                    .font(.headline)
                Spacer()
                Text("Level \(trainingSettings.difficulty.rawValue) · \(trainingSettings.difficulty.title)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            Slider(
                value: Binding(
                    get: { Double(trainingSettings.difficulty.rawValue) },
                    set: { value in
                        trainingSettings.selectDifficulty(
                            TrainingDifficulty(clamping: Int(value.rounded()))
                        )
                    }
                ),
                in: 1...5,
                step: 1
            ) {
                Text("Difficulty")
            } minimumValueLabel: {
                Text("1").font(.caption.monospacedDigit())
            } maximumValueLabel: {
                Text("5").font(.caption.monospacedDigit())
            }
            .disabled(intensitySelectionLocked)

            Text(trainingSettings.difficulty.paceDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Difficulty changes cue pace and Aura path density only. Reach, movement thresholds, target size, scoring, and safety rules stay fixed.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle(
                "Spatial sound feedback",
                isOn: Binding(
                    get: { trainingSettings.soundFeedbackEnabled },
                    set: { trainingSettings.setSoundFeedbackEnabled($0) }
                )
            )

            Toggle(
                "Suggest my next level after a complete set",
                isOn: Binding(
                    get: { trainingSettings.recommendationsEnabled },
                    set: { enabled in
                        trainingSettings.setRecommendationsEnabled(enabled)
                        if enabled {
                            refreshIntensityRecommendation(for: setKind)
                        }
                    }
                )
            )

            Label(
                "Explainable rules-based MVP — not ML, does not learn from you, and never changes the level automatically.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Level, sound, and the opt-in setting stay on this device. Results and recommendations are not saved.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if intensitySelectionLocked {
                Label(
                    "Level is locked while the immersive training space is active.",
                    systemImage: "lock.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            }

            if let recommendation = recommendation(for: setKind) {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next-set suggestion")
                        .font(.subheadline.bold())
                    Text(
                        recommendation.proposesChange
                            ? "Try level \(recommendation.suggested.rawValue) · \(recommendation.suggested.title)"
                            : "Keep level \(recommendation.suggested.rawValue) · \(recommendation.suggested.title)"
                    )
                    .font(.headline)
                    Text(recommendation.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Based on the completed level \(recommendation.basedOn.rawValue) set.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    if recommendation.proposesChange {
                        Button("Apply Suggested Level") {
                            trainingSettings.applyRecommendation()
                        }
                        .buttonStyle(.bordered)
                        .disabled(intensitySelectionLocked)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .onAppear {
            refreshIntensityRecommendation(for: setKind)
        }
    }

    func refreshIntensityRecommendation(for setKind: TrainingSetKind) {
        guard trainingSettings.recommendationsEnabled else { return }

        switch setKind {
        case .auraPunch:
            guard let summary = auraPunch.summary else { return }
            trainingSettings.consider(TrainingSetEvidence(
                kind: .auraPunch,
                difficulty: summary.difficulty,
                completedOpportunities: summary.completedRepetitions,
                minimumOpportunities: summary.repetitionGoal,
                primaryScore: summary.averageScore,
                controlScore: summary.averageOtherHandGuardScore,
                responseTimeRatio: nil,
                trackingInterruptions: summary.trackingInterruptions
            ))

        case .reactiveBoard:
            guard let summary = roundEngine.summary else { return }
            let cueDuration = roundEngine.configuration.cueDuration
                * summary.difficulty.presentation.boardCueDurationMultiplier
            let responseRatio = summary.averageResponseTime.map {
                cueDuration > 0 ? $0 / cueDuration : .infinity
            }
            trainingSettings.consider(TrainingSetEvidence(
                kind: .reactiveBoard,
                difficulty: summary.difficulty,
                completedOpportunities: summary.completedAttempts,
                minimumOpportunities: 6,
                primaryScore: summary.hitRate,
                controlScore: summary.guardReturnConsistency,
                responseTimeRatio: responseRatio,
                trackingInterruptions: summary.trackingInterruptions
            ))

        case .defense:
            guard let summary = defense.summary else { return }
            let cueDuration = defense.configuration.cueDuration
                * summary.difficulty.presentation.defenseCueDurationMultiplier
            let responseRatio = summary.averageSuccessfulResponseTime.map {
                cueDuration > 0 ? $0 / cueDuration : .infinity
            }
            let successRate = summary.completedAttempts > 0
                ? Double(summary.successfulAvoidances)
                    / Double(summary.completedAttempts)
                : 0
            trainingSettings.consider(TrainingSetEvidence(
                kind: .defense,
                difficulty: summary.difficulty,
                completedOpportunities: summary.completedAttempts,
                minimumOpportunities: summary.cueGoal,
                primaryScore: successRate,
                controlScore: nil,
                responseTimeRatio: responseRatio,
                trackingInterruptions: summary.adaptiveEvidenceInterruptions
            ))
        }
    }

    private var intensitySelectionLocked: Bool {
        appModel.immersiveSpaceState != .closed
            || roundEngine.isRoundActive
            || auraPunch.phase == .demonstrating
            || auraPunch.phase == .following
            || auraPunch.phase == .paused
            || defense.phase.isTrainingSessionActive
    }

    private func recommendation(
        for setKind: TrainingSetKind
    ) -> TrainingIntensityRecommendation? {
        guard let recommendation = trainingSettings.recommendation,
              recommendation.setKind == setKind else {
            return nil
        }
        return recommendation
    }
}

private extension DefensePhase {
    var isTrainingSessionActive: Bool {
        switch self {
        case .countdown, .active, .paused:
            true
        case .idle, .calibratingNeutral, .ready, .completed:
            false
        }
    }
}
