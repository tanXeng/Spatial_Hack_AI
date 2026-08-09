import Foundation

/// A pedagogical presentation of the same deterministic scoring rules.
nonisolated struct TrainingTrack: Identifiable, Hashable, Sendable, Codable {
    nonisolated enum ExplanationDetail: String, Hashable, Sendable, Codable {
        case plainLanguage
        case technical
    }

    nonisolated struct ScoringPolicy: Hashable, Sendable, Codable {
        let minimumTrackedFraction: Float
        let requiredMetrics: [SubMetricKind]
        let requiresReturnToGuard: Bool
    }

    let id: String
    let title: String
    let introCopy: String
    let demonstrationRate: Float
    let guidedRehearsalCount: Int
    let explanationDetail: ExplanationDetail
    let usesTimerPressure: Bool
    let scoringPolicy: ScoringPolicy

    private static let sharedScoringPolicy = ScoringPolicy(
        minimumTrackedFraction: 0.75,
        requiredMetrics: SubMetricKind.allCases,
        requiresReturnToGuard: true
    )

    static let firstRound = TrainingTrack(
        id: "first-round",
        title: "First Round",
        introCopy: "Learn the punch one clear movement at a time.",
        demonstrationRate: 0.65,
        guidedRehearsalCount: 3,
        explanationDetail: .plainLanguage,
        usesTimerPressure: false,
        scoringPolicy: sharedScoringPolicy
    )

    static let technicalCamp = TrainingTrack(
        id: "technical-camp",
        title: "Technical Camp",
        introCopy: "Refine each phase with precise technical feedback.",
        demonstrationRate: 0.85,
        guidedRehearsalCount: 5,
        explanationDetail: .technical,
        usesTimerPressure: false,
        scoringPolicy: sharedScoringPolicy
    )
}
