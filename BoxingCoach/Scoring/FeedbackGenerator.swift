import Foundation

/// Natural-language coaching for one attempt.
nonisolated struct CoachingFeedback: Sendable, Equatable {
    /// One line summarizing how the punch went.
    var headline: String
    /// The single most valuable correction for the next rep.
    var primaryFix: String
    /// Something the user did well, so feedback isn't purely negative.
    var encouragement: String

    /// True when this came from the offline generator rather than the model.
    var isOffline: Bool = false
}

/// Turns a deterministic `TechniqueScore` into coaching a beginner can act on.
///
/// **The generator never decides the score.** It receives numbers that were already computed
/// geometrically and writes prose about them. That split is what makes the feedback trustworthy:
/// the same attempt always produces the same score, and the model's only job is explaining it.
/// A model that could move the number could also flatter the user into a bad habit.
protocol FeedbackGenerating: Sendable {
    func feedback(for score: TechniqueScore, technique: Technique) async -> CoachingFeedback
}

// MARK: - Offline

/// Deterministic, offline coaching built from the sub-metric breakdown.
///
/// **This is the demo's safety net.** Conference wifi fails, and a live demo that hangs waiting on
/// a network call is worse than one with slightly less eloquent coaching — so this runs instantly,
/// never fails, and is good enough to ship on its own.
nonisolated struct MockFeedbackGenerator: FeedbackGenerating {
    func feedback(for score: TechniqueScore, technique: Technique) async -> CoachingFeedback {
        CoachingFeedback(
            headline: headline(for: score, technique: technique),
            primaryFix: primaryFix(for: score, technique: technique),
            encouragement: encouragement(for: score),
            isOffline: true
        )
    }

    private func headline(for score: TechniqueScore, technique: Technique) -> String {
        let base = "\(technique.name): \(Int(score.overall.rounded()))/100 — \(score.grade)."
        guard score.wrongHand else { return base }
        return "\(base) Wrong hand — that one doesn't count as a \(technique.name.lowercased())."
    }

    private func primaryFix(for score: TechniqueScore, technique: Technique) -> String {
        // The hand comes first when it was wrong. Coaching someone's elbow on a punch they threw
        // with the wrong arm fixes the wrong problem — they have to throw it off the right hand
        // before anything else about the shape is worth talking about.
        if let note = score.wrongHandNote {
            return "\(note) Throw the next one off your \(score.requiredHandName)."
        }

        guard let weakest = score.weakest, let value = weakest.score, value < 85 else {
            // Nothing stands out as wrong, so fall back to a technique cue rather than
            // manufacturing a fault the numbers don't support.
            return technique.coachingCues.first ?? "Keep the shape you just threw and repeat it."
        }
        return "Next rep, focus on this: \(weakest.kind.faultDescription). \(cue(for: weakest.kind, technique: technique))"
    }

    private func encouragement(for score: TechniqueScore) -> String {
        guard let strongest = score.strongest, let value = strongest.score, value >= 70 else {
            return "Early reps are about the shape, not the score — keep going."
        }
        return "Your \(strongest.kind.title.lowercased()) looked good — keep that part."
    }

    /// Pairs a failing sub-metric with the technique's own cue for that fault, so the advice is
    /// specific to the punch rather than generic.
    private func cue(for kind: SubMetricKind, technique: Technique) -> String {
        let cues = technique.coachingCues
        switch kind {
        case .extensionReach: return cues.first(where: { $0.lowercased().contains("straight") || $0.lowercased().contains("drive") }) ?? "Reach all the way through the target."
        case .path: return cues.first(where: { $0.lowercased().contains("straight") || $0.lowercased().contains("level") }) ?? "Send the fist on the shortest line to the target."
        case .elbow: return cues.first(where: { $0.lowercased().contains("elbow") }) ?? "Keep the elbow in line with the punch."
        case .guardHand: return cues.first(where: { $0.lowercased().contains("chin") || $0.lowercased().contains("hand") }) ?? "Keep the spare hand at your chin."
        case .retraction: return cues.first(where: { $0.lowercased().contains("back") || $0.lowercased().contains("guard") }) ?? "Snap the hand straight back to guard."
        }
    }
}
