import Foundation

nonisolated enum CoachingAttemptStage: String, Codable, Hashable, Sendable {
    case baseline
    case retest
}

nonisolated struct CoachingMetricSnapshot: Codable, Hashable, Sendable {
    let kind: SubMetricKind
    let score: Float?
    let measured: Float
    let detail: String
    let quality: MeasurementQuality
}

/// Reconstructable immutable facts for one of the six admitted punches in a coaching cycle.
nonisolated struct CoachingAttemptSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let cycleID: UUID
    let athleteID: UUID
    let eventID: UUID?
    let stage: CoachingAttemptStage
    let ordinal: Int
    let techniqueID: String
    let stance: Stance
    let side: BodySide
    let attemptVersion: UInt64
    let referenceVersion: UInt64
    let scoringVersion: UInt64
    let calibrationVersion: UInt64
    let providerGeneration: UInt64
    let punchStartedAt: TimeInterval
    let punchLandedAt: TimeInterval
    let punchReturnedAt: TimeInterval
    let outboundTravel: Float
    let landingError: Float
    let returnError: Float
    let overallScore: Float
    let metrics: [CoachingMetricSnapshot]
    let trackedFraction: Float
    let duration: TimeInterval
    let wrongHand: Bool
    let proofPeerAttemptID: UUID
    let correctionCode: String
    let selectedFocus: SubMetricKind
    let selectedMetricDelta: Float
    let proofDisposition: CoachingProofDisposition

    init(
        cycleID: UUID,
        athleteID: UUID,
        eventID: UUID?,
        stage: CoachingAttemptStage,
        ordinal: Int,
        evidence: CoachingAttemptEvidence,
        proofPeerAttemptID: UUID,
        result: CoachingCycleResult
    ) throws {
        let attempt = evidence.evidence
        guard (1...CoachingCycleSession.requiredAttempts).contains(ordinal),
              attempt.technique == result.technique,
              attempt.stance == result.stance,
              result.selectedProof.delta.isFinite
        else { throw LearningEvidenceRejectionReason.attemptIdentityMismatch }

        let metrics = try attempt.score.metrics.map { metric -> CoachingMetricSnapshot in
            guard metric.measured.isFinite,
                  metric.score.map(\.isFinite) ?? true,
                  let quality = attempt.quality(for: metric.kind)
            else {
                throw LearningEvidenceRejectionReason.missingMetricQuality(metric.kind)
            }
            return CoachingMetricSnapshot(
                kind: metric.kind,
                score: metric.score,
                measured: metric.measured,
                detail: metric.detail,
                quality: quality
            )
        }

        id = attempt.identity.id
        self.cycleID = cycleID
        self.athleteID = athleteID
        self.eventID = eventID
        self.stage = stage
        self.ordinal = ordinal
        techniqueID = attempt.technique.id
        stance = attempt.stance
        side = attempt.side
        attemptVersion = attempt.identity.version
        referenceVersion = attempt.identity.referenceVersion
        scoringVersion = attempt.identity.scoringVersion
        calibrationVersion = attempt.identity.calibrationVersion
        providerGeneration = attempt.punch.generation
        punchStartedAt = attempt.punch.startedAt
        punchLandedAt = attempt.punch.landedAt
        punchReturnedAt = attempt.punch.returnedAt
        outboundTravel = attempt.punch.outboundTravel
        landingError = attempt.punch.landingError
        returnError = attempt.punch.returnError
        overallScore = attempt.score.overall
        self.metrics = metrics
        trackedFraction = attempt.score.trackedFraction
        duration = attempt.score.duration
        wrongHand = attempt.score.wrongHand
        self.proofPeerAttemptID = proofPeerAttemptID
        correctionCode = result.selectedProof.correctionCode.rawValue
        selectedFocus = result.selectedProof.kind
        selectedMetricDelta = result.selectedProof.delta
        proofDisposition = result.proofDisposition
    }
}

/// One self-contained coaching result. The six detailed attempts and their like-for-like links
/// are encoded with the cycle so reopening the repository never depends on a lossy aggregate.
nonisolated struct CoachingCycleSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let athleteID: UUID
    let eventID: UUID?
    let trackID: String
    let techniqueID: String
    let stance: Stance
    let fittedReach: BilateralReach
    let attempts: [CoachingAttemptSnapshot]
    let baselineAttemptIDs: [UUID]
    let retestAttemptIDs: [UUID]
    let correctionCode: String
    let selectedFocus: SubMetricKind
    let selectedBaseline: Float
    let selectedRetest: Float
    let selectedDelta: Float
    let baselineOverall: Float
    let retestOverall: Float
    let overallDelta: Float
    let proofDisposition: CoachingProofDisposition
    let completedAt: Date

    init(
        result: CoachingCycleResult,
        athleteID: UUID,
        eventID: UUID?,
        fittedReach: BilateralReach
    ) throws {
        let baseline = result.proof.baseline.attempts
        let retest = result.proof.retest.attempts
        guard baseline.count == CoachingCycleSession.requiredAttempts,
              retest.count == CoachingCycleSession.requiredAttempts,
              result.proofDisposition != .retry,
              result.completedAt.timeIntervalSinceReferenceDate.isFinite
        else { throw LearningEvidenceRejectionReason.incompleteCycle }

        let baselineIDs = baseline.map(\.evidence.identity.id)
        let retestIDs = retest.map(\.evidence.identity.id)
        var snapshots: [CoachingAttemptSnapshot] = []
        for index in baseline.indices {
            snapshots.append(try CoachingAttemptSnapshot(
                cycleID: result.id,
                athleteID: athleteID,
                eventID: eventID,
                stage: .baseline,
                ordinal: index + 1,
                evidence: baseline[index],
                proofPeerAttemptID: retestIDs[index],
                result: result
            ))
        }
        for index in retest.indices {
            snapshots.append(try CoachingAttemptSnapshot(
                cycleID: result.id,
                athleteID: athleteID,
                eventID: eventID,
                stage: .retest,
                ordinal: index + 1,
                evidence: retest[index],
                proofPeerAttemptID: baselineIDs[index],
                result: result
            ))
        }

        id = result.id
        self.athleteID = athleteID
        self.eventID = eventID
        trackID = result.track.id
        techniqueID = result.technique.id
        stance = result.stance
        self.fittedReach = fittedReach
        attempts = snapshots
        baselineAttemptIDs = baselineIDs
        retestAttemptIDs = retestIDs
        correctionCode = result.selectedProof.correctionCode.rawValue
        selectedFocus = result.selectedProof.kind
        selectedBaseline = result.selectedProof.baseline
        selectedRetest = result.selectedProof.retest
        selectedDelta = result.selectedProof.delta
        baselineOverall = result.proof.baseline.score.overall
        retestOverall = result.proof.retest.score.overall
        overallDelta = result.proof.overallDelta
        proofDisposition = result.proofDisposition
        completedAt = result.completedAt
    }
}

/// All athlete-memory writes associated with cycle completion, committed once or not at all.
nonisolated struct CoachingCycleMemoryTransaction: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case player
        case legacyAttempts
        case skillMemory
        case cycle
    }

    let player: CompetitionPlayer
    let legacyAttempts: [TechniqueAttemptSnapshot]
    let skillMemory: AthleteSkillMemory
    let cycle: CoachingCycleSnapshot

    init(
        player: CompetitionPlayer,
        legacyAttempts: [TechniqueAttemptSnapshot],
        skillMemory: AthleteSkillMemory,
        cycle: CoachingCycleSnapshot
    ) throws {
        let cycleAttemptIDs = Set(cycle.attempts.map(\.id))
        let legacyAttemptIDs = Set(legacyAttempts.map(\.id))
        var memoryAttemptsByID: [UUID: TechniqueAttemptSnapshot] = [:]
        var memoryAttemptIDsAreUnique = true
        for attempt in skillMemory.attempts {
            if memoryAttemptsByID.updateValue(attempt, forKey: attempt.id) != nil {
                memoryAttemptIDsAreUnique = false
            }
        }
        guard player.id == cycle.athleteID,
              player.eventID == cycle.eventID,
              player.reach == cycle.fittedReach,
              player.rememberedStance == cycle.stance,
              skillMemory.athleteID == cycle.athleteID,
              skillMemory.techniqueID == cycle.techniqueID,
              skillMemory.key.eventID == cycle.eventID,
              skillMemory.key.stance == cycle.stance,
              memoryAttemptIDsAreUnique,
              cycleAttemptIDs.count == CoachingCycleSession.requiredAttempts * 2,
              legacyAttempts.count == CoachingCycleSession.requiredAttempts * 2,
              legacyAttemptIDs == cycleAttemptIDs,
              legacyAttempts.allSatisfy({ memoryAttemptsByID[$0.id] == $0 }),
              skillMemory.pastSelfTrace.map({ trace in
                  legacyAttemptIDs.contains(trace.attemptID)
                      && memoryAttemptsByID[trace.attemptID]?.pastSelfTrace == trace
              }) ?? true,
              cycle.attempts.allSatisfy({ $0.cycleID == cycle.id }),
              cycle.attempts.allSatisfy({ attempt in
                  cycle.attempts.contains { $0.id == attempt.proofPeerAttemptID }
              }),
              legacyAttempts.allSatisfy({ attempt in
                  attempt.athleteID == cycle.athleteID
                      && attempt.eventID == cycle.eventID
                      && attempt.coachingCycleID == cycle.id
                      && attempt.techniqueID == cycle.techniqueID
                      && attempt.stance == cycle.stance
                      && attempt.publicHandleSnapshot == player.publicHandle
                      && attempt.calibrationVersion == player.calibrationVersion
                      && attempt.isValid
              }),
              zip(cycle.attempts, legacyAttempts).allSatisfy({ detailed, legacy in
                  detailed.id == legacy.id
                      && detailed.stage.rawValue == legacy.stage.rawValue
                      && detailed.ordinal == legacy.cycleOrdinal
                      && detailed.overallScore == legacy.score
                      && detailed.scoringVersion == UInt64(legacy.scoringVersion)
                      && detailed.referenceVersion == UInt64(legacy.referenceVersion)
                      && detailed.calibrationVersion == UInt64(legacy.calibrationVersion ?? 0)
              })
        else { throw LearningEvidenceRejectionReason.incompleteCycle }
        self.player = player
        self.legacyAttempts = legacyAttempts
        self.skillMemory = skillMemory
        self.cycle = cycle
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            player: values.decode(CompetitionPlayer.self, forKey: .player),
            legacyAttempts: values.decode([TechniqueAttemptSnapshot].self, forKey: .legacyAttempts),
            skillMemory: values.decode(AthleteSkillMemory.self, forKey: .skillMemory),
            cycle: values.decode(CoachingCycleSnapshot.self, forKey: .cycle)
        )
    }
}
