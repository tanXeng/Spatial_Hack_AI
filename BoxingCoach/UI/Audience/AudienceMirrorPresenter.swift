import Foundation

nonisolated enum TrainingPresentationStage: String, CaseIterable, Equatable, Sendable {
    case welcome = "WELCOME"
    case safety = "SAFETY"
    case fit = "FIT"
    case learn = "LEARN"
    case baseline = "BASELINE"
    case correct = "CORRECT"
    case prove = "PROVE"
    case transfer = "TRANSFER"
    case compete = "COMPETE"
    case celebrate = "CELEBRATE"
    case trackingPaused = "TRACKING PAUSED"
    case coachOffline = "COACH OFFLINE"
    case nextBoxer = "NEXT BOXER"
}

/// Authored public copy only. There is deliberately no raw-string case, so profile data,
/// transcripts, participant names, or motion samples cannot be forwarded to the mirror.
nonisolated enum TrainingPublicInstruction: Equatable, Sendable {
    case chooseTrack
    case clearSafeSpace
    case fitReach
    case followGuide
    case controlledPunch
    case focus(SubMetricKind)
    case repeatPunch
    case transferOneTwo
    case competeTarget
    case roundComplete
    case recoverTracking
    case localCoachAvailable
    case nextParticipant

    var text: String {
        switch self {
        case .chooseTrack: "Choose First Round or Technical Camp."
        case .clearSafeSpace: "Clear enough room to extend both arms."
        case .fitReach: "Measure both arms inside comfortable reach."
        case .followGuide: "Follow the cyan guide from guard to guard."
        case .controlledPunch: "Throw one controlled punch."
        case .focus(let metric): "Focus on \(metric.title.lowercased())."
        case .repeatPunch: "Repeat the same punch."
        case .transferOneTwo: "Throw a stance-correct 1–2."
        case .competeTarget: "Hit the target and return to guard."
        case .roundComplete: "Round complete."
        case .recoverTracking: "Return both fists to guard."
        case .localCoachAvailable: "Measured local coaching remains available."
        case .nextParticipant: "The headset is ready for the next participant."
        }
    }
}

nonisolated struct TrainingProgressPresentation: Equatable, Sendable {
    let current: Int
    let total: Int

    init?(current: Int, total: Int) {
        guard total > 0, (0...total).contains(current) else { return nil }
        self.current = current
        self.total = total
    }

    var text: String { "\(current) of \(total)" }
}

nonisolated struct TrainingProofPresentation: Equatable, Sendable {
    let metric: SubMetricKind
    let baseline: Int
    let retest: Int

    init?(metric: SubMetricKind, baseline: Int, retest: Int) {
        guard (0...100).contains(baseline), (0...100).contains(retest) else { return nil }
        self.metric = metric
        self.baseline = baseline
        self.retest = retest
    }

    var text: String { "\(metric.title) \(baseline) to \(retest)" }
}

/// Immutable, privacy-bounded state shared by headset and audience presentation.
nonisolated struct TrainingPresentationState: Equatable, Sendable {
    let stage: TrainingPresentationStage
    let instruction: TrainingPublicInstruction
    let proof: TrainingProofPresentation?
    let progress: TrainingProgressPresentation?
    let competitionScore: Int?
    let competitionRank: Int?
    let publicHandle: ParticipantPublicHandle?

    init?(
        stage: TrainingPresentationStage,
        instruction: TrainingPublicInstruction,
        proof: TrainingProofPresentation? = nil,
        progress: TrainingProgressPresentation? = nil,
        competitionScore: Int? = nil,
        competitionRank: Int? = nil,
        publicHandle: ParticipantPublicHandle? = nil
    ) {
        guard competitionScore.map({ (0...100).contains($0) }) ?? true,
              competitionRank.map({ $0 > 0 }) ?? true
        else { return nil }
        self.stage = stage
        self.instruction = instruction
        self.proof = proof
        self.progress = progress
        self.competitionScore = competitionScore
        self.competitionRank = competitionRank
        self.publicHandle = publicHandle
    }

    var secondaryMetricCount: Int { proof == nil ? 0 : 1 }

    static let nextBoxer = Self(
        stage: .nextBoxer,
        instruction: .nextParticipant
    )!
}

nonisolated struct AudienceMirrorPresentation: Equatable, Sendable {
    let stage: String
    let instruction: String
    let proofMetric: String?
    let progress: String?
    let score: String?
    let rank: String?
    let publicIdentity: String?

    fileprivate init(state: TrainingPresentationState) {
        stage = state.stage.rawValue
        instruction = state.instruction.text
        proofMetric = state.proof?.text
        progress = state.progress?.text
        score = state.competitionScore.map { "\($0) points" }
        rank = state.competitionRank.map { "Rank \($0)" }
        publicIdentity = state.publicHandle?.displayValue
    }
}

nonisolated enum AudienceMirrorPresenter {
    static func presentation(for state: TrainingPresentationState) -> AudienceMirrorPresentation {
        AudienceMirrorPresentation(state: state)
    }
}

nonisolated enum TrainingPresentationContext: Sendable {
    case welcome
    case nextBoxer
    case coachOffline
    case aura(
        stage: LearningStage,
        trackingPaused: Bool,
        proof: TrainingProofPresentation?,
        aiPhrasingAvailable: Bool
    )
    case reactive(
        context: ImmersiveTrainingContext,
        phase: DrillPhase,
        trackingPaused: Bool,
        progress: TrainingProgressPresentation?,
        score: Int?,
        rank: Int?,
        publicHandle: ParticipantPublicHandle?
    )
}

nonisolated enum TrainingPresentationPolicy {
    static func state(for context: TrainingPresentationContext) -> TrainingPresentationState? {
        switch context {
        case .welcome:
            return TrainingPresentationState(stage: .welcome, instruction: .chooseTrack)
        case .nextBoxer:
            return .nextBoxer
        case .coachOffline:
            return TrainingPresentationState(stage: .coachOffline, instruction: .localCoachAvailable)
        case let .aura(stage, trackingPaused, proof, _):
            if trackingPaused {
                return TrainingPresentationState(
                    stage: .trackingPaused,
                    instruction: .recoverTracking
                )
            }
            let output: (TrainingPresentationStage, TrainingPublicInstruction)
            switch stage {
            case .fit:
                output = (.fit, .fitReach)
            case .learnWatch, .learnOutbound, .learnLanding, .learnReturn,
                 .guidedRehearsal:
                output = (.learn, .followGuide)
            case .baseline:
                output = (.baseline, .controlledPunch)
            case .correction, .correctiveDrill:
                output = (.correct, .repeatPunch)
            case .retest, .proof:
                output = (.prove, .repeatPunch)
            case .transfer:
                output = (.transfer, .transferOneTwo)
            case .complete:
                output = (.celebrate, .roundComplete)
            }
            return TrainingPresentationState(
                stage: output.0,
                instruction: output.1,
                proof: proof
            )
        case let .reactive(
            context,
            phase,
            trackingPaused,
            progress,
            score,
            rank,
            publicHandle
        ):
            if trackingPaused {
                return TrainingPresentationState(
                    stage: .trackingPaused,
                    instruction: .recoverTracking
                )
            }
            let output: (TrainingPresentationStage, TrainingPublicInstruction)
            switch context {
            case .reachCalibration, .competitionCalibration:
                output = (.fit, .fitReach)
            case .aura:
                output = (.learn, .followGuide)
            case .standard, .competition:
                switch phase {
                case .idle:
                    output = (.safety, .clearSafeSpace)
                case .calibrating:
                    output = (.fit, .fitReach)
                case .running:
                    output = (.compete, .competeTarget)
                case .finished:
                    output = (.celebrate, .roundComplete)
                }
            }
            return TrainingPresentationState(
                stage: output.0,
                instruction: output.1,
                progress: phase == .running ? progress : nil,
                competitionScore: phase == .finished ? score : nil,
                competitionRank: phase == .finished ? rank : nil,
                publicHandle: publicHandle
            )
        }
    }

    @MainActor
    static func liveState(
        flow: TrainingFlowCoordinator,
        session: ReactiveStrikeSession,
        competitionStore: CompetitionStore
    ) -> TrainingPresentationState {
        guard case .experience(let selection) = flow.route else {
            return state(for: .nextBoxer)!
        }
        switch selection {
        case .aura:
            let proof = session.auraPunch.proofMetric.flatMap {
                TrainingProofPresentation(
                    metric: $0.kind,
                    baseline: Int($0.baseline.rounded()),
                    retest: Int($0.retest.rounded())
                )
            }
            return state(for: .aura(
                stage: session.auraPunch.learningStage,
                trackingPaused: session.auraPunch.isTrackingPaused,
                proof: proof,
                aiPhrasingAvailable: CoachSecrets.relayEndpoint != nil
            ))!
        case .reactive(_, let combination, _):
            return state(for: .reactive(
                context: .standard(isCombination: combination != nil),
                phase: session.phase,
                trackingPaused: session.isTrackingPaused,
                progress: nil,
                score: nil,
                rank: nil,
                publicHandle: nil
            ))!
        case .reachCalibration:
            return state(for: .reactive(
                context: .reachCalibration,
                phase: session.phase,
                trackingPaused: session.isTrackingPaused,
                progress: nil,
                score: nil,
                rank: nil,
                publicHandle: nil
            ))!
        case .competitionCalibration:
            return state(for: .reactive(
                context: .competitionCalibration,
                phase: session.phase,
                trackingPaused: session.isTrackingPaused,
                progress: nil,
                score: nil,
                rank: nil,
                publicHandle: competitionStore.currentPlayer?.publicHandle
            ))!
        case .competition(_, let mode, _, _):
            let submission = competitionStore.latestSubmission.flatMap { submission in
                submission.playerID == competitionStore.currentPlayer?.id ? submission : nil
            }
            let rank = submission.flatMap { submission in
                competitionStore.standings(for: mode).first(where: {
                    $0.submission.id == submission.id
                })?.rank
            }
            return state(for: .reactive(
                context: .competition(isCombination: mode == .combination),
                phase: session.phase,
                trackingPaused: session.isTrackingPaused,
                progress: nil,
                score: submission?.score,
                rank: rank,
                publicHandle: competitionStore.currentPlayer?.publicHandle
            ))!
        }
    }
}
