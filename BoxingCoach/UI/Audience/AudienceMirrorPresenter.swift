import Foundation

/// Immutable, privacy-bounded state shared by headset and audience presentation.
///
/// It intentionally accepts only the event-local public handle. Private participant names,
/// calibration details, raw motion, transcripts, and profile memory cannot enter this boundary.
nonisolated struct TrainingPresentationState: Equatable, Sendable {
    let stage: String
    let instruction: String
    let proofMetric: String?
    let progress: String?
    let competitionScore: Int?
    let competitionRank: Int?
    let publicHandle: ParticipantPublicHandle?

    init(
        stage: String,
        instruction: String,
        proofMetric: String? = nil,
        progress: String? = nil,
        competitionScore: Int? = nil,
        competitionRank: Int? = nil,
        publicHandle: ParticipantPublicHandle? = nil
    ) {
        self.stage = stage
        self.instruction = instruction
        self.proofMetric = proofMetric
        self.progress = progress
        self.competitionScore = competitionScore
        self.competitionRank = competitionRank
        self.publicHandle = publicHandle
    }

    var secondaryMetricCount: Int { proofMetric == nil ? 0 : 1 }

    static let nextBoxer = Self(
        stage: "NEXT BOXER",
        instruction: "The headset is ready for the next participant."
    )
}

nonisolated struct AudienceMirrorPresentation: Equatable, Sendable {
    let stage: String
    let instruction: String
    let proofMetric: String?
    let progress: String?
    let score: String?
    let rank: String?
    let publicIdentity: String?
}

nonisolated enum AudienceMirrorPresenter {
    static func presentation(for state: TrainingPresentationState) -> AudienceMirrorPresentation {
        AudienceMirrorPresentation(
            stage: state.stage,
            instruction: state.instruction,
            proofMetric: state.proofMetric,
            progress: state.progress,
            score: state.competitionScore.map { "\($0) points" },
            rank: state.competitionRank.map { "Rank \($0)" },
            publicIdentity: state.publicHandle?.displayValue
        )
    }
}
