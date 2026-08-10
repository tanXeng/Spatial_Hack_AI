import Foundation
import simd

nonisolated enum CoachingCycleError: Error, Equatable, Sendable {
    case invalidTransition(expected: LearningStage, actual: LearningStage)
    case attemptNotAdmissible
    case attemptTechniqueMismatch
    case attemptStanceMismatch
    case attemptHandMismatch
    case unavailableProof
    case proofThresholdNotMet
    case trainingPaused
}

nonisolated enum CoachingAttemptRejection: Equatable, Sendable {
    case invalidEvidence
    case trackingLost
    case trainingPaused
}

/// Immutable admitted evidence plus the exact body-relative samples used to score the attempt.
nonisolated struct CoachingAttemptEvidence: Sendable {
    let evidence: TechniqueAttemptEvidence
    let actualSamples: [MotionSample]
    let referenceSamples: [MotionSample]

    var actualPath: [SIMD3<Float>] { actualSamples.map(\.fist) }
    var referencePath: [SIMD3<Float>] { referenceSamples.map(\.fist) }

    init(
        evidence: TechniqueAttemptEvidence,
        actualSamples: [MotionSample],
        referenceSamples: [MotionSample]
    ) throws {
        guard !actualSamples.isEmpty,
              !referenceSamples.isEmpty,
              actualSamples.allSatisfy(Self.isFinite),
              referenceSamples.allSatisfy(Self.isFinite)
        else { throw CoachingCycleError.attemptNotAdmissible }

        self.evidence = evidence
        self.actualSamples = actualSamples
        self.referenceSamples = referenceSamples
    }

    /// Compatibility boundary for older callers that retained only fist positions. New live
    /// admissions use the sample initializer so interpolation provenance is never invented.
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
        self.actualSamples = Self.samples(from: actualPath, tracked: true)
        self.referenceSamples = Self.samples(from: referencePath, tracked: false)
    }

    private static func samples(
        from path: [SIMD3<Float>],
        tracked: Bool
    ) -> [MotionSample] {
        path.enumerated().map { index, point in
            MotionSample(
                time: TimeInterval(index),
                fist: point,
                elbow: point,
                guardHand: nil,
                isTracked: tracked
            )
        }
    }

    private static func isFinite(_ sample: MotionSample) -> Bool {
        sample.time.isFinite
            && sample.fist.isFinite
            && sample.elbow.isFinite
            && (sample.guardHand?.isFinite ?? true)
    }
}

nonisolated enum CorrectionPathProvenance: Equatable, Sendable {
    case measured
    case interpolated
    case estimated
}

nonisolated struct CorrectionPathSample: Equatable, Sendable {
    let position: SIMD3<Float>
    let provenance: CorrectionPathProvenance
}

nonisolated struct CorrectionPathOverlay: Equatable, Sendable {
    let side: BodySide
    let focus: SubMetricKind
    let alignmentDistance: Float
    let actualSamples: [CorrectionPathSample]
    let referenceSamples: [CorrectionPathSample]
    let actualLabel: String
    let referenceLabel: String
    let actualColorName: String
    let referenceColorName: String
    let trackedFraction: Float
    let cue: String
    let sourceBadge: String

    var actualPath: [SIMD3<Float>] { actualSamples.map(\.position) }
    var referencePath: [SIMD3<Float>] { referenceSamples.map(\.position) }
}

/// Selects only the geometry which produced the focused score. Path/elbow/guard corrections use
/// DTW below; extension and retraction use their scorer's semantic endpoints instead of an
/// arbitrary aligned midpoint.
nonisolated enum CorrectionOverlayGeometry {
    nonisolated struct Selection: Equatable, Sendable {
        let actual: [CorrectionPathSample]
        let reference: [CorrectionPathSample]
        let metricError: Float
    }

    static func selection(
        focus: SubMetricKind,
        actual: [MotionSample],
        reference: [MotionSample],
        techniqueID: String
    ) -> Selection? {
        switch focus {
        case .extensionReach:
            guard let actualSelection = PunchExtensionSemantics.selection(
                samples: actual,
                techniqueID: techniqueID
            ),
            let referenceSelection = PunchExtensionSemantics.selection(
                samples: reference,
                techniqueID: techniqueID
            ) else { return nil }
            return Selection(
                actual: actualSelection.sampleIndices.map { index in
                    CorrectionPathSample(
                        position: actual[index].fist,
                        provenance: actual[index].isTracked ? .measured : .interpolated
                    )
                },
                reference: referenceSelection.sampleIndices.map { index in
                    CorrectionPathSample(
                        position: reference[index].fist,
                        provenance: .estimated
                    )
                },
                metricError: max(0, referenceSelection.magnitude - actualSelection.magnitude)
            )
        case .retraction:
            guard let selected = PunchRetractionSemantics.selection(
                attempt: actual,
                reference: reference
            ) else { return nil }
            let actualSample = actual[selected.attemptIndex]
            return Selection(
                actual: [CorrectionPathSample(
                    position: actualSample.fist,
                    provenance: actualSample.isTracked ? .measured : .interpolated
                )],
                reference: [CorrectionPathSample(
                    position: reference[selected.referenceIndex].fist,
                    provenance: .estimated
                )],
                metricError: selected.error
            )
        case .path, .elbow, .guardHand:
            return nil
        }
    }
}

/// A three-attempt coaching round. Its aggregate score is explicitly round-level; it is never
/// paired with one punch or assigned a synthetic attempt identity.
nonisolated struct CoachingRoundEvidence: Sendable {
    let attempts: [CoachingAttemptEvidence]
    let score: TechniqueScore

    init(attempts: [CoachingAttemptEvidence], technique: Technique) throws {
        guard attempts.count == CoachingCycleSession.requiredAttempts,
              let first = attempts.first,
              attempts.allSatisfy({ $0.evidence.technique == technique }),
              attempts.allSatisfy({
                  $0.evidence.stance == first.evidence.stance
                      && $0.evidence.identity.referenceVersion
                          == first.evidence.identity.referenceVersion
                      && $0.evidence.identity.scoringVersion
                          == first.evidence.identity.scoringVersion
                      && $0.evidence.identity.calibrationVersion
                          == first.evidence.identity.calibrationVersion
              }),
              Set(attempts.map(\.evidence.identity.id)).count == attempts.count,
              let score = TechniqueScore.averaging(
                  attempts.map(\.evidence.score),
                  techniqueID: technique.id
              )
        else { throw CoachingCycleError.attemptNotAdmissible }

        let metricAvailability = attempts.map { attempt in
            Set(attempt.evidence.score.metrics.compactMap { metric in
                metric.score == nil ? nil : metric.kind
            })
        }
        guard metricAvailability.dropFirst().allSatisfy({ $0 == metricAvailability[0] }) else {
            throw CoachingCycleError.attemptNotAdmissible
        }

        self.attempts = attempts
        self.score = score
    }
}

/// Like-for-like proof over two complete rounds. The six original punch-score identities remain
/// available through `baseline.attempts` and `retest.attempts`.
nonisolated struct CoachingRoundProof: Sendable {
    let baseline: CoachingRoundEvidence
    let retest: CoachingRoundEvidence
    let overallDelta: Float
    let metricDeltas: [MetricDelta]

    init(baseline: CoachingRoundEvidence, retest: CoachingRoundEvidence) throws {
        guard let baselineFirst = baseline.attempts.first?.evidence,
              let retestFirst = retest.attempts.first?.evidence,
              baselineFirst.technique == retestFirst.technique,
              baselineFirst.stance == retestFirst.stance,
              baseline.attempts.map(\.evidence.side) == retest.attempts.map(\.evidence.side),
              baselineFirst.identity.referenceVersion == retestFirst.identity.referenceVersion,
              baselineFirst.identity.scoringVersion == retestFirst.identity.scoringVersion,
              baselineFirst.identity.calibrationVersion == retestFirst.identity.calibrationVersion
        else { throw CoachingCycleError.unavailableProof }

        let baselineAvailability = Set(baseline.score.metrics.compactMap { metric in
            metric.score == nil ? nil : metric.kind
        })
        let retestAvailability = Set(retest.score.metrics.compactMap { metric in
            metric.score == nil ? nil : metric.kind
        })
        guard baselineAvailability == retestAvailability else {
            throw CoachingCycleError.unavailableProof
        }

        let overallDelta = retest.score.overall - baseline.score.overall
        guard overallDelta.isFinite else { throw CoachingCycleError.unavailableProof }
        let metricDeltas = SubMetricKind.allCases.compactMap { kind -> MetricDelta? in
            guard let before = baseline.score.metric(kind)?.score,
                  let after = retest.score.metric(kind)?.score,
                  (after - before).isFinite
            else { return nil }
            return MetricDelta(kind: kind, delta: after - before)
        }

        self.baseline = baseline
        self.retest = retest
        self.overallDelta = overallDelta
        self.metricDeltas = metricDeltas
    }

    func metricDelta(for kind: SubMetricKind) -> Float? {
        metricDeltas.first { $0.kind == kind }?.delta
    }
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

    private(set) var id: UUID
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
    private(set) var baselineRound: CoachingRoundEvidence?
    private(set) var retestRound: CoachingRoundEvidence?
    private(set) var proof: CoachingRoundProof?
    private(set) var proofMetric: CoachingProofMetric?
    private(set) var result: CoachingCycleResult?
    private(set) var hasPartialAttempt = false
    private(set) var isTrackingPaused = false
    private(set) var isTrainingPaused = false

    init(
        id: UUID = UUID(),
        track: TrainingTrack,
        technique: Technique,
        stance: Stance
    ) {
        self.id = id
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

    var proofMeetsTarget: Bool {
        proofDisposition != .retry
    }

    var proofDisposition: CoachingProofDisposition {
        guard let correction,
              let plan = correctionPlan,
              let metric = proofMetric
        else { return .retry }

        if correction.kind == .reinforce {
            return metric.baseline >= CorrectionSelector.correctionThreshold
                && metric.retest >= CorrectionSelector.correctionThreshold
                && metric.delta >= 0
                ? .reinforced
                : .retry
        }

        return metric.delta >= plan.targetImprovement ? .improved : .retry
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
            return .init(
                stage: "PROOF",
                instruction: proofMetric.map { _ in
                    switch proofDisposition {
                    case .improved:
                        return "The selected metric improved."
                    case .reinforced:
                        return "The selected metric held at its strong baseline."
                    case .retry:
                        return "The selected metric did not improve enough yet."
                    }
                } ?? "Preparing like-for-like proof.",
                action: proofMeetsTarget ? "Continue" : "Practice again",
                progress: nil,
                metric: metric,
                timer: nil
            )
        case .transfer:
            return .init(stage: "TRANSFER · 1–2", instruction: plain ? "Use the correct lead hand for the jab, then the rear hand for the cross." : "Transfer into a stance-correct 1–2.", action: "Throw 1–2", progress: nil, metric: metric, timer: nil)
        case .complete:
            return .init(stage: "COMPLETE", instruction: "Your cycle is complete.", action: "Finish", progress: nil, metric: metric, timer: nil)
        }
    }

    mutating func completeFit(reach: BilateralReach) throws {
        try requireActiveTraining()
        try requireStage(.fit)
        fittedReach = reach
        transition(from: .fit, to: .learnWatch)
    }

    mutating func completeLearningStep() throws {
        try requireActiveTraining()
        switch stage {
        case .learnWatch: transition(from: .learnWatch, to: .learnOutbound)
        case .learnOutbound: transition(from: .learnOutbound, to: .learnLanding)
        case .learnLanding: transition(from: .learnLanding, to: .learnReturn)
        case .learnReturn: transition(from: .learnReturn, to: .guidedRehearsal)
        default: throw CoachingCycleError.invalidTransition(expected: .learnWatch, actual: stage)
        }
    }

    mutating func completeGuidedRehearsal() throws {
        try requireActiveTraining()
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
        try requireActiveTraining()
        try requireStage(.correction)
        transition(from: .correction, to: .correctiveDrill)
    }

    mutating func completeCorrectiveDrill() throws {
        try requireActiveTraining()
        try requireStage(.correctiveDrill)
        transition(from: .correctiveDrill, to: .retest)
    }

    mutating func continueFromProof() throws {
        try requireActiveTraining()
        try requireStage(.proof)
        guard proof != nil else { throw CoachingCycleError.unavailableProof }
        guard proofMeetsTarget else { throw CoachingCycleError.proofThresholdNotMet }
        transition(from: .proof, to: .transfer)
    }

    mutating func retryCorrectionFromProof() throws {
        try requireActiveTraining()
        try requireStage(.proof)
        guard proof != nil else { throw CoachingCycleError.unavailableProof }
        guard !proofMeetsTarget else { throw CoachingCycleError.attemptNotAdmissible }

        retestAttempts.removeAll(keepingCapacity: false)
        retestRound = nil
        proof = nil
        proofMetric = nil
        while completedStages.last == .retest || completedStages.last == .correctiveDrill {
            completedStages.removeLast()
        }
        stage = .correctiveDrill
        hasPartialAttempt = false
    }

    mutating func completeTransfer(at completedAt: Date = Date()) throws {
        try requireActiveTraining()
        try requireStage(.transfer)
        guard baselineRound != nil,
              retestRound != nil,
              let correctionPlan,
              let proof,
              let proofMetric
        else { throw CoachingCycleError.unavailableProof }

        transition(from: .transfer, to: .complete)
        completedStages.append(.complete)
        result = try CoachingCycleResult(
            id: id,
            track: track,
            technique: technique,
            stance: stance,
            completedStages: completedStages,
            correction: correctionPlan,
            proof: proof,
            selectedProof: proofMetric,
            proofDisposition: proofDisposition,
            completedAt: completedAt
        )
    }

    mutating func reset() {
        id = UUID()
        stage = .fit
        completedStages.removeAll(keepingCapacity: false)
        fittedReach = nil
        guidedRehearsalsCompleted = 0
        baselineAttempts.removeAll(keepingCapacity: false)
        retestAttempts.removeAll(keepingCapacity: false)
        correction = nil
        correctionPlan = nil
        correctionOverlay = nil
        baselineRound = nil
        retestRound = nil
        proof = nil
        proofMetric = nil
        result = nil
        hasPartialAttempt = false
        isTrackingPaused = false
        isTrainingPaused = false
    }

    private mutating func finishBaseline() throws {
        let aggregate = try CoachingRoundEvidence(attempts: baselineAttempts, technique: technique)
        let decision = CorrectionSelector().select(
            score: aggregate.score,
            technique: technique,
            stance: stance
        )
        let focus = decision.focus ?? aggregate.score.weakest?.kind ?? .path
        correction = decision
        baselineRound = aggregate
        correctionPlan = try CorrectionPlan(
            technique: technique,
            focus: focus,
            rationale: decision.whyItMatters,
            cue: decision.localCue,
            rehearsalCount: 1,
            targetImprovement: decision.kind == .reinforce
                ? 0
                : CorrectionSelector.celebrationThreshold
        )
        correctionOverlay = makeCorrectionOverlay(focus: focus, decision: decision)
        transition(from: .baseline, to: .correction)
    }

    private mutating func finishRetest() throws {
        guard let baseline = baselineRound,
              let correction,
              let focus = correctionPlan?.focus,
              let baselineValue = baseline.score.metric(focus)?.score
        else { throw CoachingCycleError.unavailableProof }

        let retest = try CoachingRoundEvidence(attempts: retestAttempts, technique: technique)
        guard let retestValue = retest.score.metric(focus)?.score else {
            throw CoachingCycleError.unavailableProof
        }
        let comparison = try CoachingRoundProof(baseline: baseline, retest: retest)
        retestRound = retest
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
        if stage == .retest, let baselineRound {
            let baselineAvailability = Set(baselineRound.score.metrics.compactMap { metric in
                metric.score == nil ? nil : metric.kind
            })
            guard availableMetrics == baselineAvailability,
                  evidence.identity.referenceVersion
                    == baselineRound.attempts[0].evidence.identity.referenceVersion,
                  evidence.identity.scoringVersion
                    == baselineRound.attempts[0].evidence.identity.scoringVersion,
                  evidence.identity.calibrationVersion
                    == baselineRound.attempts[0].evidence.identity.calibrationVersion
            else { throw CoachingCycleError.attemptNotAdmissible }
        }
    }

    private func makeCorrectionOverlay(
        focus: SubMetricKind,
        decision: CorrectionDecision
    ) -> CorrectionPathOverlay? {
        guard let attempt = baselineAttempts.min(by: { lhs, rhs in
            (lhs.evidence.score.metric(focus)?.score ?? 100)
                < (rhs.evidence.score.metric(focus)?.score ?? 100)
        }) else { return nil }

        if let semantic = CorrectionOverlayGeometry.selection(
            focus: focus,
            actual: attempt.actualSamples,
            reference: attempt.referenceSamples,
            techniqueID: technique.id
        ) {
            return Self.overlay(
                side: attempt.evidence.side,
                focus: focus,
                alignmentDistance: semantic.metricError,
                actualSamples: semantic.actual,
                referenceSamples: semantic.reference,
                trackedFraction: attempt.evidence.score.trackedFraction,
                decision: decision
            )
        }

        guard let alignment = DTWComparator.align(
            reference: attempt.referencePath,
            attempt: attempt.actualPath
        ) else { return nil }
        let worstIndex = alignment.pairs.enumerated().max { lhs, rhs in
            Self.focusError(
                focus,
                pair: lhs.element,
                actual: attempt.actualSamples,
                reference: attempt.referenceSamples
            ) < Self.focusError(
                focus,
                pair: rhs.element,
                actual: attempt.actualSamples,
                reference: attempt.referenceSamples
            )
        }?.offset ?? 0
        let lower = max(0, worstIndex - 2)
        let upper = min(alignment.pairs.count - 1, worstIndex + 2)
        let selectedPairs = alignment.pairs[lower...upper]
        let actualSamples = selectedPairs.map { pair in
            let sample = attempt.actualSamples[pair.attempt]
            return CorrectionPathSample(
                position: sample.fist,
                provenance: sample.isTracked ? .measured : .interpolated
            )
        }
        let referenceSamples = selectedPairs.map { pair in
            CorrectionPathSample(
                position: attempt.referenceSamples[pair.reference].fist,
                provenance: .estimated
            )
        }
        return Self.overlay(
            side: attempt.evidence.side,
            focus: focus,
            alignmentDistance: alignment.normalizedDistance,
            actualSamples: actualSamples,
            referenceSamples: referenceSamples,
            trackedFraction: attempt.evidence.score.trackedFraction,
            decision: decision
        )
    }

    private static func overlay(
        side: BodySide,
        focus: SubMetricKind,
        alignmentDistance: Float,
        actualSamples: [CorrectionPathSample],
        referenceSamples: [CorrectionPathSample],
        trackedFraction: Float,
        decision: CorrectionDecision
    ) -> CorrectionPathOverlay {
        let includesInterpolation = actualSamples.contains { $0.provenance == .interpolated }
        return CorrectionPathOverlay(
            side: side,
            focus: focus,
            alignmentDistance: alignmentDistance,
            actualSamples: actualSamples,
            referenceSamples: referenceSamples,
            actualLabel: includesInterpolation
                ? "Actual path · Includes interpolated samples"
                : "Actual path · Measured",
            referenceLabel: "Reference path · Estimated fit",
            actualColorName: "Coral",
            referenceColorName: "Cyan",
            trackedFraction: trackedFraction,
            cue: decision.localCue,
            sourceBadge: "Measured locally · Offline coach"
        )
    }

    private static func focusError(
        _ focus: SubMetricKind,
        pair: AlignedPair,
        actual: [MotionSample],
        reference: [MotionSample]
    ) -> Float {
        let actualSample = actual[pair.attempt]
        let referenceSample = reference[pair.reference]
        switch focus {
        case .extensionReach:
            return abs(actualSample.reachFraction - referenceSample.reachFraction)
        case .path:
            return simd_distance(actualSample.fist, referenceSample.fist)
        case .elbow:
            return simd_distance(actualSample.elbow, referenceSample.elbow)
        case .guardHand:
            guard let actualGuard = actualSample.guardHand,
                  let referenceGuard = referenceSample.guardHand
            else { return 0 }
            return simd_distance(actualGuard, referenceGuard)
        case .retraction:
            let normalizedProgress = Float(pair.reference)
                / Float(max(1, reference.count - 1))
            return normalizedProgress >= 0.5
                ? simd_distance(actualSample.fist, referenceSample.fist)
                : 0
        }
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

    private func requireActiveTraining() throws {
        guard !isTrainingPaused else { throw CoachingCycleError.trainingPaused }
    }

    private static func signed(_ value: Float) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }
}
