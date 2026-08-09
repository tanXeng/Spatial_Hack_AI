import Foundation

/// Natural-language coaching for one attempt.
nonisolated struct CoachingFeedback: Sendable, Equatable {
    /// One line summarizing how the punch went.
    var headline: String
    /// The single most valuable correction for the next rep.
    var primaryFix: String
    /// Something the user did well, so feedback isn't purely negative.
    var encouragement: String

    /// True when this came from the deterministic local generator.
    var isOffline: Bool = false
}

/// Turns a deterministic `TechniqueScore` into coaching a beginner can act on.
///
/// The generator never decides the score. The relay receives only an allow-listed score summary
/// and may explain that result; any relay failure leaves the deterministic local result intact.
protocol FeedbackGenerating: Sendable {
    func feedback(for score: TechniqueScore, technique: Technique) async -> CoachingFeedback
}

// MARK: - Offline

nonisolated struct DeterministicCorrection: Sendable, Equatable {
    let code: CoachCorrectionCode
    let localCue: String
}

/// Deterministic, offline coaching built from the sub-metric breakdown.
nonisolated struct MockFeedbackGenerator: FeedbackGenerating {
    func feedback(for score: TechniqueScore, technique: Technique) async -> CoachingFeedback {
        CoachingFeedback(
            headline: headline(for: score, technique: technique),
            primaryFix: correction(for: score, technique: technique).localCue,
            encouragement: encouragement(for: score),
            isOffline: true
        )
    }

    func correction(
        for score: TechniqueScore,
        technique: Technique
    ) -> DeterministicCorrection {
        if let note = score.wrongHandNote {
            return DeterministicCorrection(
                code: .wrongHand,
                localCue: "\(note) Throw the next one off your \(score.requiredHandName)."
            )
        }

        guard let weakest = score.weakest, let value = weakest.score, value < 85 else {
            return DeterministicCorrection(
                code: .repeatShape,
                localCue: technique.coachingCues.first
                    ?? "Keep the shape you just threw and repeat it."
            )
        }
        return DeterministicCorrection(
            code: correctionCode(for: weakest.kind),
            localCue: "Next rep, focus on this: \(weakest.kind.faultDescription). \(cue(for: weakest.kind, technique: technique))"
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

    private func correctionCode(for kind: SubMetricKind) -> CoachCorrectionCode {
        switch kind {
        case .extensionReach: .extensionReach
        case .path: .path
        case .elbow: .elbow
        case .guardHand: .guardHand
        case .retraction: .retraction
        }
    }

    private func cue(for kind: SubMetricKind, technique: Technique) -> String {
        let cues = technique.coachingCues
        switch kind {
        case .extensionReach:
            return cues.first(where: {
                $0.lowercased().contains("straight") || $0.lowercased().contains("drive")
            }) ?? "Reach all the way through the target."
        case .path:
            return cues.first(where: {
                $0.lowercased().contains("straight") || $0.lowercased().contains("level")
            }) ?? "Send the fist on the shortest line to the target."
        case .elbow:
            return cues.first(where: { $0.lowercased().contains("elbow") })
                ?? "Keep the elbow in line with the punch."
        case .guardHand:
            return cues.first(where: {
                $0.lowercased().contains("chin") || $0.lowercased().contains("hand")
            }) ?? "Keep the spare hand at your chin."
        case .retraction:
            return cues.first(where: {
                $0.lowercased().contains("back") || $0.lowercased().contains("guard")
            }) ?? "Snap the hand straight back to guard."
        }
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
        requestID: @escaping @Sendable () -> String = { UUID().uuidString },
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

    func feedback(for score: TechniqueScore, technique: Technique) async -> CoachingFeedback {
        let localFeedback = await offline.feedback(for: score, technique: technique)
        let correction = offline.correction(for: score, technique: technique)
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
            return CoachingFeedback(
                headline: response.spokenCue,
                primaryFix: response.why,
                encouragement: response.encouragement,
                isOffline: false
            )
        } catch {
            return localFeedback
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
