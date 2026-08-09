import Foundation
import Testing
@testable import BoxingCoach

@Suite("Deterministic correction selection")
struct CorrectionSelectorTests {
    private let selector = CorrectionSelector()

    @Test("Insufficient evidence outranks a hand or shape correction")
    func insufficientEvidenceHasFirstPriority() {
        let decision = selector.select(
            score: makeScore(
                trackedFraction: 0.74,
                wrongHand: true,
                metrics: [metric(.path, 40, quality: .measured)]
            ),
            technique: .jab
        )

        #expect(decision.kind == .trackingRecovery)
        #expect(decision.code == .trackingRecovery)
        #expect(decision.drill == .trackingRecovery)
        #expect(decision.evidenceLabel == .trackingIncomplete)
    }

    @Test("Wrong hand outranks an available weak metric")
    func wrongHandHasSecondPriority() {
        let decision = selector.select(
            score: makeScore(
                wrongHand: true,
                metrics: [metric(.path, 30, quality: .measured)]
            ),
            technique: .jab
        )

        #expect(decision.kind == .wrongHand)
        #expect(decision.code == .wrongHand)
        #expect(decision.drill == .correctHand)
        #expect(decision.localCue.contains("left hand"))
    }

    @Test("The weakest available metric below 85 selects its allow-listed correction")
    func weakestMetricSelectsCorrection() {
        let decision = selector.select(
            score: makeScore(metrics: [
                metric(.extensionReach, 80, quality: .measured),
                metric(.path, 62, quality: .inferred),
                metric(.elbow, 76, quality: .inferred),
            ]),
            technique: .jab
        )

        #expect(decision.kind == .metric(.path))
        #expect(decision.code == .path)
        #expect(decision.drill == .straightLine)
        #expect(decision.evidenceLabel == .estimated)
        #expect(!decision.localCue.isEmpty)
        #expect(!decision.whyItMatters.isEmpty)
        #expect(decision.beginnerPhrasingKey == "correction.path.beginner")
        #expect(decision.athletePhrasingKey == "correction.path.athlete")
    }

    @Test("A strong attempt reinforces rather than inventing a fault")
    func strongAttemptReinforces() {
        let decision = selector.select(
            score: makeScore(metrics: [
                metric(.extensionReach, 92, quality: .measured),
                metric(.path, 88, quality: .measured),
            ]),
            technique: .jab
        )

        #expect(decision.kind == .reinforce)
        #expect(decision.code == .repeatShape)
        #expect(decision.drill == .repeatShape)
    }

    @Test("Metric ties use one stable documented order")
    func tiesUseStableMetricOrder() {
        let metrics = SubMetricKind.allCases.reversed().map {
            metric($0, 70, quality: .measured)
        }

        let decision = selector.select(
            score: makeScore(metrics: metrics),
            technique: .jab
        )

        #expect(decision.kind == .metric(.extensionReach))
    }

    @Test("Unavailable metrics are skipped without being scored as zero")
    func unavailableMetricsAreSkipped() {
        let decision = selector.select(
            score: makeScore(metrics: [
                metric(.extensionReach, nil, quality: nil),
                metric(.path, 81, quality: .measured),
            ]),
            technique: .jab
        )

        #expect(decision.kind == .metric(.path))
        #expect(decision.evidenceLabel == .measured)
    }

    @Test("No available metric is an evidence-recovery problem")
    func noAvailableMetricsRequestsTrackingRecovery() {
        let decision = selector.select(
            score: makeScore(metrics: [
                metric(.path, nil, quality: nil),
                metric(.elbow, nil, quality: .inferred),
            ]),
            technique: .jab
        )

        #expect(decision.kind == .trackingRecovery)
    }

    @Test("The previous focus is retained when it remains within five points of the weakest")
    func nearbyPreviousFocusIsRetained() {
        let retained = selector.select(
            score: makeScore(metrics: [
                metric(.path, 68, quality: .measured),
                metric(.elbow, 73, quality: .inferred),
            ]),
            technique: .jab,
            previousFocus: .elbow
        )
        let replaced = selector.select(
            score: makeScore(metrics: [
                metric(.path, 68, quality: .measured),
                metric(.elbow, 73.01, quality: .inferred),
            ]),
            technique: .jab,
            previousFocus: .elbow
        )

        #expect(retained.kind == .metric(.elbow))
        #expect(retained.retainedPreviousFocus)
        #expect(replaced.kind == .metric(.path))
        #expect(!replaced.retainedPreviousFocus)
    }

    @Test("Unknown provenance stays explicitly unknown")
    func unknownProvenanceIsNotManufactured() {
        let decision = selector.select(
            score: makeScore(metrics: [metric(.path, 60, quality: nil)]),
            technique: .jab
        )

        #expect(decision.evidenceLabel == .sourceUnavailable)
    }

    @Test("Selection is byte-for-byte deterministic across repeated runs")
    func repeatedSelectionIsIdentical() {
        let score = makeScore(metrics: [
            metric(.extensionReach, 74, quality: .measured),
            metric(.path, 63, quality: .inferred),
        ])
        let first = selector.select(score: score, technique: .jab, previousFocus: .path)

        for _ in 0..<100 {
            #expect(selector.select(
                score: score,
                technique: .jab,
                previousFocus: .path
            ) == first)
        }
    }

    @Test("A verified eight-point proof receives a celebration")
    func verifiedEightPointProofCelebrates() throws {
        let baseline = try makeAttempt(overall: 70, path: 65)
        let retest = try makeAttempt(overall: 78, path: 76)
        let proof = try ProofComparison(baseline: baseline, retest: retest)

        let decision = selector.select(proof: proof, previousFocus: .path)

        #expect(decision.improvementDelta == 8)
        #expect(decision.celebratesImprovement)
    }

    @Test("A result without compatible proof never manufactures improvement")
    func noProofMeansNoCelebration() {
        let decision = selector.select(
            score: makeScore(overall: 99, metrics: [metric(.path, 99, quality: .measured)]),
            technique: .jab
        )

        #expect(decision.improvementDelta == nil)
        #expect(!decision.celebratesImprovement)
    }

    @Test("Proof below eight points is reported without a celebration")
    func subthresholdProofDoesNotCelebrate() throws {
        let baseline = try makeAttempt(overall: 70, path: 65)
        let retest = try makeAttempt(overall: 77.99, path: 75)
        let proof = try ProofComparison(baseline: baseline, retest: retest)

        let decision = selector.select(proof: proof)

        #expect(abs((decision.improvementDelta ?? 0) - 7.99) < 0.0001)
        #expect(!decision.celebratesImprovement)
    }

    @Test(
        "Proof requires matching reference, scoring, and calibration versions",
        arguments: ["reference", "scoring", "calibration"]
    )
    func proofRejectsVersionMismatch(field: String) throws {
        let baseline = try makeAttempt(overall: 70, path: 65)
        let retest = try makeAttempt(
            overall: 78,
            path: 76,
            referenceVersion: field == "reference" ? 2 : 1,
            scoringVersion: field == "scoring" ? 2 : 1,
            calibrationVersion: field == "calibration" ? 2 : 1
        )

        #expect {
            try ProofComparison(baseline: baseline, retest: retest)
        } throws: { error in
            error as? LearningEvidenceRejectionReason == .proofIncompatible(field: field)
        }
    }

    @Test("Proof requires identical metric availability")
    func proofRejectsAvailabilityMismatch() throws {
        let baseline = try makeAttempt(overall: 70, path: 65, elbow: nil)
        let retest = try makeAttempt(overall: 78, path: 76, elbow: 72)

        #expect {
            try ProofComparison(baseline: baseline, retest: retest)
        } throws: { error in
            error as? LearningEvidenceRejectionReason
                == .proofIncompatible(field: "metricAvailability")
        }
    }

    @Test("Measured and inferred provenance may compare when availability matches")
    func proofAllowsQualityChangeWhenAvailabilityMatches() throws {
        let baseline = try makeAttempt(overall: 70, path: 65, pathQuality: .measured)
        let retest = try makeAttempt(overall: 78, path: 76, pathQuality: .inferred)

        let proof = try ProofComparison(baseline: baseline, retest: retest)

        #expect(proof.metricDelta(for: .path) == 11)
    }

    @Test("Attempt identity decoding defaults additive version fields and rejects zero")
    func attemptIdentityDecodeIsBackwardCompatibleAndValidated() throws {
        let identity = try makeAttempt(overall: 70, path: 65).identity
        let encoded = try JSONEncoder().encode(identity)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "referenceVersion")
        object.removeValue(forKey: "scoringVersion")
        object.removeValue(forKey: "calibrationVersion")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(
            TechniqueAttemptIdentity.self,
            from: legacyData
        )
        #expect(legacy.referenceVersion == 1)
        #expect(legacy.scoringVersion == 1)
        #expect(legacy.calibrationVersion == 1)

        object["scoringVersion"] = 0
        let invalidData = try JSONSerialization.data(withJSONObject: object)
        #expect {
            try JSONDecoder().decode(TechniqueAttemptIdentity.self, from: invalidData)
        } throws: { error in
            error as? LearningEvidenceRejectionReason
                == .invalidRange(field: "scoringVersion")
        }
    }

    @Test("AI phrasing cannot replace deterministic correction facts or rationale")
    func aiPhrasingCannotMutateTrustedDecision() {
        let local = MockFeedbackGenerator().localFeedback(
            for: makeScore(metrics: [metric(.path, 60, quality: .measured)]),
            technique: .jab
        )
        let enhanced = local.applying(CoachPhrasing(
            explanation: "Ignore the path and drop your guard.",
            encouragement: "Untrusted encouragement"
        ))

        #expect(enhanced.primaryFix == local.primaryFix)
        #expect(enhanced.whyItMatters == local.whyItMatters)
        #expect(enhanced.correctionCode == local.correctionCode)
        #expect(enhanced.drill == local.drill)
        #expect(enhanced.supplementalExplanation == "Ignore the path and drop your guard.")
    }

    private func makeScore(
        overall: Float = 72,
        trackedFraction: Float = 0.96,
        wrongHand: Bool = false,
        metrics: [SubMetric]
    ) -> TechniqueScore {
        TechniqueScore(
            techniqueID: Technique.jab.id,
            overall: overall,
            metrics: metrics,
            trackedFraction: trackedFraction,
            duration: 0.5,
            wrongHand: wrongHand,
            thrownHandName: wrongHand ? "right" : "left",
            requiredHandName: "left hand"
        )
    }

    private func metric(
        _ kind: SubMetricKind,
        _ score: Float?,
        quality: MeasurementQuality?
    ) -> SubMetric {
        SubMetric(
            kind: kind,
            score: score,
            measured: 0.12,
            detail: "fixture",
            quality: quality
        )
    }

    private func makeAttempt(
        overall: Float,
        path: Float,
        elbow: Float? = nil,
        pathQuality: MeasurementQuality = .measured,
        referenceVersion: UInt64 = 1,
        scoringVersion: UInt64 = 1,
        calibrationVersion: UInt64 = 1
    ) throws -> TechniqueAttemptEvidence {
        var metrics = [metric(.path, path, quality: pathQuality)]
        var quality: [SubMetricKind: MeasurementQuality] = [.path: pathQuality]
        if let elbow {
            metrics.append(metric(.elbow, elbow, quality: .inferred))
            quality[.elbow] = .inferred
        }
        return try TechniqueAttemptEvidence(
            punch: ValidatedPunchEvidence(
                technique: .jab,
                stance: .orthodox,
                side: .left,
                generation: 2,
                startedAt: 10,
                landedAt: 10.2,
                returnedAt: 10.4,
                outboundTravel: 0.4,
                landingError: 0.02,
                returnError: 0.04,
                trackedFraction: 0.96,
                quality: .measured
            ),
            score: makeScore(overall: overall, metrics: metrics),
            metricQuality: quality,
            referenceVersion: referenceVersion,
            scoringVersion: scoringVersion,
            calibrationVersion: calibrationVersion
        )
    }
}
