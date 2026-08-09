import Foundation

nonisolated enum CoachingFeedbackSource: String, Sendable, Equatable {
    case offlineCoach = "offline_coach"
    case aiPhrasing = "ai_phrasing"
}

/// A local, allow-listed drill selected from deterministic evidence.
///
/// This is deliberately not part of `CoachRelayResponse`: the relay may change prose only.
nonisolated enum CoachCorrectiveDrill: String, Sendable, Equatable, Codable {
    case trackingRecovery = "tracking_recovery"
    case correctHand = "correct_hand"
    case fullExtension = "full_extension"
    case straightLine = "straight_line"
    case elbowTuck = "elbow_tuck"
    case guardAnchor = "guard_anchor"
    case snapBack = "snap_back"
    case repeatShape = "repeat_shape"
}

/// Immutable deterministic decision state carried from local selection through presentation.
nonisolated struct CoachingDecisionSnapshot: Sendable, Equatable, Codable {
    let correctionCode: CoachCorrectionCode
    let drill: CoachCorrectiveDrill
    let localCue: String
    let whyItMatters: String
    let evidenceLabel: CorrectionEvidenceLabel
    let focus: SubMetricKind?
    let retainedPreviousFocus: Bool
    let audienceTrack: CoachLearnerLevel
    let audienceCopyKey: String
    let improvementDelta: Float?
    let celebratesImprovement: Bool

    init(decision: CorrectionDecision, audienceTrack: CoachLearnerLevel) {
        correctionCode = decision.code
        drill = decision.drill
        localCue = decision.localCue
        whyItMatters = decision.whyItMatters
        evidenceLabel = decision.evidenceLabel
        focus = decision.focus
        retainedPreviousFocus = decision.retainedPreviousFocus
        self.audienceTrack = audienceTrack
        audienceCopyKey = audienceTrack == .beginner
            ? decision.beginnerPhrasingKey
            : decision.athletePhrasingKey
        improvementDelta = decision.improvementDelta
        celebratesImprovement = decision.celebratesImprovement
    }
}

/// Optional, explicitly supplemental prose returned by the relay.
///
/// It contains no headline, corrective cue, score, correction, or drill fields, so applying it
/// cannot displace the deterministic coaching instruction.
nonisolated struct CoachPhrasing: Sendable, Equatable {
    let explanation: String
    let encouragement: String
}

/// Natural-language coaching for one attempt.
nonisolated struct CoachingFeedback: Sendable, Equatable {
    /// One line summarizing how the punch went.
    let headline: String
    /// Something the user did well, so feedback isn't purely negative.
    let encouragement: String
    /// Optional AI context shown only after the trusted local guidance.
    let supplementalExplanation: String?
    /// Optional AI encouragement shown only inside the supplemental section.
    let supplementalEncouragement: String?
    /// Whether the result is local-only or enriched with a separately presented AI supplement.
    let source: CoachingFeedbackSource
    /// Exact local selection state; optional relay prose cannot mutate any field inside it.
    let decision: CoachingDecisionSnapshot

    /// The single most valuable correction for the next rep.
    var primaryFix: String { decision.localCue }
    /// Trusted local explanation paired with the deterministic correction.
    var whyItMatters: String { decision.whyItMatters }
    /// Deterministic correction selected before any relay work begins.
    var correctionCode: CoachCorrectionCode { decision.correctionCode }
    /// Deterministic local drill; never supplied by the relay.
    var drill: CoachCorrectiveDrill { decision.drill }

    nonisolated init(
        headline: String,
        encouragement: String,
        supplementalExplanation: String?,
        supplementalEncouragement: String?,
        source: CoachingFeedbackSource,
        decision: CoachingDecisionSnapshot
    ) {
        self.headline = headline
        self.encouragement = encouragement
        self.supplementalExplanation = supplementalExplanation
        self.supplementalEncouragement = supplementalEncouragement
        self.source = source
        self.decision = decision
    }

    var isOffline: Bool { source == .offlineCoach }

    func applying(_ phrasing: CoachPhrasing) -> CoachingFeedback {
        CoachingFeedback(
            headline: headline,
            encouragement: encouragement,
            supplementalExplanation: phrasing.explanation,
            supplementalEncouragement: phrasing.encouragement,
            source: .aiPhrasing,
            decision: decision
        )
    }
}

/// Turns a deterministic `TechniqueScore` into coaching a beginner can act on.
///
/// The generator never decides the score. The relay receives only an allow-listed score summary
/// and may explain that result; any relay failure leaves the deterministic local result intact.
nonisolated protocol FeedbackGenerating: Sendable {
    /// Pure local work. Callers publish this value before starting optional relay work.
    func localFeedback(
        for score: TechniqueScore,
        technique: Technique,
        stance: Stance,
        previousFocus: SubMetricKind?,
        audienceTrack: CoachLearnerLevel
    ) -> CoachingFeedback

    /// Optional prose only. Returning nil preserves the already-published local feedback.
    func phrasing(
        for score: TechniqueScore,
        technique: Technique,
        decision: CoachingDecisionSnapshot
    ) async -> CoachPhrasing?
}

nonisolated extension FeedbackGenerating {
    /// Convenience for non-UI consumers. Interactive sessions use the split API so they never wait.
    func feedback(
        for score: TechniqueScore,
        technique: Technique,
        stance: Stance,
        previousFocus: SubMetricKind?,
        audienceTrack: CoachLearnerLevel
    ) async -> CoachingFeedback {
        let local = localFeedback(
            for: score,
            technique: technique,
            stance: stance,
            previousFocus: previousFocus,
            audienceTrack: audienceTrack
        )
        guard let phrasing = await phrasing(
            for: score,
            technique: technique,
            decision: local.decision
        ) else {
            return local
        }
        return local.applying(phrasing)
    }
}

// MARK: - Offline

/// Deterministic, offline coaching built from the sub-metric breakdown.
nonisolated struct MockFeedbackGenerator: FeedbackGenerating {
    func localFeedback(
        for score: TechniqueScore,
        technique: Technique,
        stance: Stance,
        previousFocus: SubMetricKind?,
        audienceTrack: CoachLearnerLevel
    ) -> CoachingFeedback {
        let decision = CorrectionSelector().select(
            score: score,
            technique: technique,
            stance: stance,
            previousFocus: previousFocus
        )
        let snapshot = CoachingDecisionSnapshot(
            decision: decision,
            audienceTrack: audienceTrack
        )
        return CoachingFeedback(
            headline: headline(for: score, technique: technique, decision: decision),
            encouragement: encouragement(for: score, decision: decision),
            supplementalExplanation: nil,
            supplementalEncouragement: nil,
            source: .offlineCoach,
            decision: snapshot
        )
    }

    func phrasing(
        for score: TechniqueScore,
        technique: Technique,
        decision: CoachingDecisionSnapshot
    ) async -> CoachPhrasing? {
        nil
    }

    private func headline(
        for score: TechniqueScore,
        technique: Technique,
        decision: CorrectionDecision
    ) -> String {
        guard decision.code != .trackingRecovery else {
            return "Tracking incomplete — no technique score yet."
        }
        guard score.overall.isFinite, (0...100).contains(score.overall) else {
            return "Tracking incomplete — no technique score yet."
        }
        let base = "\(technique.name): \(Int(score.overall.rounded()))/100 — \(score.grade)."
        guard score.wrongHand else { return base }
        return "\(base) Wrong hand — that one doesn't count as a \(technique.name.lowercased())."
    }

    private func encouragement(
        for score: TechniqueScore,
        decision: CorrectionDecision
    ) -> String {
        guard decision.code != .trackingRecovery else {
            return "Reset in guard and keep both fists visible for the full rep."
        }
        guard let strongest = score.strongest,
              let value = strongest.score,
              value.isFinite,
              value >= 70
        else {
            return "Early reps are about the shape, not the score — keep going."
        }
        return "Your \(strongest.kind.title.lowercased()) looked good — keep that part."
    }

}

// MARK: - Relay

nonisolated struct CoachRelayFeedbackContext: Sendable, Equatable {
    var locale: String
    var personalBest = false
    var validAttemptCount = 1
    var sameFocusCount = 1
}

nonisolated enum FeedbackGenerator {
    static func production(
        endpoint: URL? = CoachSecrets.relayEndpoint,
        session: URLSession = CoachRelayClient.liveSession(),
        clock: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> String = { CoachRelayClient.makeRequestID() },
        context: CoachRelayFeedbackContext = CoachRelayFeedbackContext(
            locale: Locale.current.identifier
        )
    ) -> some FeedbackGenerating {
        RelayFeedbackGenerator(
            client: CoachRelayClient(
                endpoint: endpoint,
                session: session,
                clock: clock,
                requestID: requestID
            ),
            context: context
        )
    }
}

/// Uses relay prose only after the strict client validates it against the deterministic result.
/// Network and validation errors are deliberately silent because local coaching is always valid.
nonisolated struct RelayFeedbackGenerator: FeedbackGenerating {
    let client: CoachRelayClient
    var context: CoachRelayFeedbackContext
    private let offline = MockFeedbackGenerator()

    func localFeedback(
        for score: TechniqueScore,
        technique: Technique,
        stance: Stance,
        previousFocus: SubMetricKind?,
        audienceTrack: CoachLearnerLevel
    ) -> CoachingFeedback {
        offline.localFeedback(
            for: score,
            technique: technique,
            stance: stance,
            previousFocus: previousFocus,
            audienceTrack: audienceTrack
        )
    }

    func phrasing(
        for score: TechniqueScore,
        technique: Technique,
        decision: CoachingDecisionSnapshot
    ) async -> CoachPhrasing? {
        guard decision.correctionCode != .trackingRecovery else { return nil }
        let facts = CoachRelayRequestFacts(
            locale: context.locale,
            learnerLevel: decision.audienceTrack,
            technique: technique.id,
            scoreBand: scoreBand(for: score.overall),
            trackedFraction: Double(score.trackedFraction),
            metrics: score.metrics.compactMap { metric in
                guard let value = metric.score, value.isFinite else { return nil }
                return CoachRelayMetric(name: metric.kind.rawValue, value: Double(value))
            },
            correctionCode: decision.correctionCode,
            localCue: decision.localCue,
            personalBest: context.personalBest,
            validAttemptCount: context.validAttemptCount,
            sameFocusCount: context.sameFocusCount
        )

        do {
            let response = try await client.response(for: facts)
            // The exact relay contract still validates `spokenCue`, but a free-form cue can never
            // replace the deterministic correction. Only clearly supplemental fields cross into
            // visible feedback state.
            return CoachPhrasing(
                explanation: response.whyItMatters,
                encouragement: response.encouragement
            )
        } catch {
            return nil
        }
    }

    private func scoreBand(for overall: Float) -> CoachScoreBand {
        guard overall.isFinite else { return .needsWork }
        switch overall {
        case 88...: return .excellent
        case 74..<88: return .solid
        case 58..<74: return .developing
        default: return .needsWork
        }
    }
}
