import Foundation

/// The ordered, explicit stages of one learn-practice-prove coaching cycle.
nonisolated enum LearningStage: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case fit
    case learnWatch
    case learnOutbound
    case learnLanding
    case learnReturn
    case guidedRehearsal
    case baseline
    case correction
    case correctiveDrill
    case retest
    case proof
    case transfer
    case complete

    var id: String { rawValue }
}

nonisolated enum LearningEvidenceRejectionReason: Error, Hashable, Sendable, Codable {
    case nonFinite(field: String)
    case invalidRange(field: String)
    case techniqueMismatch(expected: String, actual: String)
    case missingMetricQuality(SubMetricKind)
    case attemptIdentityMismatch
    case proofIncompatible(field: String)
    case incompleteCycle
}

/// Provenance for one deterministic score metric.
nonisolated struct MetricMeasurement: Hashable, Sendable, Codable {
    let kind: SubMetricKind
    let quality: MeasurementQuality
}

/// Stable identity for one version of an admitted technique attempt.
nonisolated struct TechniqueAttemptIdentity: Hashable, Sendable, Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case techniqueID
        case stance
        case side
        case referenceVersion
        case scoringVersion
        case calibrationVersion
    }

    let id: UUID
    let version: UInt64
    let techniqueID: String
    let stance: Stance
    let side: BodySide
    let referenceVersion: UInt64
    let scoringVersion: UInt64
    let calibrationVersion: UInt64

    init(
        id: UUID,
        version: UInt64,
        techniqueID: String,
        stance: Stance,
        side: BodySide,
        referenceVersion: UInt64 = 1,
        scoringVersion: UInt64 = 1,
        calibrationVersion: UInt64 = 1
    ) throws {
        guard version > 0 else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "version")
        }
        guard !techniqueID.isEmpty else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "techniqueID")
        }
        guard referenceVersion > 0 else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "referenceVersion")
        }
        guard scoringVersion > 0 else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "scoringVersion")
        }
        guard calibrationVersion > 0 else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "calibrationVersion")
        }

        self.id = id
        self.version = version
        self.techniqueID = techniqueID
        self.stance = stance
        self.side = side
        self.referenceVersion = referenceVersion
        self.scoringVersion = scoringVersion
        self.calibrationVersion = calibrationVersion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            version: values.decode(UInt64.self, forKey: .version),
            techniqueID: values.decode(String.self, forKey: .techniqueID),
            stance: values.decode(Stance.self, forKey: .stance),
            side: values.decode(BodySide.self, forKey: .side),
            referenceVersion: values.decodeIfPresent(
                UInt64.self,
                forKey: .referenceVersion
            ) ?? 1,
            scoringVersion: values.decodeIfPresent(
                UInt64.self,
                forKey: .scoringVersion
            ) ?? 1,
            calibrationVersion: values.decodeIfPresent(
                UInt64.self,
                forKey: .calibrationVersion
            ) ?? 1
        )
    }
}

/// An admitted punch paired with its deterministic score and metric provenance.
///
/// `TechniqueScore` is retained rather than recreating its scoring payload, while the raw
/// `RecordedAttempt` stays behind the scoring boundary.
nonisolated struct TechniqueAttemptEvidence: Sendable {
    let identity: TechniqueAttemptIdentity
    let punch: ValidatedPunchEvidence
    let score: TechniqueScore
    let metricMeasurements: [MetricMeasurement]

    var technique: Technique { punch.technique }
    var stance: Stance { punch.stance }
    var side: BodySide { punch.side }

    init(
        punch: ValidatedPunchEvidence,
        score: TechniqueScore,
        metricQuality: [SubMetricKind: MeasurementQuality],
        attemptID: UUID = UUID(),
        version: UInt64 = 1,
        referenceVersion: UInt64 = 1,
        scoringVersion: UInt64 = 1,
        calibrationVersion: UInt64 = 1
    ) throws {
        guard version > 0 else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "version")
        }
        guard referenceVersion > 0 else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "referenceVersion")
        }
        guard scoringVersion > 0 else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "scoringVersion")
        }
        guard calibrationVersion > 0 else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "calibrationVersion")
        }
        guard score.techniqueID == punch.technique.id else {
            throw LearningEvidenceRejectionReason.techniqueMismatch(
                expected: punch.technique.id,
                actual: score.techniqueID
            )
        }
        try LearningEvidenceValidation.requireFinite(score.overall, field: "score.overall")
        try LearningEvidenceValidation.requireScore(score.overall, field: "score.overall")
        try LearningEvidenceValidation.requireFinite(
            score.trackedFraction,
            field: "score.trackedFraction"
        )
        guard (0...1).contains(score.trackedFraction) else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "score.trackedFraction")
        }
        try LearningEvidenceValidation.requireFinite(score.duration, field: "score.duration")
        guard score.duration >= 0 else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "score.duration")
        }

        var seenMetrics: Set<SubMetricKind> = []
        var measurements: [MetricMeasurement] = []
        for metric in score.metrics {
            guard seenMetrics.insert(metric.kind).inserted else {
                throw LearningEvidenceRejectionReason.invalidRange(field: "score.metrics")
            }
            try LearningEvidenceValidation.requireFinite(
                metric.measured,
                field: "score.metrics.\(metric.kind.rawValue).measured"
            )
            if let metricScore = metric.score {
                try LearningEvidenceValidation.requireFinite(
                    metricScore,
                    field: "score.metrics.\(metric.kind.rawValue).score"
                )
                try LearningEvidenceValidation.requireScore(
                    metricScore,
                    field: "score.metrics.\(metric.kind.rawValue).score"
                )
            }
            guard let quality = metricQuality[metric.kind] else {
                throw LearningEvidenceRejectionReason.missingMetricQuality(metric.kind)
            }
            measurements.append(MetricMeasurement(kind: metric.kind, quality: quality))
        }

        self.identity = try TechniqueAttemptIdentity(
            id: attemptID,
            version: version,
            techniqueID: punch.technique.id,
            stance: punch.stance,
            side: punch.side,
            referenceVersion: referenceVersion,
            scoringVersion: scoringVersion,
            calibrationVersion: calibrationVersion
        )
        self.punch = punch
        self.score = score
        self.metricMeasurements = measurements.sorted {
            let order = SubMetricKind.allCases
            return (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0)
        }
    }

    func quality(for kind: SubMetricKind) -> MeasurementQuality? {
        metricMeasurements.first { $0.kind == kind }?.quality
    }
}

/// One actionable correction selected from deterministic submetric evidence.
nonisolated struct CorrectionPlan: Hashable, Sendable, Codable {
    private enum CodingKeys: String, CodingKey {
        case technique
        case focus
        case rationale
        case cue
        case rehearsalCount
        case targetImprovement
    }

    let technique: Technique
    let focus: SubMetricKind
    let rationale: String
    let cue: String
    let rehearsalCount: Int
    let targetImprovement: Float

    init(
        technique: Technique,
        focus: SubMetricKind,
        rationale: String,
        cue: String,
        rehearsalCount: Int,
        targetImprovement: Float
    ) throws {
        try LearningEvidenceValidation.requireFinite(
            targetImprovement,
            field: "targetImprovement"
        )
        guard rehearsalCount > 0 else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "rehearsalCount")
        }
        guard targetImprovement >= 0 else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "targetImprovement")
        }
        guard !rationale.isEmpty else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "rationale")
        }
        guard !cue.isEmpty else {
            throw LearningEvidenceRejectionReason.invalidRange(field: "cue")
        }

        self.technique = technique
        self.focus = focus
        self.rationale = rationale
        self.cue = cue
        self.rehearsalCount = rehearsalCount
        self.targetImprovement = targetImprovement
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            technique: values.decode(Technique.self, forKey: .technique),
            focus: values.decode(SubMetricKind.self, forKey: .focus),
            rationale: values.decode(String.self, forKey: .rationale),
            cue: values.decode(String.self, forKey: .cue),
            rehearsalCount: values.decode(Int.self, forKey: .rehearsalCount),
            targetImprovement: values.decode(Float.self, forKey: .targetImprovement)
        )
    }
}

nonisolated struct MetricDelta: Hashable, Sendable, Codable {
    let kind: SubMetricKind
    let delta: Float
}

/// A like-for-like baseline/retest comparison; positive deltas mean improvement.
nonisolated struct ProofComparison: Sendable {
    let baseline: TechniqueAttemptEvidence
    let retest: TechniqueAttemptEvidence
    let overallDelta: Float
    let metricDeltas: [MetricDelta]

    init(
        baseline: TechniqueAttemptEvidence,
        retest: TechniqueAttemptEvidence
    ) throws {
        let minimumTrackedFraction = CorrectionSelector.minimumTrackedFraction
        guard baseline.punch.trackedFraction >= minimumTrackedFraction,
              baseline.score.trackedFraction >= minimumTrackedFraction,
              retest.punch.trackedFraction >= minimumTrackedFraction,
              retest.score.trackedFraction >= minimumTrackedFraction
        else {
            throw LearningEvidenceRejectionReason.proofIncompatible(
                field: "trackingCoverage"
            )
        }
        guard !baseline.score.wrongHand, !retest.score.wrongHand else {
            throw LearningEvidenceRejectionReason.proofIncompatible(field: "wrongHand")
        }
        guard baseline.technique == retest.technique,
              baseline.stance == retest.stance,
              baseline.side == retest.side
        else { throw LearningEvidenceRejectionReason.attemptIdentityMismatch }
        guard baseline.identity.referenceVersion == retest.identity.referenceVersion else {
            throw LearningEvidenceRejectionReason.proofIncompatible(field: "reference")
        }
        guard baseline.identity.scoringVersion == retest.identity.scoringVersion else {
            throw LearningEvidenceRejectionReason.proofIncompatible(field: "scoring")
        }
        guard baseline.identity.calibrationVersion == retest.identity.calibrationVersion else {
            throw LearningEvidenceRejectionReason.proofIncompatible(field: "calibration")
        }

        let baselineAvailability = Set(baseline.score.metrics.compactMap { metric in
            metric.score == nil ? nil : metric.kind
        })
        let retestAvailability = Set(retest.score.metrics.compactMap { metric in
            metric.score == nil ? nil : metric.kind
        })
        guard baselineAvailability == retestAvailability else {
            throw LearningEvidenceRejectionReason.proofIncompatible(
                field: "metricAvailability"
            )
        }

        let overallDelta = retest.score.overall - baseline.score.overall
        try LearningEvidenceValidation.requireFinite(overallDelta, field: "overallDelta")

        let deltas = SubMetricKind.allCases.compactMap { kind -> MetricDelta? in
            guard let baselineScore = baseline.score.metric(kind)?.score,
                  let retestScore = retest.score.metric(kind)?.score
            else { return nil }
            return MetricDelta(kind: kind, delta: retestScore - baselineScore)
        }
        for delta in deltas {
            try LearningEvidenceValidation.requireFinite(
                delta.delta,
                field: "metricDeltas.\(delta.kind.rawValue)"
            )
        }

        self.baseline = baseline
        self.retest = retest
        self.overallDelta = overallDelta
        self.metricDeltas = deltas
    }

    func metricDelta(for kind: SubMetricKind) -> Float? {
        metricDeltas.first { $0.kind == kind }?.delta
    }
}

/// The immutable output of one complete coaching cycle.
nonisolated struct CoachingCycleResult: Sendable {
    let track: TrainingTrack
    let technique: Technique
    let stance: Stance
    let completedStages: [LearningStage]
    let baseline: TechniqueAttemptEvidence
    let correction: CorrectionPlan
    let retest: TechniqueAttemptEvidence
    let proof: ProofComparison
    let completedAt: Date

    init(
        track: TrainingTrack,
        technique: Technique,
        stance: Stance,
        completedStages: [LearningStage],
        baseline: TechniqueAttemptEvidence,
        correction: CorrectionPlan,
        retest: TechniqueAttemptEvidence,
        proof: ProofComparison,
        completedAt: Date
    ) throws {
        guard completedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LearningEvidenceRejectionReason.nonFinite(field: "completedAt")
        }
        guard completedStages == LearningStage.allCases else {
            throw LearningEvidenceRejectionReason.incompleteCycle
        }
        guard technique == baseline.technique,
              technique == retest.technique,
              technique == correction.technique,
              stance == baseline.stance,
              stance == retest.stance,
              proof.baseline.identity == baseline.identity,
              proof.retest.identity == retest.identity,
              proof.overallDelta == retest.score.overall - baseline.score.overall
        else { throw LearningEvidenceRejectionReason.attemptIdentityMismatch }

        self.track = track
        self.technique = technique
        self.stance = stance
        self.completedStages = completedStages
        self.baseline = baseline
        self.correction = correction
        self.retest = retest
        self.proof = proof
        self.completedAt = completedAt
    }
}

nonisolated private enum LearningEvidenceValidation {
    static func requireFinite(_ value: Float, field: String) throws {
        guard value.isFinite else {
            throw LearningEvidenceRejectionReason.nonFinite(field: field)
        }
    }

    static func requireFinite(_ value: TimeInterval, field: String) throws {
        guard value.isFinite else {
            throw LearningEvidenceRejectionReason.nonFinite(field: field)
        }
    }

    static func requireScore(_ value: Float, field: String) throws {
        guard (0...100).contains(value) else {
            throw LearningEvidenceRejectionReason.invalidRange(field: field)
        }
    }
}
