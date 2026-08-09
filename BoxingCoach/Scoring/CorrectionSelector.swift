import Foundation

/// The mutually exclusive coaching outcomes produced by deterministic evidence.
nonisolated enum CorrectionSelectionKind: Sendable, Equatable {
    case trackingRecovery
    case wrongHand
    case metric(SubMetricKind)
    case reinforce
}

/// Honest source copy shown beside the selected correction.
nonisolated enum CorrectionEvidenceLabel: String, Sendable, Equatable, Codable {
    case measured = "Measured"
    case estimated = "Estimated"
    case sourceUnavailable = "Source unavailable"
    case trackingIncomplete = "Tracking incomplete"
}

/// One immutable, explainable coaching decision. None of these fields come from generative AI.
nonisolated struct CorrectionDecision: Sendable, Equatable {
    let kind: CorrectionSelectionKind
    let code: CoachCorrectionCode
    let drill: CoachCorrectiveDrill
    let localCue: String
    let whyItMatters: String
    let evidenceLabel: CorrectionEvidenceLabel
    let beginnerPhrasingKey: String
    let athletePhrasingKey: String
    let focus: SubMetricKind?
    let retainedPreviousFocus: Bool
    let improvementDelta: Float?
    let celebratesImprovement: Bool
}

/// Selects exactly one correction from admitted deterministic score facts.
///
/// Priority is fixed: evidence recovery, wrong hand, weakest available metric below 85, then
/// reinforcement. Stable metric ordering and focus retention prevent the coach from oscillating
/// between nearly tied observations from one round to the next.
nonisolated struct CorrectionSelector: Sendable {
    static let minimumTrackedFraction: Float = 0.75
    static let correctionThreshold: Float = 85
    static let focusRetentionTolerance: Float = 5
    static let celebrationThreshold: Float = 8

    nonisolated init() {}

    nonisolated func select(
        score: TechniqueScore,
        technique: Technique,
        stance: Stance,
        previousFocus: SubMetricKind? = nil
    ) -> CorrectionDecision {
        select(
            score: score,
            technique: technique,
            stance: stance,
            previousFocus: previousFocus,
            proof: nil
        )
    }

    /// Selects from the retest in an already validated like-for-like proof.
    nonisolated func select(
        proof: ProofComparison,
        previousFocus: SubMetricKind? = nil
    ) -> CorrectionDecision {
        return select(
            score: proof.retest.score,
            technique: proof.retest.technique,
            stance: proof.retest.stance,
            previousFocus: previousFocus,
            proof: proof
        )
    }

    nonisolated private func select(
        score: TechniqueScore,
        technique: Technique,
        stance: Stance,
        previousFocus: SubMetricKind?,
        proof: ProofComparison?
    ) -> CorrectionDecision {
        let available = score.metrics.filter { metric in
            guard let value = metric.score else { return false }
            return value.isFinite && (0...100).contains(value)
        }
        let hasInvalidNumericEvidence = !score.trackedFraction.isFinite
            || !(0...1).contains(score.trackedFraction)
            || !score.overall.isFinite
            || !(0...100).contains(score.overall)
            || score.metrics.contains { metric in
                metric.measured.isFinite == false
                    || metric.score?.isFinite == false
                    || metric.score.map { !(0...100).contains($0) } == true
            }

        if hasInvalidNumericEvidence
            || score.trackedFraction < Self.minimumTrackedFraction
            || available.isEmpty {
            return decision(
                for: .trackingRecovery,
                score: score,
                technique: technique,
                stance: stance,
                metric: nil,
                quality: nil,
                retainedPreviousFocus: false,
                improvementDelta: nil
            )
        }

        if score.wrongHand {
            return decision(
                for: .wrongHand,
                score: score,
                technique: technique,
                stance: stance,
                metric: nil,
                quality: .measured,
                retainedPreviousFocus: false,
                improvementDelta: nil
            )
        }

        let ordered = available.sorted { lhs, rhs in
            let lhsValue = lhs.score ?? 100
            let rhsValue = rhs.score ?? 100
            if lhsValue != rhsValue { return lhsValue < rhsValue }
            return Self.metricOrder(lhs.kind) < Self.metricOrder(rhs.kind)
        }
        guard let weakest = ordered.first, let weakestValue = weakest.score else {
            return decision(
                for: .trackingRecovery,
                score: score,
                technique: technique,
                stance: stance,
                metric: nil,
                quality: nil,
                retainedPreviousFocus: false,
                improvementDelta: nil
            )
        }

        let retainedMetric: SubMetric?
        if let previousFocus,
           let previous = available.first(where: { $0.kind == previousFocus }),
           let previousValue = previous.score,
           previousValue < Self.correctionThreshold,
           previousValue <= weakestValue + Self.focusRetentionTolerance {
            retainedMetric = previous
        } else {
            retainedMetric = nil
        }

        let selected = retainedMetric ?? weakest
        guard let selectedValue = selected.score,
              selectedValue < Self.correctionThreshold else {
            return decision(
                for: .reinforce,
                score: score,
                technique: technique,
                stance: stance,
                metric: nil,
                quality: MeasurementQuality.conservativeAggregation(
                    available.map { quality(for: $0, proof: proof) }
                ),
                retainedPreviousFocus: false,
                improvementDelta: nil
            )
        }

        return decision(
            for: .metric(selected.kind),
            score: score,
            technique: technique,
            stance: stance,
            metric: selected.kind,
            quality: quality(for: selected, proof: proof),
            retainedPreviousFocus: retainedMetric != nil,
            improvementDelta: proof?.metricDelta(for: selected.kind)
        )
    }

    /// A proof delta is derived from both attempts, so its label must represent both sources.
    nonisolated private func quality(
        for retestMetric: SubMetric,
        proof: ProofComparison?
    ) -> MeasurementQuality? {
        guard let proof else { return retestMetric.quality }
        return MeasurementQuality.conservativeAggregation([
            proof.baseline.score.metric(retestMetric.kind)?.quality,
            proof.retest.score.metric(retestMetric.kind)?.quality,
        ])
    }

    nonisolated private func decision(
        for kind: CorrectionSelectionKind,
        score: TechniqueScore,
        technique: Technique,
        stance: Stance,
        metric: SubMetricKind?,
        quality: MeasurementQuality?,
        retainedPreviousFocus: Bool,
        improvementDelta: Float?
    ) -> CorrectionDecision {
        let catalog = catalogEntry(
            for: kind,
            score: score,
            technique: technique,
            stance: stance
        )
        let evidenceLabel: CorrectionEvidenceLabel
        switch kind {
        case .trackingRecovery:
            evidenceLabel = .trackingIncomplete
        case .wrongHand:
            evidenceLabel = .measured
        case .metric:
            switch quality {
            case .measured: evidenceLabel = .measured
            case .inferred: evidenceLabel = .estimated
            case nil: evidenceLabel = .sourceUnavailable
            }
        case .reinforce:
            switch quality {
            case .measured: evidenceLabel = .measured
            case .inferred: evidenceLabel = .estimated
            case nil: evidenceLabel = .sourceUnavailable
            }
        }
        let validImprovementDelta: Float?
        if case .metric = kind, improvementDelta?.isFinite == true {
            validImprovementDelta = improvementDelta
        } else {
            validImprovementDelta = nil
        }
        let celebrates = validImprovementDelta.map {
            $0.isFinite && $0 >= Self.celebrationThreshold
        } ?? false

        return CorrectionDecision(
            kind: kind,
            code: catalog.code,
            drill: catalog.drill,
            localCue: catalog.cue,
            whyItMatters: catalog.why,
            evidenceLabel: evidenceLabel,
            beginnerPhrasingKey: catalog.beginnerKey,
            athletePhrasingKey: catalog.athleteKey,
            focus: metric,
            retainedPreviousFocus: retainedPreviousFocus,
            improvementDelta: validImprovementDelta,
            celebratesImprovement: celebrates
        )
    }

    nonisolated private func catalogEntry(
        for kind: CorrectionSelectionKind,
        score: TechniqueScore,
        technique: Technique,
        stance: Stance
    ) -> CatalogEntry {
        switch kind {
        case .trackingRecovery:
            return CatalogEntry(
                code: .trackingRecovery,
                drill: .trackingRecovery,
                cue: "Hold both closed fists in guard while tracking stabilizes.",
                why: "A full, continuous rep is required before technique can be judged honestly.",
                beginnerKey: "correction.tracking.beginner",
                athleteKey: "correction.tracking.athlete"
            )
        case .wrongHand:
            let requirement = score.requiredHandName.isEmpty
                ? technique.hand.requirementDescription(for: stance)
                : score.requiredHandName
            return CatalogEntry(
                code: .wrongHand,
                drill: .correctHand,
                cue: "Reset in guard and throw the next rep with your \(requirement).",
                why: "Correct hand selection preserves stance, range, and the intended defensive position.",
                beginnerKey: "correction.hand.beginner",
                athleteKey: "correction.hand.athlete"
            )
        case let .metric(kind):
            return metricEntry(kind)
        case .reinforce:
            return CatalogEntry(
                code: .repeatShape,
                drill: .repeatShape,
                cue: technique.coachingCues.first
                    ?? "Repeat the same balanced shape from guard to guard.",
                why: "Repeating a sound rep builds a stable movement pattern before speed is added.",
                beginnerKey: "correction.reinforce.beginner",
                athleteKey: "correction.reinforce.athlete"
            )
        }
    }

    nonisolated private func metricEntry(_ kind: SubMetricKind) -> CatalogEntry {
        switch kind {
        case .extensionReach:
            return CatalogEntry(
                code: .extensionReach,
                drill: .fullExtension,
                cue: "The punch stopped short. Reach through the target without leaning or locking the elbow.",
                why: "Usable reach lets the punch land while your stance stays balanced.",
                beginnerKey: "correction.extension.beginner",
                athleteKey: "correction.extension.athlete"
            )
        case .path:
            return CatalogEntry(
                code: .path,
                drill: .straightLine,
                cue: "Send the fist straight out and bring it back on the same line.",
                why: "A direct path arrives sooner and leaves fewer openings.",
                beginnerKey: "correction.path.beginner",
                athleteKey: "correction.path.athlete"
            )
        case .elbow:
            return CatalogEntry(
                code: .elbow,
                drill: .elbowTuck,
                cue: "Keep the elbow behind the fist instead of letting it flare outward.",
                why: "A connected elbow supports a straighter punch and a tighter guard.",
                beginnerKey: "correction.elbow.beginner",
                athleteKey: "correction.elbow.athlete"
            )
        case .guardHand:
            return CatalogEntry(
                code: .guardHand,
                drill: .guardAnchor,
                cue: "Anchor the spare hand beside your cheek throughout the punch.",
                why: "The non-punching hand protects the opening created by the strike.",
                beginnerKey: "correction.guard.beginner",
                athleteKey: "correction.guard.athlete"
            )
        case .retraction:
            return CatalogEntry(
                code: .retraction,
                drill: .snapBack,
                cue: "Snap the fist straight back to guard before resetting.",
                why: "Fast retraction restores defense and prepares the next action.",
                beginnerKey: "correction.retraction.beginner",
                athleteKey: "correction.retraction.athlete"
            )
        }
    }

    nonisolated private static func metricOrder(_ kind: SubMetricKind) -> Int {
        SubMetricKind.allCases.firstIndex(of: kind) ?? .max
    }
}

nonisolated private struct CatalogEntry: Sendable {
    let code: CoachCorrectionCode
    let drill: CoachCorrectiveDrill
    let cue: String
    let why: String
    let beginnerKey: String
    let athleteKey: String
}
