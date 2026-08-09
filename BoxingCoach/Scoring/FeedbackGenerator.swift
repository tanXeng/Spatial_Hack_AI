import Foundation

nonisolated enum CoachingFeedbackSource: String, Sendable, Equatable {
    case offlineCoach = "offline_coach"
    case aiPhrasing = "ai_phrasing"
}

/// A local, allow-listed drill selected from deterministic evidence.
///
/// This is deliberately not part of `CoachRelayResponse`: the relay may change prose only.
nonisolated enum CoachCorrectiveDrill: String, Sendable, Equatable {
    case trackingRecovery = "tracking_recovery"
    case correctHand = "correct_hand"
    case fullExtension = "full_extension"
    case straightLine = "straight_line"
    case elbowTuck = "elbow_tuck"
    case guardAnchor = "guard_anchor"
    case snapBack = "snap_back"
    case repeatShape = "repeat_shape"
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
    /// The single most valuable correction for the next rep.
    let primaryFix: String
    /// Something the user did well, so feedback isn't purely negative.
    let encouragement: String
    /// Trusted local explanation paired with the deterministic correction.
    let whyItMatters: String
    /// Optional AI context shown only after the trusted local guidance.
    let supplementalExplanation: String?
    /// Optional AI encouragement shown only inside the supplemental section.
    let supplementalEncouragement: String?
    /// Whether the result is local-only or enriched with a separately presented AI supplement.
    let source: CoachingFeedbackSource
    /// Deterministic correction selected before any relay work begins.
    let correctionCode: CoachCorrectionCode
    /// Deterministic local drill; never supplied by the relay.
    let drill: CoachCorrectiveDrill

    nonisolated init(
        headline: String,
        primaryFix: String,
        encouragement: String,
        whyItMatters: String = "",
        supplementalExplanation: String?,
        supplementalEncouragement: String?,
        source: CoachingFeedbackSource,
        correctionCode: CoachCorrectionCode,
        drill: CoachCorrectiveDrill
    ) {
        self.headline = headline
        self.primaryFix = primaryFix
        self.encouragement = encouragement
        self.whyItMatters = whyItMatters
        self.supplementalExplanation = supplementalExplanation
        self.supplementalEncouragement = supplementalEncouragement
        self.source = source
        self.correctionCode = correctionCode
        self.drill = drill
    }

    var isOffline: Bool { source == .offlineCoach }

    func applying(_ phrasing: CoachPhrasing) -> CoachingFeedback {
        CoachingFeedback(
            headline: headline,
            primaryFix: primaryFix,
            encouragement: encouragement,
            whyItMatters: whyItMatters,
            supplementalExplanation: phrasing.explanation,
            supplementalEncouragement: phrasing.encouragement,
            source: .aiPhrasing,
            correctionCode: correctionCode,
            drill: drill
        )
    }
}

/// Turns a deterministic `TechniqueScore` into coaching a beginner can act on.
///
/// The generator never decides the score. The relay receives only an allow-listed score summary
/// and may explain that result; any relay failure leaves the deterministic local result intact.
nonisolated protocol FeedbackGenerating: Sendable {
    /// Pure local work. Callers publish this value before starting optional relay work.
    func localFeedback(for score: TechniqueScore, technique: Technique) -> CoachingFeedback

    /// Optional prose only. Returning nil preserves the already-published local feedback.
    func phrasing(for score: TechniqueScore, technique: Technique) async -> CoachPhrasing?
}

nonisolated extension FeedbackGenerating {
    /// Convenience for non-UI consumers. Interactive sessions use the split API so they never wait.
    func feedback(for score: TechniqueScore, technique: Technique) async -> CoachingFeedback {
        let local = localFeedback(for: score, technique: technique)
        guard let phrasing = await phrasing(for: score, technique: technique) else {
            return local
        }
        return local.applying(phrasing)
    }
}

// MARK: - Offline

nonisolated struct DeterministicCorrection: Sendable, Equatable {
    let code: CoachCorrectionCode
    let drill: CoachCorrectiveDrill
    let localCue: String
    let whyItMatters: String
}

/// Deterministic, offline coaching built from the sub-metric breakdown.
nonisolated struct MockFeedbackGenerator: FeedbackGenerating {
    func localFeedback(for score: TechniqueScore, technique: Technique) -> CoachingFeedback {
        let correction = correction(for: score, technique: technique)
        return CoachingFeedback(
            headline: headline(for: score, technique: technique),
            primaryFix: correction.localCue,
            encouragement: encouragement(for: score),
            whyItMatters: correction.whyItMatters,
            supplementalExplanation: nil,
            supplementalEncouragement: nil,
            source: .offlineCoach,
            correctionCode: correction.code,
            drill: correction.drill
        )
    }

    func phrasing(for score: TechniqueScore, technique: Technique) async -> CoachPhrasing? {
        nil
    }

    func correction(
        for score: TechniqueScore,
        technique: Technique
    ) -> DeterministicCorrection {
        let decision = CorrectionSelector().select(score: score, technique: technique)
        return DeterministicCorrection(
            code: decision.code,
            drill: decision.drill,
            localCue: decision.localCue,
            whyItMatters: decision.whyItMatters
        )
    }

    private func headline(for score: TechniqueScore, technique: Technique) -> String {
        let base = "\(technique.name): \(Int(score.overall.rounded()))/100 — \(score.grade)."
        guard score.wrongHand else { return base }
        return "\(base) Wrong hand — that one doesn't count as a \(technique.name.lowercased())."
    }

    private func encouragement(for score: TechniqueScore) -> String {
        guard let strongest = score.strongest, let value = strongest.score, value >= 70 else {
            return "Early reps are about the shape, not the score — keep going."
        }
        return "Your \(strongest.kind.title.lowercased()) looked good — keep that part."
    }

}

// MARK: - Relay

nonisolated struct CoachRelayFeedbackContext: Sendable, Equatable {
    var locale: String
    var learnerLevel: CoachLearnerLevel = .beginner
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

    func localFeedback(for score: TechniqueScore, technique: Technique) -> CoachingFeedback {
        offline.localFeedback(for: score, technique: technique)
    }

    func phrasing(for score: TechniqueScore, technique: Technique) async -> CoachPhrasing? {
        let correction = offline.correction(for: score, technique: technique)
        guard correction.code != .trackingRecovery else { return nil }
        let facts = CoachRelayRequestFacts(
            locale: context.locale,
            learnerLevel: context.learnerLevel,
            technique: technique.id,
            scoreBand: scoreBand(for: score.overall),
            trackedFraction: Double(score.trackedFraction),
            metrics: score.metrics.compactMap { metric in
                guard let value = metric.score else { return nil }
                return CoachRelayMetric(name: metric.kind.rawValue, value: Double(value))
            },
            correctionCode: correction.code,
            localCue: correction.localCue,
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
        switch overall {
        case 88...: .excellent
        case 74..<88: .solid
        case 58..<74: .developing
        default: .needsWork
        }
    }
}
