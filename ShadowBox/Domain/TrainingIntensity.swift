//
//  TrainingIntensity.swift
//  Test
//
//  Session-only pace and visual-assistance controls. Difficulty never changes
//  reach, movement thresholds, target size, scoring weights, or safety rules.
//

import Foundation

enum TrainingDifficulty: Int, CaseIterable, Equatable, Hashable, Sendable {
    case guided = 1
    case steady
    case balanced
    case sharp
    case peak

    nonisolated static let defaultValue = TrainingDifficulty.balanced

    init(clamping value: Int) {
        self = Self(rawValue: min(5, max(1, value))) ?? .defaultValue
    }

    var title: String {
        switch self {
        case .guided: "Guided"
        case .steady: "Steady"
        case .balanced: "Balanced"
        case .sharp: "Sharp"
        case .peak: "Peak"
        }
    }

    var paceDescription: String {
        switch self {
        case .guided: "Longest cues and the densest Aura path"
        case .steady: "Relaxed cues with extra visual guidance"
        case .balanced: "Standard cue pace and guidance"
        case .sharp: "Shorter cues with a lighter Aura path"
        case .peak: "Shortest cues and the lightest Aura path"
        }
    }

    /// All values are relative to each engine's configured baseline so custom
    /// test/tuning configurations retain their meaning at level 3.
    var presentation: TrainingPresentationProfile {
        switch self {
        case .guided:
            TrainingPresentationProfile(
                auraDemonstrationMultiplier: 1.60,
                auraPathPointCount: 15,
                boardCueDurationMultiplier: 1.40,
                boardFeedbackDelayMultiplier: 1.55,
                defenseCueDurationMultiplier: 1.50,
                defenseInterCueDelayMultiplier: 2.60
            )
        case .steady:
            TrainingPresentationProfile(
                auraDemonstrationMultiplier: 1.30,
                auraPathPointCount: 13,
                boardCueDurationMultiplier: 1.20,
                boardFeedbackDelayMultiplier: 1.25,
                defenseCueDurationMultiplier: 1.25,
                defenseInterCueDelayMultiplier: 1.70
            )
        case .balanced:
            TrainingPresentationProfile(
                auraDemonstrationMultiplier: 1,
                auraPathPointCount: 11,
                boardCueDurationMultiplier: 1,
                boardFeedbackDelayMultiplier: 1,
                defenseCueDurationMultiplier: 1,
                defenseInterCueDelayMultiplier: 1
            )
        case .sharp:
            TrainingPresentationProfile(
                auraDemonstrationMultiplier: 0.80,
                auraPathPointCount: 9,
                boardCueDurationMultiplier: 0.82,
                boardFeedbackDelayMultiplier: 0.80,
                defenseCueDurationMultiplier: 0.82,
                defenseInterCueDelayMultiplier: 0.65
            )
        case .peak:
            TrainingPresentationProfile(
                auraDemonstrationMultiplier: 0.65,
                auraPathPointCount: 7,
                boardCueDurationMultiplier: 0.68,
                boardFeedbackDelayMultiplier: 0.65,
                defenseCueDurationMultiplier: 0.70,
                defenseInterCueDelayMultiplier: 0.45
            )
        }
    }
}

struct TrainingPresentationProfile: Equatable, Sendable {
    let auraDemonstrationMultiplier: Double
    let auraPathPointCount: Int
    let boardCueDurationMultiplier: Double
    let boardFeedbackDelayMultiplier: Double
    let defenseCueDurationMultiplier: Double
    let defenseInterCueDelayMultiplier: Double
}

enum TrainingSetKind: String, Equatable, Sendable {
    case auraPunch
    case reactiveBoard
    case defense

    var title: String {
        switch self {
        case .auraPunch: "Aura Punch"
        case .reactiveBoard: "Punch Board"
        case .defense: "Defense"
        }
    }
}

/// Aggregate-only evidence. No samples, transforms, traces, or training
/// history enter the recommendation policy.
struct TrainingSetEvidence: Equatable, Sendable {
    let kind: TrainingSetKind
    let difficulty: TrainingDifficulty
    let completedOpportunities: Int
    let minimumOpportunities: Int
    let primaryScore: Double
    let controlScore: Double?
    let responseTimeRatio: Double?
    let trackingInterruptions: Int
}

nonisolated enum TrainingRecommendationReason: Equatable, Sendable {
    case trackingInterrupted
    case insufficientEvidence
    case readyForFasterPace
    case reducePaceForControl
    case consolidateCurrentPace
    case alreadyAtMinimum
    case alreadyAtMaximum
}

struct TrainingIntensityRecommendation: Equatable, Sendable {
    let setKind: TrainingSetKind
    let basedOn: TrainingDifficulty
    let suggested: TrainingDifficulty
    let reason: TrainingRecommendationReason
    let explanation: String

    var proposesChange: Bool {
        suggested != basedOn
    }
}

enum TrainingIntensityAdvisor {
    static func recommendation(
        from evidence: TrainingSetEvidence
    ) -> TrainingIntensityRecommendation {
        if evidence.trackingInterruptions > 0 {
            return hold(
                evidence,
                reason: .trackingInterrupted,
                explanation: "Hold this level because tracking was interrupted; the set is not clean evidence for a pace change."
            )
        }

        guard evidence.completedOpportunities >= evidence.minimumOpportunities else {
            return hold(
                evidence,
                reason: .insufficientEvidence,
                explanation: "Hold this level until a complete set provides enough evidence."
            )
        }

        switch evidence.kind {
        case .auraPunch:
            let control = evidence.controlScore ?? 0
            if evidence.primaryScore >= 0.85, control >= 0.75 {
                return change(evidence, offset: 1, reason: .readyForFasterPace)
            }
            if evidence.primaryScore < 0.55 || control < 0.45 {
                return change(evidence, offset: -1, reason: .reducePaceForControl)
            }

        case .reactiveBoard:
            let control = evidence.controlScore
            if evidence.primaryScore >= 0.85,
               let control,
               control >= 0.75,
               let responseTimeRatio = evidence.responseTimeRatio,
               responseTimeRatio <= 0.60 {
                return change(evidence, offset: 1, reason: .readyForFasterPace)
            }
            if evidence.primaryScore < 0.50
                || evidence.responseTimeRatio.map({ $0 > 0.90 }) == true {
                return change(evidence, offset: -1, reason: .reducePaceForControl)
            }

        case .defense:
            if evidence.primaryScore >= 0.83,
               let responseTimeRatio = evidence.responseTimeRatio,
               responseTimeRatio <= 0.60 {
                return change(evidence, offset: 1, reason: .readyForFasterPace)
            }
            if evidence.primaryScore < 0.50
                || evidence.responseTimeRatio.map({ $0 > 0.90 }) == true {
                return change(evidence, offset: -1, reason: .reducePaceForControl)
            }
        }

        return hold(
            evidence,
            reason: .consolidateCurrentPace,
            explanation: "Hold this level and consolidate clean, controlled repetitions before changing the presentation pace."
        )
    }

    private static func change(
        _ evidence: TrainingSetEvidence,
        offset: Int,
        reason: TrainingRecommendationReason
    ) -> TrainingIntensityRecommendation {
        let proposed = TrainingDifficulty(
            clamping: evidence.difficulty.rawValue + min(1, max(-1, offset))
        )

        if proposed == evidence.difficulty {
            let isMaximum = offset > 0
            return hold(
                evidence,
                reason: isMaximum ? .alreadyAtMaximum : .alreadyAtMinimum,
                explanation: isMaximum
                    ? "Keep level 5: this is already the fastest presentation pace in the MVP."
                    : "Keep level 1: this is already the most guided presentation pace in the MVP."
            )
        }

        let explanation: String
        switch reason {
        case .readyForFasterPace:
            explanation = "Strong control and response evidence supports trying one faster presentation level next set."
        case .reducePaceForControl:
            explanation = "A one-level slower presentation should leave more time to rebuild control next set."
        default:
            explanation = "Try one adjacent presentation level next set."
        }

        return TrainingIntensityRecommendation(
            setKind: evidence.kind,
            basedOn: evidence.difficulty,
            suggested: proposed,
            reason: reason,
            explanation: explanation
        )
    }

    private static func hold(
        _ evidence: TrainingSetEvidence,
        reason: TrainingRecommendationReason,
        explanation: String
    ) -> TrainingIntensityRecommendation {
        TrainingIntensityRecommendation(
            setKind: evidence.kind,
            basedOn: evidence.difficulty,
            suggested: evidence.difficulty,
            reason: reason,
            explanation: explanation
        )
    }
}
