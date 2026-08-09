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
        let attemptID = UUID()
        let attempt = try makeAttempt(
            overall: 68,
            pathScore: 62,
            pathQuality: .inferred,
            attemptID: attemptID,
            version: 2
        )

        #expect(attempt.technique == .jab)
        #expect(attempt.stance == .orthodox)
        #expect(attempt.side == .left)
        #expect(attempt.quality(for: .path) == .inferred)
        #expect(attempt.identity.id == attemptID)
        #expect(attempt.identity.version == 2)
        #expect(attempt.identity.techniqueID == Technique.jab.id)
        #expect(attempt.identity.stance == .orthodox)
        #expect(attempt.identity.side == .left)
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

    @Test("Decoded correction plans re-enter validated admission")
    func decodedCorrectionPlanCannotBypassValidation() throws {
        let correction = try CorrectionPlan(
            technique: .jab,
            focus: .path,
            rationale: "The fist drifted outside the reference line.",
            cue: "Send the fist straight down the center lane.",
            rehearsalCount: 4,
            targetImprovement: 10
        )
        let invalidData = try replacingJSONValue(
            in: JSONEncoder().encode(correction),
            key: "rehearsalCount",
            with: 0
        )

        #expect {
            try JSONDecoder().decode(CorrectionPlan.self, from: invalidData)
        } throws: { error in
            error as? LearningEvidenceRejectionReason == .invalidRange(field: "rehearsalCount")
        }
    }

    @Test("A coaching cycle carries the completed learning proof")
    func coachingCycleCarriesCompletedProof() throws {
        let baseline = try makeRound(overall: 68, pathScore: 62)
        let retest = try makeRound(overall: 81, pathScore: 79)
        let correction = try CorrectionPlan(
            technique: .jab,
            focus: .path,
            rationale: "The fist drifted outside the reference line.",
            cue: "Send the fist straight down the center lane.",
            rehearsalCount: 4,
            targetImprovement: 10
        )
        let proof = try CoachingRoundProof(baseline: baseline, retest: retest)
        let selectedProof = CoachingProofMetric(
            kind: .path,
            baseline: 62,
            retest: 79,
            delta: 17,
            trackedFraction: 0.96,
            correctionCode: .path,
            evidenceLabel: .measured,
            sourceBadge: "Measured locally · Offline coach"
        )
        let result = try CoachingCycleResult(
            id: UUID(),
            track: .technicalCamp,
            technique: .jab,
            stance: .orthodox,
            completedStages: LearningStage.allCases,
            correction: correction,
            proof: proof,
            selectedProof: selectedProof,
            proofDisposition: .improved,
            completedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(result.completedStages.last == .complete)
        #expect(result.proof.overallDelta == 13)
        #expect(result.track == .technicalCamp)
    }

    @Test("A coaching cycle rejects a selected proof that contradicts its round aggregate")
    func coachingCycleBindsProofToItsExactAttempts() throws {
        let baseline = try makeRound(overall: 68, pathScore: 62)
        let retest = try makeRound(overall: 81, pathScore: 79)
        let correction = try CorrectionPlan(
            technique: .jab,
            focus: .path,
            rationale: "The fist drifted outside the reference line.",
            cue: "Send the fist straight down the center lane.",
            rehearsalCount: 4,
            targetImprovement: 10
        )
        let proof = try CoachingRoundProof(baseline: baseline, retest: retest)
        let contradictorySelection = CoachingProofMetric(
            kind: .path,
            baseline: 60,
            retest: 79,
            delta: 19,
            trackedFraction: 0.96,
            correctionCode: .path,
            evidenceLabel: .measured,
            sourceBadge: "Measured locally · Offline coach"
        )

        #expect {
            try CoachingCycleResult(
                id: UUID(),
                track: .technicalCamp,
                technique: .jab,
                stance: .orthodox,
                completedStages: LearningStage.allCases,
                correction: correction,
                proof: proof,
                selectedProof: contradictorySelection,
                proofDisposition: .improved,
                completedAt: Date(timeIntervalSince1970: 100)
            )
        } throws: { error in
            error as? LearningEvidenceRejectionReason == .attemptIdentityMismatch
        }
    }

    private func makeAttempt(
        overall: Float,
        pathScore: Float,
        pathQuality: MeasurementQuality = .measured,
        attemptID: UUID = UUID(),
        version: UInt64 = 1
    ) throws -> TechniqueAttemptEvidence {
        try TechniqueAttemptEvidence(
            punch: makePunchEvidence(),
            score: makeScore(overall: overall, pathScore: pathScore),
            metricQuality: [.path: pathQuality],
            attemptID: attemptID,
            version: version
        )
    }

    private func makeRound(
        overall: Float,
        pathScore: Float
    ) throws -> CoachingRoundEvidence {
        let samples = [
            MotionSample(
                time: 0,
                fist: SIMD3(0, 0, 0.2),
                elbow: SIMD3(0, 0, 0.1),
                guardHand: SIMD3(0, 0.2, 0.1),
                isTracked: true
            ),
            MotionSample(
                time: 0.2,
                fist: SIMD3(0, 0, 0.9),
                elbow: SIMD3(0, 0, 0.5),
                guardHand: SIMD3(0, 0.2, 0.1),
                isTracked: true
            ),
        ]
        let attempts = try (0..<CoachingCycleSession.requiredAttempts).map { _ in
            try CoachingAttemptEvidence(
                evidence: makeAttempt(overall: overall, pathScore: pathScore),
                actualSamples: samples,
                referenceSamples: samples
            )
        }
        return try CoachingRoundEvidence(attempts: attempts, technique: .jab)
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

    private func replacingJSONValue(
        in data: Data,
        key: String,
        with value: Int
    ) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }
}
