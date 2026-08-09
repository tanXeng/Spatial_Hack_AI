import Foundation
import simd

/// The four things a punch is graded on (guard is coached live, not scored).
///
/// Deliberately named and separated rather than collapsed into one number: "68/100" tells a
/// beginner nothing they can act on, whereas "your elbow flared" is a thing they can go fix on
/// the next rep. The split also gives the feedback LLM concrete facts to talk about instead of
/// inviting it to invent plausible-sounding technique notes.
/// `nonisolated` here and on the types below: these are plain data and arithmetic with no UI
/// affinity, and the project defaults types to `@MainActor`. Without it, the feedback generator —
/// which runs off the main actor to do network I/O — cannot read `grade` or `title`.
nonisolated enum SubMetricKind: String, CaseIterable, Sendable, Codable {
    case extensionReach = "extension"
    case path
    case elbow
    case guardHand = "guard"
    case retraction

    var title: String {
        switch self {
        case .extensionReach: return "Extension"
        case .path: return "Path"
        case .elbow: return "Elbow"
        case .guardHand: return "Guard"
        case .retraction: return "Retraction"
        }
    }

    /// What the number actually measures — shown in the UI and given to the LLM as grounding.
    var explanation: String {
        switch self {
        case .extensionReach: return "How close the punch came to full reach"
        case .path: return "How closely the fist followed the ideal line"
        case .elbow: return "Whether the elbow stayed tucked instead of flaring"
        case .guardHand: return "Whether the other hand stayed up at the chin"
        case .retraction: return "Whether the hand returned to guard afterward"
        }
    }

    /// The fault a low score on this metric represents.
    var faultDescription: String {
        switch self {
        case .extensionReach: return "the punch stopped short of full extension"
        case .path: return "the fist looped or drifted instead of travelling straight to the target"
        case .elbow: return "the elbow flared away from the body"
        case .guardHand: return "the non-punching hand dropped away from the chin"
        case .retraction: return "the hand did not come back to guard after the punch"
        }
    }

    var weight: Float {
        switch self {
        case .extensionReach: return 0.25
        case .path: return 0.25
        case .elbow: return 0.20
        case .guardHand: return 0.15
        case .retraction: return 0.15
        }
    }
}

/// A single graded aspect of the attempt.
nonisolated struct SubMetric: Sendable, Identifiable, Codable {
    var kind: SubMetricKind
    /// 0–100. `nil` when the underlying data was not tracked well enough to judge.
    var score: Float?
    /// The raw measured error, in arm-reach units. Kept so thresholds can be recalibrated
    /// against real attempts without re-recording anything.
    var measured: Float
    /// Short human-readable measurement, e.g. "82% of full reach".
    var detail: String
    /// Provenance of the displayed metric. `nil` means the value predates provenance capture;
    /// callers must label it unknown rather than guessing measured or inferred.
    var quality: MeasurementQuality? = nil

    var id: String { kind.rawValue }
    var isAvailable: Bool { score != nil }
}

nonisolated extension MeasurementQuality {
    /// Aggregates provenance without upgrading any contributing available metric.
    static func conservativeAggregation(
        _ qualities: [MeasurementQuality?]
    ) -> MeasurementQuality? {
        guard !qualities.isEmpty, !qualities.contains(where: { $0 == nil }) else {
            return nil
        }
        return qualities.contains(.inferred) ? .inferred : .measured
    }
}

/// The complete, deterministic grade for one attempt.
///
/// Everything here is computed from geometry. The LLM never touches these numbers — it only
/// explains them (see `FeedbackGenerator`).
nonisolated struct TechniqueScore: Sendable {
    var techniqueID: String
    var overall: Float
    var metrics: [SubMetric]
    /// Fraction of the attempt that came from real tracking rather than gap-filling.
    var trackedFraction: Float
    /// How long the punch took, start to finish.
    var duration: TimeInterval

    /// True when the punch was thrown with a hand this technique does not allow — a jab off the
    /// rear hand, say. Stored as plain values rather than as `BodySide`/`PunchHand` so the
    /// `nonisolated` feedback generator can read them without hopping to the main actor.
    var wrongHand: Bool = false
    /// The hand that actually threw, e.g. "right".
    var thrownHandName: String = ""
    /// What the technique asks for, e.g. "left hand" or "either hand".
    var requiredHandName: String = ""

    /// One sentence stating the hand fault, or `nil` when the right hand was used.
    var wrongHandNote: String? {
        guard wrongHand, !thrownHandName.isEmpty, !requiredHandName.isEmpty else { return nil }
        return "Thrown with the \(thrownHandName) hand, but this punch is the \(requiredHandName)."
    }

    var grade: String {
        switch overall {
        case 88...: return "Excellent"
        case 74..<88: return "Solid"
        case 58..<74: return "Developing"
        default: return "Needs work"
        }
    }

    /// The metric most worth coaching, which is what feedback should lead with.
    var weakest: SubMetric? {
        metrics
            .filter { $0.isAvailable }
            .min { ($0.score ?? 100) < ($1.score ?? 100) }
    }

    var strongest: SubMetric? {
        metrics
            .filter { $0.isAvailable }
            .max { ($0.score ?? 0) < ($1.score ?? 0) }
    }

    func metric(_ kind: SubMetricKind) -> SubMetric? {
        metrics.first { $0.kind == kind }
    }

    /// Combines multiple punch scores into one round grade (e.g. 3 target hits).
    static func averaging(_ scores: [TechniqueScore], techniqueID: String) -> TechniqueScore? {
        guard !scores.isEmpty else { return nil }

        let overall = scores.map(\.overall).reduce(0, +) / Float(scores.count)
        let trackedFraction = scores.map(\.trackedFraction).reduce(0, +) / Float(scores.count)
        let duration = scores.map(\.duration).reduce(0, +) / Double(scores.count)
        let wrongHand = scores.contains(where: \.wrongHand)

        var averagedMetrics: [SubMetric] = []
        for kind in SubMetricKind.allCases where kind != .guardHand {
            let contributors = scores.compactMap { score -> SubMetric? in
                guard let metric = score.metric(kind), metric.score != nil else { return nil }
                return metric
            }
            guard !contributors.isEmpty else { continue }
            let available = contributors.compactMap(\.score)
            let meanScore = available.reduce(0, +) / Float(available.count)
            let template = contributors.first
            let quality = MeasurementQuality.conservativeAggregation(
                contributors.map(\.quality)
            )
            averagedMetrics.append(
                SubMetric(
                    kind: kind,
                    score: meanScore,
                    measured: template?.measured ?? 0,
                    detail: "Avg of \(scores.count) punches",
                    quality: quality
                )
            )
        }

        averagedMetrics.sort { a, b in
            let order = SubMetricKind.allCases
            return (order.firstIndex(of: a.kind) ?? 0) < (order.firstIndex(of: b.kind) ?? 0)
        }

        let first = scores[0]
        return TechniqueScore(
            techniqueID: techniqueID,
            overall: overall,
            metrics: averagedMetrics,
            trackedFraction: trackedFraction,
            duration: duration,
            wrongHand: wrongHand,
            thrownHandName: first.thrownHandName,
            requiredHandName: first.requiredHandName
        )
    }
}

/// Error tolerances, in arm-reach units, for each sub-metric.
///
/// `good` is the error at which the user still scores 100; `bad` is where they score 0, with a
/// straight line between. Linear rather than exponential on purpose — when a score looks wrong
/// during calibration, a linear ramp can be reasoned about from the raw `measured` value without
/// running anything.
///
/// ⚠️ These are hand-tuned from the geometry, **not** calibrated against real attempts yet
/// They are provisional and should be adjusted once real punches have been recorded.
nonisolated struct ScoringThresholds: Sendable {
    var extensionGood: Float = 0.06
    var extensionBad: Float = 0.34

    var pathGood: Float = 0.11
    var pathBad: Float = 0.46

    var elbowGood: Float = 0.09
    var elbowBad: Float = 0.36

    var guardGood: Float = 0.13
    var guardBad: Float = 0.46

    var retractionGood: Float = 0.13
    var retractionBad: Float = 0.50

    /// Multiplier applied to the overall score when the punch was thrown with the wrong hand.
    ///
    /// The sub-metrics are deliberately left alone: a well-shaped cross thrown off the lead hand
    /// is a hand-selection error, not a technique collapse, and zeroing the geometry would hide
    /// the fact that the movement itself was fine. The penalty lands on the overall number so the
    /// results page can name the actual mistake.
    var wrongHandMultiplier: Float = 0.6

    static let `default` = ScoringThresholds()
}

/// Turns a recorded attempt plus a reference punch into a `TechniqueScore`.
nonisolated struct TechniqueScorer: Sendable {
    var thresholds: ScoringThresholds = .default

    /// Returns `nil` when the capture was too poor to grade honestly.
    ///
    /// `thrownSide` is the hand the user actually punched with, which is not always the one the
    /// technique asks for — see `wrongHandMultiplier`.
    func score(
        attempt: RecordedAttempt,
        reference: ReferencePunch,
        technique: Technique,
        thrownSide: BodySide,
        stance: Stance
    ) -> TechniqueScore? {
        guard attempt.isUsable, !reference.samples.isEmpty else { return nil }

        let useOutboundPath = attempt.endsNearExtension()
        let pathReferenceSamples = useOutboundPath ? reference.outboundSamples : reference.samples
        guard pathReferenceSamples.count > 1 else { return nil }

        let referenceFists = pathReferenceSamples.map(\.fist)
        let attemptFists = attempt.samples.map(\.fist)

        guard let alignment = DTWComparator.align(
            reference: referenceFists,
            attempt: attemptFists
        ) else { return nil }

        var metrics: [SubMetric] = [
            extensionMetric(attempt: attempt, reference: reference),
            pathMetric(alignment: alignment),
            elbowMetric(
                attempt: attempt,
                referenceSamples: pathReferenceSamples,
                alignment: alignment
            ),
            retractionMetric(attempt: attempt, reference: reference)
        ]

        // Keep a stable display order regardless of how the metrics were built.
        metrics.sort { a, b in
            let order = SubMetricKind.allCases
            return (order.firstIndex(of: a.kind) ?? 0) < (order.firstIndex(of: b.kind) ?? 0)
        }

        let wrongHand = !technique.hand.allows(thrownSide, stance: stance)
        let shapeScore = weightedOverall(metrics)

        return TechniqueScore(
            techniqueID: technique.id,
            overall: wrongHand ? shapeScore * thresholds.wrongHandMultiplier : shapeScore,
            metrics: metrics,
            trackedFraction: attempt.trackedFraction,
            duration: attempt.duration,
            wrongHand: wrongHand,
            thrownHandName: thrownSide.rawValue,
            requiredHandName: technique.hand.requirementDescription(for: stance)
        )
    }

    // MARK: - Individual metrics

    /// Did the punch reach full extension?
    ///
    /// Only *under*-extension is penalized. A user who reaches slightly past the reference is not
    /// making a mistake — reference reach is an estimate from average proportions, and punishing
    /// someone for exceeding it would mostly be punishing them for having longer arms than
    /// `BodyMeasurements.averageAdult` assumes.
    private func extensionMetric(attempt: RecordedAttempt, reference: ReferencePunch) -> SubMetric {
        let referencePeak = reference.extensionMagnitude
        let attemptPeak = attempt.extensionMagnitude(for: reference.techniqueID)
        let shortfall = max(0, referencePeak - attemptPeak)

        let percent = referencePeak > 0 ? Int((attemptPeak / referencePeak * 100).rounded()) : 0

        return SubMetric(
            kind: .extensionReach,
            score: falloff(shortfall, good: thresholds.extensionGood, bad: thresholds.extensionBad),
            measured: shortfall,
            detail: "\(min(percent, 120))% of reference reach",
            quality: .inferred
        )
    }

    /// Did the fist follow the right line?
    private func pathMetric(alignment: DTWAlignment) -> SubMetric {
        SubMetric(
            kind: .path,
            score: falloff(
                alignment.normalizedDistance,
                good: thresholds.pathGood,
                bad: thresholds.pathBad
            ),
            measured: alignment.normalizedDistance,
            detail: String(format: "%.2f avg deviation", alignment.normalizedDistance),
            quality: .measured
        )
    }

    /// Did the elbow stay tucked?
    private func elbowMetric(
        attempt: RecordedAttempt,
        referenceSamples: [MotionSample],
        alignment: DTWAlignment
    ) -> SubMetric {
        let deviation = DTWComparator.meanDistance(
            reference: referenceSamples.map(\.elbow),
            attempt: attempt.samples.map(\.elbow),
            along: alignment
        ) ?? 0

        return SubMetric(
            kind: .elbow,
            score: falloff(deviation, good: thresholds.elbowGood, bad: thresholds.elbowBad),
            measured: deviation,
            detail: String(format: "%.2f avg deviation", deviation),
            quality: .inferred
        )
    }

    /// Did the other hand stay up?
    ///
    /// Scores `nil` rather than 0 when the guard hand was not tracked. A hand resting at the hip
    /// and a hand outside the camera's view produce the same absence of data, and marking the
    /// second case as a dropped guard would be inventing a fault.
    private func guardMetric(
        attempt: RecordedAttempt,
        reference: ReferencePunch,
        alignment: DTWAlignment
    ) -> SubMetric {
        let attemptGuards = attempt.samples.map(\.guardHand)
        let trackedCount = attemptGuards.compactMap { $0 }.count

        guard trackedCount >= attemptGuards.count / 2, trackedCount > 0 else {
            return SubMetric(
                kind: .guardHand,
                score: nil,
                measured: 0,
                detail: "Guard hand not tracked",
                quality: nil
            )
        }

        var total: Float = 0
        var count = 0
        for pair in alignment.pairs {
            guard pair.reference < reference.samples.count,
                  pair.attempt < attempt.samples.count,
                  let referenceGuard = reference.samples[pair.reference].guardHand,
                  let attemptGuard = attempt.samples[pair.attempt].guardHand
            else { continue }
            total += simd_distance(referenceGuard, attemptGuard)
            count += 1
        }

        guard count > 0 else {
            return SubMetric(
                kind: .guardHand,
                score: nil,
                measured: 0,
                detail: "Guard hand not tracked",
                quality: nil
            )
        }

        let deviation = total / Float(count)
        return SubMetric(
            kind: .guardHand,
            score: falloff(deviation, good: thresholds.guardGood, bad: thresholds.guardBad),
            measured: deviation,
            detail: String(format: "%.2f from guard position", deviation),
            quality: .measured
        )
    }

    /// Did the hand come back?
    private func retractionMetric(attempt: RecordedAttempt, reference: ReferencePunch) -> SubMetric {
        guard let selection = PunchRetractionSemantics.selection(
            attempt: attempt.samples,
            reference: reference.samples
        )
        else {
            return SubMetric(
                kind: .retraction,
                score: nil,
                measured: 0,
                detail: "No data",
                quality: nil
            )
        }

        if attempt.endsNearExtension() {
            return SubMetric(
                kind: .retraction,
                score: nil,
                measured: 0,
                detail: "Retraction not captured",
                quality: nil
            )
        }

        return SubMetric(
            kind: .retraction,
            score: falloff(
                selection.error,
                good: thresholds.retractionGood,
                bad: thresholds.retractionBad
            ),
            measured: selection.error,
            detail: String(format: "%.2f from guard at finish", selection.error),
            quality: .measured
        )
    }

    // MARK: - Aggregation

    /// Weighted mean over the metrics that could actually be measured.
    ///
    /// Unavailable metrics are excluded and the remaining weights renormalized, so a user whose
    /// guard hand left the camera's view is not silently penalized for a tracking limitation.
    private func weightedOverall(_ metrics: [SubMetric]) -> Float {
        var total: Float = 0
        var weightSum: Float = 0

        for metric in metrics {
            guard let score = metric.score else { continue }
            total += score * metric.kind.weight
            weightSum += metric.kind.weight
        }

        guard weightSum > 0 else { return 0 }
        return total / weightSum
    }

    /// 100 at `good` or better, 0 at `bad` or worse, linear between.
    private func falloff(_ error: Float, good: Float, bad: Float) -> Float {
        guard bad > good else { return error <= good ? 100 : 0 }
        if error <= good { return 100 }
        if error >= bad { return 0 }
        return 100 * (1 - (error - good) / (bad - good))
    }
}
