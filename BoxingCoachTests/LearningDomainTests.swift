import Foundation
import Testing
@testable import BoxingCoach

@Suite("Learning domain contracts")
struct LearningDomainTests {
    @Test("Training tracks adapt instruction without changing scoring")
    func tracksShareScoringButAdaptInstruction() {
        let firstRound = TrainingTrack.firstRound
        let technicalCamp = TrainingTrack.technicalCamp

        #expect(firstRound.scoringPolicy == technicalCamp.scoringPolicy)
        #expect(firstRound.title != technicalCamp.title)
        #expect(firstRound.introCopy != technicalCamp.introCopy)
        #expect(firstRound.demonstrationRate < technicalCamp.demonstrationRate)
        #expect(firstRound.guidedRehearsalCount < technicalCamp.guidedRehearsalCount)
        #expect(firstRound.explanationDetail == .plainLanguage)
        #expect(technicalCamp.explanationDetail == .technical)
    }

    @Test("Learning stages retain the complete coaching progression")
    func learningStagesAreExhaustiveAndOrdered() {
        #expect(
            LearningStage.allCases == [
                .fit,
                .learnWatch,
                .learnOutbound,
                .learnLanding,
                .learnReturn,
                .guidedRehearsal,
                .baseline,
                .correction,
                .correctiveDrill,
                .retest,
                .proof,
                .transfer,
                .complete,
            ]
        )
    }

    @Test("Technique attempts reject nonfinite deterministic scores")
    func attemptEvidenceRejectsNonfiniteScore() throws {
        let punch = try makePunchEvidence()
        let score = makeScore(overall: .nan)

        #expect {
            try TechniqueAttemptEvidence(
                punch: punch,
                score: score,
                metricQuality: [.path: .measured]
            )
        } throws: { error in
            error as? LearningEvidenceRejectionReason == .nonFinite(field: "score.overall")
        }
    }

    @Test("Technique attempts preserve measured versus inferred metric provenance")
    func attemptEvidenceRetainsMetricProvenance() throws {
        let attempt = try makeAttempt(
            overall: 68,
            pathScore: 62,
            pathQuality: .inferred
        )

        #expect(attempt.technique == .jab)
        #expect(attempt.stance == .orthodox)
        #expect(attempt.side == .left)
        #expect(attempt.quality(for: .path) == .inferred)
    }

    @Test("Correction and proof compare the same technique with finite deltas")
    func correctionAndProofDescribeImprovement() throws {
        let baseline = try makeAttempt(overall: 68, pathScore: 62)
        let retest = try makeAttempt(overall: 81, pathScore: 79)
        let correction = try CorrectionPlan(
            technique: .jab,
            focus: .path,
            rationale: "The fist drifted outside the reference line.",
            cue: "Send the fist straight down the center lane.",
            rehearsalCount: 4,
            targetImprovement: 10
        )
        let proof = try ProofComparison(baseline: baseline, retest: retest)

        #expect(correction.focus == .path)
        #expect(proof.overallDelta == 13)
        #expect(proof.metricDelta(for: .path) == 17)
        requireDurableValueContract(correction)
    }

    @Test("A coaching cycle carries the completed learning proof")
    func coachingCycleCarriesCompletedProof() throws {
        let baseline = try makeAttempt(overall: 68, pathScore: 62)
        let retest = try makeAttempt(overall: 81, pathScore: 79)
        let correction = try CorrectionPlan(
            technique: .jab,
            focus: .path,
            rationale: "The fist drifted outside the reference line.",
            cue: "Send the fist straight down the center lane.",
            rehearsalCount: 4,
            targetImprovement: 10
        )
        let proof = try ProofComparison(baseline: baseline, retest: retest)
        let result = try CoachingCycleResult(
            track: .technicalCamp,
            technique: .jab,
            stance: .orthodox,
            completedStages: LearningStage.allCases,
            baseline: baseline,
            correction: correction,
            retest: retest,
            proof: proof,
            completedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(result.completedStages.last == .complete)
        #expect(result.proof.overallDelta == 13)
        #expect(result.track == .technicalCamp)
    }

    private func makeAttempt(
        overall: Float,
        pathScore: Float,
        pathQuality: MeasurementQuality = .measured
    ) throws -> TechniqueAttemptEvidence {
        try TechniqueAttemptEvidence(
            punch: makePunchEvidence(),
            score: makeScore(overall: overall, pathScore: pathScore),
            metricQuality: [.path: pathQuality]
        )
    }

    private func makePunchEvidence() throws -> ValidatedPunchEvidence {
        try ValidatedPunchEvidence(
            technique: .jab,
            stance: .orthodox,
            side: .left,
            generation: 11,
            startedAt: 60,
            landedAt: 60.2,
            returnedAt: 60.5,
            outboundTravel: 0.5,
            landingError: 0.03,
            returnError: 0.05,
            trackedFraction: 0.96,
            quality: .measured
        )
    }

    private func makeScore(
        overall: Float,
        pathScore: Float = 62
    ) -> TechniqueScore {
        TechniqueScore(
            techniqueID: Technique.jab.id,
            overall: overall,
            metrics: [
                SubMetric(
                    kind: .path,
                    score: pathScore,
                    measured: 0.14,
                    detail: "14% normalized path error"
                )
            ],
            trackedFraction: 0.96,
            duration: 0.5
        )
    }

    private func requireDurableValueContract<T: Codable & Hashable & Sendable>(_ value: T) {
        _ = value
    }
}
