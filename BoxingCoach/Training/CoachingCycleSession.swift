import Foundation
import simd

nonisolated enum CoachingCycleError: Error, Equatable, Sendable {
    case invalidTransition(expected: LearningStage, actual: LearningStage)
    case attemptNotAdmissible
    case attemptTechniqueMismatch
    case attemptStanceMismatch
    case attemptHandMismatch
    case unavailableProof
}

nonisolated enum CoachingAttemptRejection: Equatable, Sendable {
    case invalidEvidence
    case trackingLost
    case trainingPaused
}

/// Immutable admitted evidence plus the two body-relative paths needed for correction display.
nonisolated struct CoachingAttemptEvidence: Sendable {
    let evidence: TechniqueAttemptEvidence
    let actualPath: [SIMD3<Float>]
    let referencePath: [SIMD3<Float>]

    init(
        evidence: TechniqueAttemptEvidence,
        actualPath: [SIMD3<Float>],
        referencePath: [SIMD3<Float>]
    ) throws {
        guard !actualPath.isEmpty,
              !referencePath.isEmpty,
              actualPath.allSatisfy(\.isFinite),
              referencePath.allSatisfy(\.isFinite)
        else { throw CoachingCycleError.attemptNotAdmissible }

        self.evidence = evidence
        self.actualPath = actualPath
        self.referencePath = referencePath
    }
}

nonisolated struct CorrectionPathOverlay: Equatable, Sendable {
    let side: BodySide
    let actualPath: [SIMD3<Float>]
    let referencePath: [SIMD3<Float>]
    let actualLabel: String
    let referenceLabel: String
    let actualColorName: String
    let referenceColorName: String
    let trackedFraction: Float
    let cue: String
    let sourceBadge: String
}

nonisolated struct CoachingProofMetric: Equatable, Sendable {
    let kind: SubMetricKind
    let baseline: Float
    let retest: Float
    let delta: Float
    let trackedFraction: Float
    let correctionCode: CoachCorrectionCode
    let evidenceLabel: CorrectionEvidenceLabel
    let sourceBadge: String
}

nonisolated struct CoachingCyclePresentation: Equatable, Sendable {
    let stage: String
    let instruction: String
    let action: String
    let progress: String?
    let metric: String?
    let timer: String?
}

/// Pure deterministic reducer for one complete fit-learn-prove-transfer cycle.
///
/// The reducer accepts only immutable `TechniqueAttemptEvidence` that already crossed the Task 4
/// punch-admission boundary. Rejected, interrupted, or paused partial reps have no score payload
/// and therefore cannot become a low attempt by accident.
nonisolated struct CoachingCycleSession: Sendable {
    static let requiredAttempts = 3

    let track: TrainingTrack
    let technique: Technique
    let stance: Stance

    private(set) var stage: LearningStage = .fit
    private(set) var completedStages: [LearningStage] = []
    private(set) var fittedReach: BilateralReach?
    private(set) var guidedRehearsalsCompleted = 0
    private(set) var baselineAttempts: [CoachingAttemptEvidence] = []
    private(set) var retestAttempts: [CoachingAttemptEvidence] = []
    private(set) var correction: CorrectionDecision?
    private(set) var correctionPlan: CorrectionPlan?
    private(set) var correctionOverlay: CorrectionPathOverlay?
    private(set) var baselineSnapshot: TechniqueAttemptEvidence?
    private(set) var retestSnapshot: TechniqueAttemptEvidence?
    private(set) var proof: ProofComparison?
    private(set) var proofMetric: CoachingProofMetric?
    private(set) var result: CoachingCycleResult?
    private(set) var hasPartialAttempt = false
    private(set) var isTrackingPaused = false
    private(set) var isTrainingPaused = false

    init(track: TrainingTrack, technique: Technique, stance: Stance) {
        self.track = track
        self.technique = technique
        self.stance = stance
    }

    var activeAttemptCount: Int {
        switch stage {
        case .baseline: baselineAttempts.count
        case .retest: retestAttempts.count
        default: 0
        }
    }

    var presentation: CoachingCyclePresentation {
        let plain = track.explanationDetail == .plainLanguage
        let progress: String?
        switch stage {
        case .guidedRehearsal:
            progress = "Rehearsal \(guidedRehearsalsCompleted + 1) of \(track.guidedRehearsalCount)"
        case .baseline:
            progress = "Baseline \(baselineAttempts.count) of \(Self.requiredAttempts)"
        case .retest:
            progress = "Retest \(retestAttempts.count) of \(Self.requiredAttempts)"
        default:
            progress = nil
        }

        let metric = proofMetric.map {
            "\($0.kind.title): \(Int($0.baseline.rounded())) → \(Int($0.retest.rounded())) (\(Self.signed($0.delta)))"
        }

        switch stage {
        case .fit:
            return .init(
                stage: "FIT",
                instruction: plain
                    ? "Hold both fists in guard, then extend each arm comfortably."
                    : "Set guard, then hold bilateral comfortable extension.",
                action: "Fit your reach",
                progress: nil,
                metric: nil,
                timer: nil
            )
        case .learnWatch:
            return .init(stage: "LEARN · WATCH", instruction: plain ? "Watch the whole punch once." : "Read the full reference shape.", action: "Watch", progress: nil, metric: nil, timer: nil)
        case .learnOutbound:
            return .init(stage: "LEARN · OUTBOUND", instruction: plain ? "Follow the fist out from guard." : "Match the outbound line.", action: "Follow out", progress: nil, metric: nil, timer: nil)
        case .learnLanding:
            return .init(stage: "LEARN · LANDING", instruction: plain ? "Meet the target without reaching past comfort." : "Match fitted extension.", action: "Land", progress: nil, metric: nil, timer: nil)
        case .learnReturn:
            return .init(stage: "LEARN · RETURN", instruction: plain ? "Bring the fist straight back to guard." : "Retract on the same line.", action: "Return", progress: nil, metric: nil, timer: nil)
        case .guidedRehearsal:
            return .init(stage: "GUIDED REHEARSAL", instruction: plain ? "Move with the cyan guide from guard to guard." : "Rehearse the fitted reference at \(Int(track.demonstrationRate * 100)) percent pace.", action: "Rehearse", progress: progress, metric: nil, timer: nil)
        case .baseline:
            return .init(stage: "BASELINE", instruction: plain ? "Throw one controlled punch when ready." : "Record one clean unassisted rep.", action: "Punch", progress: progress, metric: nil, timer: nil)
        case .correction:
            return .init(stage: "ONE CORRECTION", instruction: correction?.localCue ?? "Review the selected correction.", action: "Review", progress: nil, metric: nil, timer: nil)
        case .correctiveDrill:
            return .init(stage: "CORRECTIVE DRILL", instruction: correction?.localCue ?? "Rehearse the selected correction.", action: "Practice", progress: nil, metric: nil, timer: nil)
        case .retest:
            return .init(stage: "RETEST", instruction: plain ? "Repeat the same punch with the correction." : "Retest under the same scoring contract.", action: "Punch", progress: progress, metric: nil, timer: nil)
        case .proof:
            return .init(stage: "PROOF", instruction: proofMetric.map { $0.delta >= 0 ? "The selected metric improved." : "The selected metric did not improve yet." } ?? "Preparing like-for-like proof.", action: "Continue", progress: nil, metric: metric, timer: nil)
        case .transfer:
            return .init(stage: "TRANSFER · 1–2", instruction: plain ? "Use the correct lead hand for the jab, then the rear hand for the cross." : "Transfer into a stance-correct 1–2.", action: "Throw 1–2", progress: nil, metric: metric, timer: nil)
        case .complete:
            return .init(stage: "COMPLETE", instruction: "Your proof is saved for this cycle.", action: "Finish", progress: nil, metric: metric, timer: nil)
        }
    }

    mutating func completeFit(reach: BilateralReach) throws {
        try requireStage(.fit)
        fittedReach = reach
        transition(from: .fit, to: .learnWatch)
    }

    mutating func completeLearningStep() throws {
        switch stage {
        case .learnWatch: transition(from: .learnWatch, to: .learnOutbound)
        case .learnOutbound: transition(from: .learnOutbound, to: .learnLanding)
        case .learnLanding: transition(from: .learnLanding, to: .learnReturn)
        case .learnReturn: transition(from: .learnReturn, to: .guidedRehearsal)
        default: throw CoachingCycleError.invalidTransition(expected: .learnWatch, actual: stage)
        }
    }

    mutating func completeGuidedRehearsal() throws {
        try requireStage(.guidedRehearsal)
        guard guidedRehearsalsCompleted < track.guidedRehearsalCount else {
            throw CoachingCycleError.attemptNotAdmissible
        }
        guidedRehearsalsCompleted += 1
        if guidedRehearsalsCompleted == track.guidedRehearsalCount {
            transition(from: .guidedRehearsal, to: .baseline)
        }
    }

    mutating func beginPartialAttempt() {
        guard stage == .baseline || stage == .retest,
              !isTrackingPaused,
              !isTrainingPaused else { return }
        hasPartialAttempt = true
    }

    mutating func rejectPartialAttempt(_ reason: CoachingAttemptRejection) {
        _ = reason
        hasPartialAttempt = false
    }

    mutating func trackingDidPause() {
        isTrackingPaused = true
        rejectPartialAttempt(.trackingLost)
    }

    mutating func trackingDidResume() {
        isTrackingPaused = false
    }

    mutating func trainingDidPause() {
        isTrainingPaused = true
        rejectPartialAttempt(.trainingPaused)
    }

    mutating func trainingDidResume() {
        isTrainingPaused = false
    }

    mutating func admit(_ attempt: CoachingAttemptEvidence) throws {
        guard !isTrackingPaused, !isTrainingPaused else {
            throw CoachingCycleError.attemptNotAdmissible
        }
        try validate(attempt)
        hasPartialAttempt = false

        switch stage {
        case .baseline:
            guard baselineAttempts.count < Self.requiredAttempts else {
                throw CoachingCycleError.attemptNotAdmissible
            }
            baselineAttempts.append(attempt)
            if baselineAttempts.count == Self.requiredAttempts {
                try finishBaseline()
            }
        case .retest:
            guard retestAttempts.count < Self.requiredAttempts else {
                throw CoachingCycleError.attemptNotAdmissible
            }
            retestAttempts.append(attempt)
            if retestAttempts.count == Self.requiredAttempts {
                try finishRetest()
            }
        default:
            throw CoachingCycleError.invalidTransition(expected: .baseline, actual: stage)
        }
    }

    mutating func beginCorrectiveDrill() throws {
        try requireStage(.correction)
        transition(from: .correction, to: .correctiveDrill)
    }

    mutating func completeCorrectiveDrill() throws {
        try requireStage(.correctiveDrill)
        transition(from: .correctiveDrill, to: .retest)
    }

    mutating func continueFromProof() throws {
        try requireStage(.proof)
        guard proof != nil else { throw CoachingCycleError.unavailableProof }
        transition(from: .proof, to: .transfer)
    }

    mutating func completeTransfer(at completedAt: Date = Date()) throws {
        try requireStage(.transfer)
        guard let baseline = baselineSnapshot,
              let retest = retestSnapshot,
              let correctionPlan,
              let proof
        else { throw CoachingCycleError.unavailableProof }

        transition(from: .transfer, to: .complete)
        completedStages.append(.complete)
        result = try CoachingCycleResult(
            track: track,
            technique: technique,
            stance: stance,
            completedStages: completedStages,
            baseline: baseline,
            correction: correctionPlan,
            retest: retest,
            proof: proof,
            completedAt: completedAt
        )
    }

    mutating func reset() {
        stage = .fit
        completedStages.removeAll(keepingCapacity: false)
        fittedReach = nil
        guidedRehearsalsCompleted = 0
        baselineAttempts.removeAll(keepingCapacity: false)
        retestAttempts.removeAll(keepingCapacity: false)
        correction = nil
        correctionPlan = nil
        correctionOverlay = nil
        baselineSnapshot = nil
        retestSnapshot = nil
        proof = nil
        proofMetric = nil
        result = nil
        hasPartialAttempt = false
        isTrackingPaused = false
        isTrainingPaused = false
    }

    private mutating func finishBaseline() throws {
        guard let aggregate = aggregateEvidence(from: baselineAttempts) else {
            throw CoachingCycleError.attemptNotAdmissible
        }
        let decision = CorrectionSelector().select(
            score: aggregate.score,
            technique: technique,
            stance: stance
        )
        let focus = decision.focus ?? aggregate.score.weakest?.kind ?? .path
        correction = decision
        baselineSnapshot = aggregate
        correctionPlan = try CorrectionPlan(
            technique: technique,
            focus: focus,
            rationale: decision.whyItMatters,
            cue: decision.localCue,
            rehearsalCount: 1,
            targetImprovement: CorrectionSelector.celebrationThreshold
        )
        correctionOverlay = makeCorrectionOverlay(focus: focus, decision: decision)
        transition(from: .baseline, to: .correction)
    }

    private mutating func finishRetest() throws {
        guard let baseline = baselineSnapshot,
              let retest = aggregateEvidence(from: retestAttempts),
              let correction,
              let focus = correctionPlan?.focus,
              let baselineValue = baseline.score.metric(focus)?.score,
              let retestValue = retest.score.metric(focus)?.score
        else { throw CoachingCycleError.unavailableProof }

        let comparison = try ProofComparison(baseline: baseline, retest: retest)
        retestSnapshot = retest
        proof = comparison
        proofMetric = CoachingProofMetric(
            kind: focus,
            baseline: baselineValue,
            retest: retestValue,
            delta: retestValue - baselineValue,
            trackedFraction: min(baseline.score.trackedFraction, retest.score.trackedFraction),
            correctionCode: correction.code,
            evidenceLabel: correction.evidenceLabel,
            sourceBadge: "Measured locally · Offline coach"
        )
        transition(from: .retest, to: .proof)
    }

    private func validate(_ attempt: CoachingAttemptEvidence) throws {
        let evidence = attempt.evidence
        guard evidence.technique == technique else {
            throw CoachingCycleError.attemptTechniqueMismatch
        }
        guard evidence.stance == stance else {
            throw CoachingCycleError.attemptStanceMismatch
        }

        let attemptIndex: Int
        switch stage {
        case .baseline: attemptIndex = baselineAttempts.count + 1
        case .retest: attemptIndex = retestAttempts.count + 1
        default: throw CoachingCycleError.invalidTransition(expected: .baseline, actual: stage)
        }
        let expectedSide: BodySide
        if technique.hand == .either {
            expectedSide = attemptIndex.isMultiple(of: 2) ? stance.rearSide : stance.leadSide
        } else {
            expectedSide = technique.hand.side(for: stance)
        }
        guard evidence.side == expectedSide else {
            throw CoachingCycleError.attemptHandMismatch
        }
        guard evidence.punch.trackedFraction >= track.scoringPolicy.minimumTrackedFraction,
              evidence.score.trackedFraction >= track.scoringPolicy.minimumTrackedFraction,
              !evidence.score.wrongHand,
              !evidence.score.metrics.compactMap(\.score).isEmpty
        else { throw CoachingCycleError.attemptNotAdmissible }

        let availableMetrics = Set(evidence.score.metrics.compactMap { metric in
            metric.score == nil ? nil : metric.kind
        })
        let admittedInStage = stage == .baseline ? baselineAttempts : retestAttempts
        if let first = admittedInStage.first?.evidence {
            let firstAvailability = Set(first.score.metrics.compactMap { metric in
                metric.score == nil ? nil : metric.kind
            })
            guard availableMetrics == firstAvailability,
                  evidence.identity.referenceVersion == first.identity.referenceVersion,
                  evidence.identity.scoringVersion == first.identity.scoringVersion,
                  evidence.identity.calibrationVersion == first.identity.calibrationVersion
            else { throw CoachingCycleError.attemptNotAdmissible }
        }
        if stage == .retest, let baselineSnapshot {
            let baselineAvailability = Set(baselineSnapshot.score.metrics.compactMap { metric in
                metric.score == nil ? nil : metric.kind
            })
            guard availableMetrics == baselineAvailability,
                  evidence.identity.referenceVersion == baselineSnapshot.identity.referenceVersion,
                  evidence.identity.scoringVersion == baselineSnapshot.identity.scoringVersion,
                  evidence.identity.calibrationVersion == baselineSnapshot.identity.calibrationVersion
            else { throw CoachingCycleError.attemptNotAdmissible }
        }
    }

    private func aggregateEvidence(
        from attempts: [CoachingAttemptEvidence]
    ) -> TechniqueAttemptEvidence? {
        guard attempts.count == Self.requiredAttempts,
              let last = attempts.last,
              let score = TechniqueScore.averaging(
                attempts.map(\.evidence.score),
                techniqueID: technique.id
              )
        else { return nil }

        let quality = Dictionary(uniqueKeysWithValues: score.metrics.compactMap { metric in
            metric.quality.map { (metric.kind, $0) }
        })
        return try? TechniqueAttemptEvidence(
            punch: last.evidence.punch,
            score: score,
            metricQuality: quality,
            referenceVersion: last.evidence.identity.referenceVersion,
            scoringVersion: last.evidence.identity.scoringVersion,
            calibrationVersion: last.evidence.identity.calibrationVersion
        )
    }

    private func makeCorrectionOverlay(
        focus: SubMetricKind,
        decision: CorrectionDecision
    ) -> CorrectionPathOverlay? {
        guard let attempt = baselineAttempts.min(by: { lhs, rhs in
            (lhs.evidence.score.metric(focus)?.score ?? 100)
                < (rhs.evidence.score.metric(focus)?.score ?? 100)
        }) else { return nil }

        let count = min(attempt.actualPath.count, attempt.referencePath.count)
        guard count > 0 else { return nil }
        let actual = Self.resample(attempt.actualPath, count: count)
        let reference = Self.resample(attempt.referencePath, count: count)
        let worstIndex = zip(actual, reference).enumerated().max { lhs, rhs in
            simd_distance(lhs.element.0, lhs.element.1)
                < simd_distance(rhs.element.0, rhs.element.1)
        }?.offset ?? 0
        let lower = max(0, worstIndex - 2)
        let upper = min(count - 1, worstIndex + 2)

        return CorrectionPathOverlay(
            side: attempt.evidence.side,
            actualPath: Array(actual[lower...upper]),
            referencePath: Array(reference[lower...upper]),
            actualLabel: "Actual path · Measured",
            referenceLabel: "Reference path · Estimated fit",
            actualColorName: "Coral",
            referenceColorName: "Cyan",
            trackedFraction: attempt.evidence.score.trackedFraction,
            cue: decision.localCue,
            sourceBadge: "Measured locally · Offline coach"
        )
    }

    private mutating func transition(from: LearningStage, to: LearningStage) {
        completedStages.append(from)
        stage = to
        hasPartialAttempt = false
    }

    private func requireStage(_ expected: LearningStage) throws {
        guard stage == expected else {
            throw CoachingCycleError.invalidTransition(expected: expected, actual: stage)
        }
    }

    private static func resample(
        _ path: [SIMD3<Float>],
        count: Int
    ) -> [SIMD3<Float>] {
        guard count > 1, path.count > 1 else {
            return Array(repeating: path.first ?? .zero, count: max(1, count))
        }
        return (0..<count).map { index in
            let position = Float(index) * Float(path.count - 1) / Float(count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(path.count - 1, lower + 1)
            let fraction = position - Float(lower)
            return simd_mix(path[lower], path[upper], SIMD3(repeating: fraction))
        }
    }

    private static func signed(_ value: Float) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }
}
