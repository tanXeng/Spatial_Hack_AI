import Foundation
import simd

nonisolated enum ExperienceLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case beginner
    case intermediate
    case advanced
}

nonisolated enum EventEditionStatus: String, Codable, Hashable, Sendable {
    case open
    case closed
}

nonisolated struct EventEdition: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let title: String
    let status: EventEditionStatus
    let openedAt: Date
    let closedAt: Date?
    let scoringVersion: Int
    let calibrationVersion: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case openedAt
        case closedAt
        case scoringVersion
        case calibrationVersion
    }

    init?(
        id: UUID,
        title: String,
        status: EventEditionStatus,
        openedAt: Date,
        closedAt: Date?,
        scoringVersion: Int,
        calibrationVersion: Int
    ) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              openedAt.timeIntervalSinceReferenceDate.isFinite,
              scoringVersion > 0,
              calibrationVersion > 0
        else { return nil }

        switch (status, closedAt) {
        case (.open, nil):
            break
        case let (.closed, closedAt?)
            where closedAt.timeIntervalSinceReferenceDate.isFinite && closedAt >= openedAt:
            break
        default:
            return nil
        }

        self.id = id
        self.title = normalizedTitle
        self.status = status
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.scoringVersion = scoringVersion
        self.calibrationVersion = calibrationVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let title = try container.decode(String.self, forKey: .title)
        let status = try container.decode(EventEditionStatus.self, forKey: .status)
        let openedAt = try container.decode(Date.self, forKey: .openedAt)
        let closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
        let scoringVersion = try container.decode(Int.self, forKey: .scoringVersion)
        let calibrationVersion = try container.decode(Int.self, forKey: .calibrationVersion)

        guard let validated = EventEdition(
            id: id,
            title: title,
            status: status,
            openedAt: openedAt,
            closedAt: closedAt,
            scoringVersion: scoringVersion,
            calibrationVersion: calibrationVersion
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "Event edition fields do not form a valid open or closed edition."
            )
        }
        self = validated
    }

    var isOpen: Bool { status == .open }

    func closing(at date: Date) -> EventEdition? {
        guard isOpen, date >= openedAt else { return nil }
        return EventEdition(
            id: id,
            title: title,
            status: .closed,
            openedAt: openedAt,
            closedAt: date,
            scoringVersion: scoringVersion,
            calibrationVersion: calibrationVersion
        )
    }
}

nonisolated struct ParticipantPublicHandle: Codable, Hashable, Sendable {
    let eventID: UUID
    let displayName: String
    /// Public, display-only, non-authenticating disambiguator; it is not a secret or credential.
    /// Security invariant: never use this value for authentication, authorization, recovery, or as a PIN.
    let displayCode: String

    var displayValue: String { "\(displayName) #\(displayCode)" }

    private enum CodingKeys: String, CodingKey {
        case eventID
        case displayName
        case displayCode
    }

    private init(eventID: UUID, displayName: String, displayCode: String) {
        self.eventID = eventID
        self.displayName = displayName
        self.displayCode = displayCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let eventID = try container.decode(UUID.self, forKey: .eventID)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let displayCode = try container.decode(String.self, forKey: .displayCode)
        guard let validated = Self.reserving(
            eventID: eventID,
            displayName: displayName,
            displayCode: displayCode,
            against: []
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .displayCode,
                in: container,
                debugDescription: "Participant display code must contain exactly four ASCII digits."
            )
        }
        self = validated
    }

    static func reserving(
        eventID: UUID,
        displayName: String,
        displayCode: String,
        against existing: [ParticipantPublicHandle]
    ) -> ParticipantPublicHandle? {
        guard isFourDigitDisplayCode(displayCode),
              !existing.contains(where: { $0.eventID == eventID && $0.displayCode == displayCode }),
              let validatedName = try? CompetitionName.display(displayName)
        else { return nil }

        return ParticipantPublicHandle(
            eventID: eventID,
            displayName: validatedName,
            displayCode: displayCode
        )
    }

    static func allocating(
        eventID: UUID,
        displayName: String,
        against existing: [ParticipantPublicHandle]
    ) -> ParticipantPublicHandle? {
        let reserved = Set(existing.lazy.filter { $0.eventID == eventID }.map(\.displayCode))
        guard reserved.count < 10_000 else { return nil }

        for candidate in 0..<10_000 {
            let displayCode = String(format: "%04d", candidate)
            guard !reserved.contains(displayCode) else { continue }
            return reserving(
                eventID: eventID,
                displayName: displayName,
                displayCode: displayCode,
                against: existing
            )
        }
        return nil
    }

    private static func isFourDigitDisplayCode(_ value: String) -> Bool {
        value.utf8.count == 4 && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}

nonisolated enum TechniqueAttemptStage: String, Codable, Hashable, Sendable {
    case practice
    case baseline
    case retest
}

nonisolated enum TechniqueMetricProvenance: String, Codable, Hashable, Sendable {
    case measured
    case inferred
    case unavailable
}

nonisolated struct TechniqueMetricSnapshot: Codable, Hashable, Sendable {
    let kind: String
    let score: Float?
    let provenance: TechniqueMetricProvenance

    private enum CodingKeys: String, CodingKey {
        case kind
        case score
        case provenance
    }

    init?(kind: String, score: Float?, provenance: TechniqueMetricProvenance) {
        let kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty, kind.utf8.count <= 64 else { return nil }
        switch (provenance, score) {
        case (.unavailable, nil):
            break
        case (.measured, let score?), (.inferred, let score?):
            guard score.isFinite, (0...100).contains(score) else { return nil }
        default:
            return nil
        }
        self.kind = kind
        self.score = score
        self.provenance = provenance
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let validated = TechniqueMetricSnapshot(
            kind: try values.decode(String.self, forKey: .kind),
            score: try values.decodeIfPresent(Float.self, forKey: .score),
            provenance: try values.decode(TechniqueMetricProvenance.self, forKey: .provenance)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .score,
                in: values,
                debugDescription: "Available metrics require a finite score; unavailable metrics cannot carry one."
            )
        }
        self = validated
    }
}

nonisolated struct AthleteSkillMemoryKey: Codable, Hashable, Sendable {
    let eventID: UUID?
    let athleteID: UUID
    let techniqueID: String
    let stance: Stance
    let referenceVersion: Int
    let scoringVersion: Int
    let calibrationVersion: Int?

    private enum CodingKeys: String, CodingKey {
        case eventID
        case athleteID
        case techniqueID
        case stance
        case referenceVersion
        case scoringVersion
        case calibrationVersion
    }

    init?(
        eventID: UUID?,
        athleteID: UUID,
        techniqueID: String,
        stance: Stance,
        referenceVersion: Int,
        scoringVersion: Int,
        calibrationVersion: Int?
    ) {
        let techniqueID = techniqueID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !techniqueID.isEmpty,
              referenceVersion > 0,
              scoringVersion > 0,
              calibrationVersion.map({ $0 > 0 }) ?? true
        else { return nil }
        self.eventID = eventID
        self.athleteID = athleteID
        self.techniqueID = techniqueID
        self.stance = stance
        self.referenceVersion = referenceVersion
        self.scoringVersion = scoringVersion
        self.calibrationVersion = calibrationVersion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let validated = AthleteSkillMemoryKey(
            eventID: try values.decodeIfPresent(UUID.self, forKey: .eventID),
            athleteID: try values.decode(UUID.self, forKey: .athleteID),
            techniqueID: try values.decode(String.self, forKey: .techniqueID),
            stance: try values.decode(Stance.self, forKey: .stance),
            referenceVersion: try values.decode(Int.self, forKey: .referenceVersion),
            scoringVersion: try values.decode(Int.self, forKey: .scoringVersion),
            calibrationVersion: try values.decodeIfPresent(Int.self, forKey: .calibrationVersion)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .referenceVersion,
                in: values,
                debugDescription: "Skill-memory keys require a technique and positive evidence versions."
            )
        }
        self = validated
    }

    var storageKey: String {
        let event = eventID?.uuidString.lowercased() ?? "none"
        let calibration = calibrationVersion.map(String.init) ?? "none"
        return [
            event,
            athleteID.uuidString.lowercased(),
            "\(techniqueID.utf8.count):\(techniqueID)",
            stance.rawValue,
            String(referenceVersion),
            String(scoringVersion),
            calibration
        ].joined(separator: "|")
    }
}

nonisolated struct TechniqueAttemptSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let athleteID: UUID
    let eventID: UUID?
    let coachingCycleID: UUID?
    let stage: TechniqueAttemptStage
    let cycleOrdinal: Int?
    let techniqueID: String
    let stance: Stance
    let score: Float
    let metrics: [TechniqueMetricSnapshot]
    let trackedFraction: Float
    let duration: TimeInterval
    let isValid: Bool
    let wrongHand: Bool
    let scoringVersion: Int
    let referenceVersion: Int
    let calibrationVersion: Int?
    let correctionCode: String?
    let baselineAttemptID: UUID?
    let startedAt: Date
    let completedAt: Date
    let pastSelfTrace: PastSelfTrace?
    let publicHandleSnapshot: ParticipantPublicHandle?

    private enum CodingKeys: String, CodingKey {
        case id
        case athleteID
        case eventID
        case coachingCycleID
        case stage
        case cycleOrdinal
        case techniqueID
        case stance
        case score
        case metrics
        case trackedFraction
        case duration
        case isValid
        case wrongHand
        case scoringVersion
        case referenceVersion
        case calibrationVersion
        case correctionCode
        case baselineAttemptID
        case startedAt
        case completedAt
        case pastSelfTrace
        case publicHandleSnapshot
    }

    init?(
        id: UUID,
        athleteID: UUID,
        eventID: UUID?,
        coachingCycleID: UUID?,
        stage: TechniqueAttemptStage,
        cycleOrdinal: Int? = nil,
        techniqueID: String,
        stance: Stance,
        score: Float,
        metrics: [TechniqueMetricSnapshot],
        trackedFraction: Float,
        duration: TimeInterval,
        isValid: Bool,
        wrongHand: Bool,
        scoringVersion: Int,
        referenceVersion: Int,
        calibrationVersion: Int?,
        correctionCode: String?,
        baselineAttemptID: UUID?,
        startedAt: Date,
        completedAt: Date,
        pastSelfTrace: PastSelfTrace?,
        publicHandleSnapshot: ParticipantPublicHandle?
    ) {
        let techniqueID = techniqueID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCorrection = correctionCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let interval = completedAt.timeIntervalSince(startedAt)
        let metricKinds = metrics.map(\.kind)
        guard !techniqueID.isEmpty,
              score.isFinite,
              (0...100).contains(score),
              trackedFraction.isFinite,
              (0...1).contains(trackedFraction),
              duration.isFinite,
              duration >= 0,
              interval.isFinite,
              interval >= 0,
              duration <= interval,
              !isValid || !wrongHand,
              Set(metricKinds).count == metricKinds.count,
              scoringVersion > 0,
              referenceVersion > 0,
              calibrationVersion.map({ $0 > 0 }) ?? true,
              startedAt.timeIntervalSinceReferenceDate.isFinite,
              completedAt.timeIntervalSinceReferenceDate.isFinite,
              normalizedCorrection.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true,
              pastSelfTrace.map({ $0.attemptID == id }) ?? true,
              publicHandleSnapshot.map({ $0.eventID == eventID }) ?? true,
              cycleOrdinal.map({
                  (1...CoachingCycleSession.requiredAttempts).contains($0)
              }) ?? true
        else { return nil }

        switch stage {
        case .practice:
            guard baselineAttemptID == nil else { return nil }
        case .baseline:
            guard coachingCycleID != nil, baselineAttemptID == nil else { return nil }
        case .retest:
            guard coachingCycleID != nil,
                  let baselineAttemptID,
                  baselineAttemptID != id
            else { return nil }
        }

        self.id = id
        self.athleteID = athleteID
        self.eventID = eventID
        self.coachingCycleID = coachingCycleID
        self.stage = stage
        self.cycleOrdinal = cycleOrdinal
        self.techniqueID = techniqueID
        self.stance = stance
        self.score = score
        self.metrics = metrics.sorted { $0.kind < $1.kind }
        self.trackedFraction = trackedFraction
        self.duration = duration
        self.isValid = isValid
        self.wrongHand = wrongHand
        self.scoringVersion = scoringVersion
        self.referenceVersion = referenceVersion
        self.calibrationVersion = calibrationVersion
        self.correctionCode = normalizedCorrection
        self.baselineAttemptID = baselineAttemptID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.pastSelfTrace = pastSelfTrace
        self.publicHandleSnapshot = publicHandleSnapshot
    }

    init?(
        id: UUID,
        athleteID: UUID,
        eventID: UUID?,
        techniqueID: String,
        score: Float,
        scoringVersion: Int,
        calibrationVersion: Int?,
        startedAt: Date,
        completedAt: Date,
        publicHandleSnapshot: ParticipantPublicHandle?
    ) {
        self.init(
            id: id,
            athleteID: athleteID,
            eventID: eventID,
            coachingCycleID: nil,
            stage: .practice,
            cycleOrdinal: nil,
            techniqueID: techniqueID,
            stance: .orthodox,
            score: score,
            metrics: [],
            trackedFraction: 1,
            duration: completedAt.timeIntervalSince(startedAt),
            isValid: true,
            wrongHand: false,
            scoringVersion: scoringVersion,
            referenceVersion: 1,
            calibrationVersion: calibrationVersion,
            correctionCode: nil,
            baselineAttemptID: nil,
            startedAt: startedAt,
            completedAt: completedAt,
            pastSelfTrace: nil,
            publicHandleSnapshot: publicHandleSnapshot
        )
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let startedAt = try values.decode(Date.self, forKey: .startedAt)
        let completedAt = try values.decode(Date.self, forKey: .completedAt)
        guard let validated = TechniqueAttemptSnapshot(
            id: try values.decode(UUID.self, forKey: .id),
            athleteID: try values.decode(UUID.self, forKey: .athleteID),
            eventID: try values.decodeIfPresent(UUID.self, forKey: .eventID),
            coachingCycleID: try values.decodeIfPresent(UUID.self, forKey: .coachingCycleID),
            stage: try values.decodeIfPresent(TechniqueAttemptStage.self, forKey: .stage) ?? .practice,
            cycleOrdinal: try values.decodeIfPresent(Int.self, forKey: .cycleOrdinal),
            techniqueID: try values.decode(String.self, forKey: .techniqueID),
            stance: try values.decodeIfPresent(Stance.self, forKey: .stance) ?? .orthodox,
            score: try values.decode(Float.self, forKey: .score),
            metrics: try values.decodeIfPresent([TechniqueMetricSnapshot].self, forKey: .metrics) ?? [],
            trackedFraction: try values.decodeIfPresent(Float.self, forKey: .trackedFraction) ?? 1,
            duration: try values.decodeIfPresent(TimeInterval.self, forKey: .duration)
                ?? completedAt.timeIntervalSince(startedAt),
            isValid: try values.decodeIfPresent(Bool.self, forKey: .isValid) ?? true,
            wrongHand: try values.decodeIfPresent(Bool.self, forKey: .wrongHand) ?? false,
            scoringVersion: try values.decode(Int.self, forKey: .scoringVersion),
            referenceVersion: try values.decodeIfPresent(Int.self, forKey: .referenceVersion) ?? 1,
            calibrationVersion: try values.decodeIfPresent(Int.self, forKey: .calibrationVersion),
            correctionCode: try values.decodeIfPresent(String.self, forKey: .correctionCode),
            baselineAttemptID: try values.decodeIfPresent(UUID.self, forKey: .baselineAttemptID),
            startedAt: startedAt,
            completedAt: completedAt,
            pastSelfTrace: try values.decodeIfPresent(PastSelfTrace.self, forKey: .pastSelfTrace),
            publicHandleSnapshot: try values.decodeIfPresent(
                ParticipantPublicHandle.self,
                forKey: .publicHandleSnapshot
            )
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .score,
                in: values,
                debugDescription: "Technique attempt fields violate evidence, version, time, proof, or provenance invariants."
            )
        }
        self = validated
    }

    var memoryKey: AthleteSkillMemoryKey? {
        AthleteSkillMemoryKey(
            eventID: eventID,
            athleteID: athleteID,
            techniqueID: techniqueID,
            stance: stance,
            referenceVersion: referenceVersion,
            scoringVersion: scoringVersion,
            calibrationVersion: calibrationVersion
        )
    }

    func hasCompatibleMetricAvailability(
        with other: TechniqueAttemptSnapshot
    ) -> Bool {
        availableMetricKinds == other.availableMetricKinds
    }

    private var availableMetricKinds: Set<String> {
        Set(metrics.lazy.compactMap { metric in
            metric.provenance == .unavailable ? nil : metric.kind
        })
    }
}

nonisolated enum PastSelfTraceCoordinateSpace: String, Codable, Hashable, Sendable {
    case normalizedBody
    case head
    case world
}

nonisolated struct NormalizedTraceSample: Codable, Hashable, Sendable {
    let time: Float
    let position: SIMD3<Float>

    init(time: Float, position: SIMD3<Float>) {
        self.time = time
        self.position = position
    }

    fileprivate var isValid: Bool {
        time.isFinite
            && (0...1).contains(time)
            && position.x.isFinite
            && position.y.isFinite
            && position.z.isFinite
    }
}

nonisolated struct PastSelfTrace: Codable, Hashable, Sendable {
    static let maximumSampleCount = 32

    let attemptID: UUID
    let samples: [NormalizedTraceSample]

    private enum CodingKeys: String, CodingKey {
        case attemptID
        case samples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let attemptID = try container.decode(UUID.self, forKey: .attemptID)
        let samples = try container.decode([NormalizedTraceSample].self, forKey: .samples)
        guard let validated = PastSelfTrace(
            attemptID: attemptID,
            coordinateSpace: .normalizedBody,
            samples: samples
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .samples,
                in: container,
                debugDescription: "Past-self traces require finite, ordered normalized body samples."
            )
        }
        self = validated
    }

    init?(
        attemptID: UUID,
        coordinateSpace: PastSelfTraceCoordinateSpace,
        samples: [NormalizedTraceSample]
    ) {
        guard coordinateSpace == .normalizedBody,
              !samples.isEmpty,
              samples.allSatisfy(\.isValid),
              zip(samples, samples.dropFirst()).allSatisfy({ $0.time <= $1.time })
        else { return nil }

        self.attemptID = attemptID
        self.samples = Self.downsample(samples)
    }

    private static func downsample(_ samples: [NormalizedTraceSample]) -> [NormalizedTraceSample] {
        guard samples.count > maximumSampleCount else { return samples }

        let finalIndex = samples.count - 1
        let finalSlot = maximumSampleCount - 1
        return (0..<maximumSampleCount).map { slot in
            let sourceIndex = Int((Double(slot) * Double(finalIndex) / Double(finalSlot)).rounded())
            return samples[sourceIndex]
        }
    }
}

nonisolated struct TechniqueProofDelta: Codable, Hashable, Sendable {
    let baselineAttemptID: UUID
    let retestAttemptID: UUID
    let coachingCycleID: UUID
    let scoreDelta: Float
    let correctionCode: String?
    let completedAt: Date
}

nonisolated struct AthleteSkillMemory: Codable, Hashable, Sendable {
    let key: AthleteSkillMemoryKey
    let athleteID: UUID
    let techniqueID: String
    let experienceLevel: ExperienceLevel
    let attempts: [TechniqueAttemptSnapshot]
    let pastSelfTrace: PastSelfTrace?
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case athleteID
        case techniqueID
        case experienceLevel
        case attempts
        case pastSelfTrace
        case updatedAt
    }

    init?(
        athleteID: UUID,
        techniqueID: String,
        experienceLevel: ExperienceLevel,
        attempts: [TechniqueAttemptSnapshot],
        pastSelfTrace: PastSelfTrace?,
        updatedAt: Date
    ) {
        let orderedAttempts = attempts.sorted(by: Self.attemptOrder)
        guard let first = orderedAttempts.first,
              let key = first.memoryKey,
              !techniqueID.isEmpty,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              orderedAttempts.allSatisfy({
                  $0.athleteID == athleteID
                      && $0.techniqueID == techniqueID
                      && $0.memoryKey == key
                      && $0.isValid
                      && $0.completedAt <= updatedAt
              }),
              pastSelfTrace.map({ trace in orderedAttempts.contains { $0.id == trace.attemptID } }) ?? true
        else { return nil }

        self.key = key
        self.athleteID = athleteID
        self.techniqueID = techniqueID
        self.experienceLevel = experienceLevel
        self.attempts = orderedAttempts
        self.pastSelfTrace = pastSelfTrace
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let athleteID = try container.decode(UUID.self, forKey: .athleteID)
        let techniqueID = try container.decode(String.self, forKey: .techniqueID)
        let experienceLevel = try container.decode(ExperienceLevel.self, forKey: .experienceLevel)
        let attempts = try container.decode([TechniqueAttemptSnapshot].self, forKey: .attempts)
        let pastSelfTrace = try container.decodeIfPresent(PastSelfTrace.self, forKey: .pastSelfTrace)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        guard let validated = AthleteSkillMemory(
            athleteID: athleteID,
            techniqueID: techniqueID,
            experienceLevel: experienceLevel,
            attempts: attempts,
            pastSelfTrace: pastSelfTrace,
            updatedAt: updatedAt
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .attempts,
                in: container,
                debugDescription: "Athlete memory contains attempts or trace data outside its athlete and technique."
            )
        }
        self = validated
    }

    var bestAttempt: TechniqueAttemptSnapshot? {
        attempts.max {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.completedAt != $1.completedAt { return $0.completedAt < $1.completedAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    var attemptCount: Int { attempts.count }

    var latestAttempt: TechniqueAttemptSnapshot? { attempts.last }

    var rollingLastThreeScore: Float? {
        let values = attempts.suffix(3).map(\.score)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    var correctionFocus: String? { latestAttempt?.correctionCode }

    var correctionFocusStreak: Int {
        guard let focus = correctionFocus else { return 0 }
        return attempts.reversed().prefix { $0.correctionCode == focus }.count
    }

    var lastProofDelta: TechniqueProofDelta? {
        for retest in attempts.reversed() where retest.stage == .retest {
            guard let baselineID = retest.baselineAttemptID,
                  let cycleID = retest.coachingCycleID,
                  let baseline = attempts.first(where: { $0.id == baselineID }),
                  baseline.stage == .baseline,
                  baseline.coachingCycleID == cycleID,
                  baseline.memoryKey == retest.memoryKey,
                  baseline.hasCompatibleMetricAvailability(with: retest),
                  baseline.correctionCode == retest.correctionCode,
                  baseline.completedAt <= retest.completedAt
            else { continue }
            return TechniqueProofDelta(
                baselineAttemptID: baseline.id,
                retestAttemptID: retest.id,
                coachingCycleID: cycleID,
                scoreDelta: retest.score - baseline.score,
                correctionCode: retest.correctionCode,
                completedAt: retest.completedAt
            )
        }
        return nil
    }

    func latestMetric(kind: String) -> TechniqueMetricSnapshot? {
        attempts.reversed().lazy.compactMap { attempt in
            attempt.metrics.first { $0.kind == kind && $0.provenance != .unavailable }
        }.first
    }

    func bestMetric(kind: String) -> TechniqueMetricSnapshot? {
        attempts.flatMap(\.metrics).filter {
            $0.kind == kind && $0.provenance != .unavailable
        }.max {
            ($0.score ?? -.infinity) < ($1.score ?? -.infinity)
        }
    }

    static func rebuilding(
        key: AthleteSkillMemoryKey,
        experienceLevel: ExperienceLevel,
        from attempts: [TechniqueAttemptSnapshot]
    ) -> AthleteSkillMemory? {
        let compatible = attempts.filter { $0.isValid && $0.memoryKey == key }
            .sorted(by: attemptOrder)
        guard let latest = compatible.last else { return nil }
        let trace = compatible.reversed().compactMap(\.pastSelfTrace).first
        return AthleteSkillMemory(
            athleteID: key.athleteID,
            techniqueID: key.techniqueID,
            experienceLevel: experienceLevel,
            attempts: compatible,
            pastSelfTrace: trace,
            updatedAt: latest.completedAt
        )
    }

    private static func attemptOrder(
        _ lhs: TechniqueAttemptSnapshot,
        _ rhs: TechniqueAttemptSnapshot
    ) -> Bool {
        if lhs.completedAt != rhs.completedAt { return lhs.completedAt < rhs.completedAt }
        if lhs.coachingCycleID == rhs.coachingCycleID,
           lhs.stage != rhs.stage {
            return lhs.stage == .baseline
        }
        if lhs.coachingCycleID == rhs.coachingCycleID,
           lhs.cycleOrdinal != rhs.cycleOrdinal {
            return (lhs.cycleOrdinal ?? .max) < (rhs.cycleOrdinal ?? .max)
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

nonisolated enum DurableTrainingRunKind: String, Codable, Hashable, Sendable {
    case auraCoaching
    case rankedCompetition
    case legacy
}

nonisolated struct DurableTrainingRunDescriptor: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case runID, kind, track, techniqueID, stance, competitionMode
    }
    let runID: UUID
    let kind: DurableTrainingRunKind
    let track: TrainingTrack?
    let techniqueID: String?
    let stance: Stance?
    let competitionMode: CompetitionMode?

    private init(
        runID: UUID,
        kind: DurableTrainingRunKind,
        track: TrainingTrack?,
        techniqueID: String?,
        stance: Stance?,
        competitionMode: CompetitionMode?
    ) {
        self.runID = runID
        self.kind = kind
        self.track = track
        self.techniqueID = techniqueID
        self.stance = stance
        self.competitionMode = competitionMode
    }

    static func aura(
        runID: UUID,
        track: TrainingTrack,
        technique: Technique,
        stance: Stance
    ) -> DurableTrainingRunDescriptor {
        DurableTrainingRunDescriptor(
            runID: runID,
            kind: .auraCoaching,
            track: track,
            techniqueID: technique.id,
            stance: stance,
            competitionMode: nil
        )
    }

    static func ranked(
        runID: UUID,
        mode: CompetitionMode,
        stance: Stance
    ) -> DurableTrainingRunDescriptor {
        DurableTrainingRunDescriptor(
            runID: runID,
            kind: .rankedCompetition,
            track: nil,
            techniqueID: nil,
            stance: stance,
            competitionMode: mode
        )
    }

    static func legacy(runID: UUID) -> DurableTrainingRunDescriptor {
        DurableTrainingRunDescriptor(
            runID: runID,
            kind: .legacy,
            track: nil,
            techniqueID: nil,
            stance: nil,
            competitionMode: nil
        )
    }

    func validates(_ run: PendingTrainingRun) -> Bool {
        guard runID == run.id else { return false }
        switch kind {
        case .auraCoaching:
            return track != nil && stance != nil && competitionMode == nil
                && techniqueID == run.techniqueID
        case .rankedCompetition:
            return track == nil && techniqueID == nil && stance != nil && competitionMode != nil
        case .legacy:
            return track == nil && techniqueID == nil && stance == nil && competitionMode == nil
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let runID = try values.decode(UUID.self, forKey: .runID)
        let kind = try values.decode(DurableTrainingRunKind.self, forKey: .kind)
        let track = try values.decodeIfPresent(TrainingTrack.self, forKey: .track)
        let techniqueID = try values.decodeIfPresent(String.self, forKey: .techniqueID)
        let stance = try values.decodeIfPresent(Stance.self, forKey: .stance)
        let competitionMode = try values.decodeIfPresent(CompetitionMode.self, forKey: .competitionMode)
        let decoded = DurableTrainingRunDescriptor(
            runID: runID,
            kind: kind,
            track: track,
            techniqueID: techniqueID,
            stance: stance,
            competitionMode: competitionMode
        )
        let shapeIsValid: Bool = switch kind {
        case .auraCoaching:
            track != nil && stance != nil && competitionMode == nil
                && !(techniqueID?.isEmpty ?? true)
        case .rankedCompetition:
            track == nil && techniqueID == nil && stance != nil && competitionMode != nil
        case .legacy:
            track == nil && techniqueID == nil && stance == nil && competitionMode == nil
        }
        guard shapeIsValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: values,
                debugDescription: "Run descriptor fields do not match its durable kind."
            )
        }
        self = decoded
    }
}

nonisolated struct PendingTrainingRun: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let athleteID: UUID
    let eventID: UUID?
    let techniqueID: String
    let requestedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case athleteID
        case eventID
        case techniqueID
        case requestedAt
    }

    init?(
        id: UUID,
        athleteID: UUID,
        eventID: UUID?,
        techniqueID: String,
        requestedAt: Date
    ) {
        guard !techniqueID.isEmpty,
              requestedAt.timeIntervalSinceReferenceDate.isFinite
        else { return nil }

        self.id = id
        self.athleteID = athleteID
        self.eventID = eventID
        self.techniqueID = techniqueID
        self.requestedAt = requestedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let athleteID = try container.decode(UUID.self, forKey: .athleteID)
        let eventID = try container.decodeIfPresent(UUID.self, forKey: .eventID)
        let techniqueID = try container.decode(String.self, forKey: .techniqueID)
        let requestedAt = try container.decode(Date.self, forKey: .requestedAt)

        guard let validated = PendingTrainingRun(
            id: id,
            athleteID: athleteID,
            eventID: eventID,
            techniqueID: techniqueID,
            requestedAt: requestedAt
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .techniqueID,
                in: container,
                debugDescription: "Pending training run requires a technique and finite request time."
            )
        }
        self = validated
    }

    func starting(at date: Date) -> ActiveTrainingRun? {
        guard date.timeIntervalSinceReferenceDate.isFinite, date >= requestedAt else { return nil }
        return ActiveTrainingRun(pending: self, startedAt: date)
    }
}

nonisolated struct ActiveTrainingRun: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let athleteID: UUID
    let eventID: UUID?
    let techniqueID: String
    let requestedAt: Date
    let startedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case athleteID
        case eventID
        case techniqueID
        case requestedAt
        case startedAt
    }

    private init?(
        id: UUID,
        athleteID: UUID,
        eventID: UUID?,
        techniqueID: String,
        requestedAt: Date,
        startedAt: Date
    ) {
        guard !techniqueID.isEmpty,
              requestedAt.timeIntervalSinceReferenceDate.isFinite,
              startedAt.timeIntervalSinceReferenceDate.isFinite,
              startedAt >= requestedAt
        else { return nil }

        self.id = id
        self.athleteID = athleteID
        self.eventID = eventID
        self.techniqueID = techniqueID
        self.requestedAt = requestedAt
        self.startedAt = startedAt
    }

    fileprivate init?(pending: PendingTrainingRun, startedAt: Date) {
        self.init(
            id: pending.id,
            athleteID: pending.athleteID,
            eventID: pending.eventID,
            techniqueID: pending.techniqueID,
            requestedAt: pending.requestedAt,
            startedAt: startedAt
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let athleteID = try container.decode(UUID.self, forKey: .athleteID)
        let eventID = try container.decodeIfPresent(UUID.self, forKey: .eventID)
        let techniqueID = try container.decode(String.self, forKey: .techniqueID)
        let requestedAt = try container.decode(Date.self, forKey: .requestedAt)
        let startedAt = try container.decode(Date.self, forKey: .startedAt)

        guard let validated = ActiveTrainingRun(
            id: id,
            athleteID: athleteID,
            eventID: eventID,
            techniqueID: techniqueID,
            requestedAt: requestedAt,
            startedAt: startedAt
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .startedAt,
                in: container,
                debugDescription: "Active training run must start at or after its finite request time."
            )
        }
        self = validated
    }

    func completing(with attempt: TechniqueAttemptSnapshot) -> CompletedTrainingRun? {
        guard attempt.athleteID == athleteID,
              attempt.eventID == eventID,
              attempt.techniqueID == techniqueID,
              attempt.startedAt >= startedAt
        else { return nil }
        return CompletedTrainingRun(active: self, attempt: attempt)
    }

    func cancelling(at date: Date) -> CancelledTrainingRun? {
        guard date.timeIntervalSinceReferenceDate.isFinite, date >= startedAt else { return nil }
        return CancelledTrainingRun(active: self, cancelledAt: date)
    }
}

nonisolated struct CompletedTrainingRun: Identifiable, Codable, Hashable, Sendable {
    let runID: UUID
    let athleteID: UUID
    let eventID: UUID?
    let techniqueID: String
    let startedAt: Date
    let completedAt: Date
    let attemptID: UUID

    var id: UUID { runID }

    private enum CodingKeys: String, CodingKey {
        case runID
        case athleteID
        case eventID
        case techniqueID
        case startedAt
        case completedAt
        case attemptID
    }

    private init?(
        runID: UUID,
        athleteID: UUID,
        eventID: UUID?,
        techniqueID: String,
        startedAt: Date,
        completedAt: Date,
        attemptID: UUID
    ) {
        guard !techniqueID.isEmpty,
              startedAt.timeIntervalSinceReferenceDate.isFinite,
              completedAt.timeIntervalSinceReferenceDate.isFinite,
              completedAt >= startedAt
        else { return nil }

        self.runID = runID
        self.athleteID = athleteID
        self.eventID = eventID
        self.techniqueID = techniqueID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.attemptID = attemptID
    }

    fileprivate init?(active: ActiveTrainingRun, attempt: TechniqueAttemptSnapshot) {
        self.init(
            runID: active.id,
            athleteID: active.athleteID,
            eventID: active.eventID,
            techniqueID: active.techniqueID,
            startedAt: active.startedAt,
            completedAt: attempt.completedAt,
            attemptID: attempt.id
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let runID = try container.decode(UUID.self, forKey: .runID)
        let athleteID = try container.decode(UUID.self, forKey: .athleteID)
        let eventID = try container.decodeIfPresent(UUID.self, forKey: .eventID)
        let techniqueID = try container.decode(String.self, forKey: .techniqueID)
        let startedAt = try container.decode(Date.self, forKey: .startedAt)
        let completedAt = try container.decode(Date.self, forKey: .completedAt)
        let attemptID = try container.decode(UUID.self, forKey: .attemptID)

        guard let validated = CompletedTrainingRun(
            runID: runID,
            athleteID: athleteID,
            eventID: eventID,
            techniqueID: techniqueID,
            startedAt: startedAt,
            completedAt: completedAt,
            attemptID: attemptID
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .completedAt,
                in: container,
                debugDescription: "Completed training run must finish at or after its finite start time."
            )
        }
        self = validated
    }
}

nonisolated struct CancelledTrainingRun: Identifiable, Codable, Hashable, Sendable {
    let runID: UUID
    let athleteID: UUID
    let eventID: UUID?
    let techniqueID: String
    let startedAt: Date
    let cancelledAt: Date

    var id: UUID { runID }

    private enum CodingKeys: String, CodingKey {
        case runID
        case athleteID
        case eventID
        case techniqueID
        case startedAt
        case cancelledAt
    }

    private init?(
        runID: UUID,
        athleteID: UUID,
        eventID: UUID?,
        techniqueID: String,
        startedAt: Date,
        cancelledAt: Date
    ) {
        guard !techniqueID.isEmpty,
              startedAt.timeIntervalSinceReferenceDate.isFinite,
              cancelledAt.timeIntervalSinceReferenceDate.isFinite,
              cancelledAt >= startedAt
        else { return nil }

        self.runID = runID
        self.athleteID = athleteID
        self.eventID = eventID
        self.techniqueID = techniqueID
        self.startedAt = startedAt
        self.cancelledAt = cancelledAt
    }

    fileprivate init?(active: ActiveTrainingRun, cancelledAt: Date) {
        self.init(
            runID: active.id,
            athleteID: active.athleteID,
            eventID: active.eventID,
            techniqueID: active.techniqueID,
            startedAt: active.startedAt,
            cancelledAt: cancelledAt
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let runID = try container.decode(UUID.self, forKey: .runID)
        let athleteID = try container.decode(UUID.self, forKey: .athleteID)
        let eventID = try container.decodeIfPresent(UUID.self, forKey: .eventID)
        let techniqueID = try container.decode(String.self, forKey: .techniqueID)
        let startedAt = try container.decode(Date.self, forKey: .startedAt)
        let cancelledAt = try container.decode(Date.self, forKey: .cancelledAt)

        guard let validated = CancelledTrainingRun(
            runID: runID,
            athleteID: athleteID,
            eventID: eventID,
            techniqueID: techniqueID,
            startedAt: startedAt,
            cancelledAt: cancelledAt
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .cancelledAt,
                in: container,
                debugDescription: "Cancelled training run must end at or after its finite start time."
            )
        }
        self = validated
    }
}

nonisolated enum TrainingRunStatus: String, Codable, Hashable, Sendable {
    case reserved
    case active
    case completedAwaitingCommit
    case committed
    case aborted
}

nonisolated struct TrainingRunSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let athleteID: UUID
    let eventID: UUID?
    let techniqueID: String
    let status: TrainingRunStatus
    let requestedAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let attemptID: UUID?
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case athleteID
        case eventID
        case techniqueID
        case status
        case requestedAt
        case startedAt
        case completedAt
        case attemptID
        case updatedAt
    }

    init?(_ pending: PendingTrainingRun) {
        self.init(
            id: pending.id,
            athleteID: pending.athleteID,
            eventID: pending.eventID,
            techniqueID: pending.techniqueID,
            status: .reserved,
            requestedAt: pending.requestedAt,
            startedAt: nil,
            completedAt: nil,
            attemptID: nil,
            updatedAt: pending.requestedAt
        )
    }

    private init?(
        id: UUID,
        athleteID: UUID,
        eventID: UUID?,
        techniqueID: String,
        status: TrainingRunStatus,
        requestedAt: Date,
        startedAt: Date?,
        completedAt: Date?,
        attemptID: UUID?,
        updatedAt: Date
    ) {
        guard !techniqueID.isEmpty,
              requestedAt.timeIntervalSinceReferenceDate.isFinite,
              startedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              completedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt >= requestedAt,
              startedAt.map({ $0 >= requestedAt && $0 <= updatedAt }) ?? true,
              completedAt.map({ completed in
                  completed >= (startedAt ?? requestedAt) && completed <= updatedAt
              }) ?? true
        else { return nil }

        switch status {
        case .reserved:
            guard startedAt == nil, completedAt == nil, attemptID == nil,
                  updatedAt == requestedAt else { return nil }
        case .active:
            guard startedAt != nil, completedAt == nil, attemptID == nil else { return nil }
        case .completedAwaitingCommit, .committed:
            guard startedAt != nil, completedAt != nil, attemptID == id else { return nil }
        case .aborted:
            guard completedAt != nil, attemptID == nil else { return nil }
        }

        self.id = id
        self.athleteID = athleteID
        self.eventID = eventID
        self.techniqueID = techniqueID
        self.status = status
        self.requestedAt = requestedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.attemptID = attemptID
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let validated = TrainingRunSnapshot(
            id: try values.decode(UUID.self, forKey: .id),
            athleteID: try values.decode(UUID.self, forKey: .athleteID),
            eventID: try values.decodeIfPresent(UUID.self, forKey: .eventID),
            techniqueID: try values.decode(String.self, forKey: .techniqueID),
            status: try values.decode(TrainingRunStatus.self, forKey: .status),
            requestedAt: try values.decode(Date.self, forKey: .requestedAt),
            startedAt: try values.decodeIfPresent(Date.self, forKey: .startedAt),
            completedAt: try values.decodeIfPresent(Date.self, forKey: .completedAt),
            attemptID: try values.decodeIfPresent(UUID.self, forKey: .attemptID),
            updatedAt: try values.decode(Date.self, forKey: .updatedAt)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: values,
                debugDescription: "Training run timestamps and evidence do not match its state."
            )
        }
        self = validated
    }

    func starting(at date: Date) -> TrainingRunSnapshot? {
        guard status == .reserved else { return nil }
        return TrainingRunSnapshot(
            id: id,
            athleteID: athleteID,
            eventID: eventID,
            techniqueID: techniqueID,
            status: .active,
            requestedAt: requestedAt,
            startedAt: date,
            completedAt: nil,
            attemptID: nil,
            updatedAt: date
        )
    }

    func completing(with attempt: TechniqueAttemptSnapshot) -> TrainingRunSnapshot? {
        guard status == .active,
              attempt.id == id,
              attempt.athleteID == athleteID,
              attempt.eventID == eventID,
              attempt.techniqueID == techniqueID,
              attempt.isValid,
              let startedAt,
              attempt.startedAt >= startedAt
        else { return nil }
        return TrainingRunSnapshot(
            id: id,
            athleteID: athleteID,
            eventID: eventID,
            techniqueID: techniqueID,
            status: .completedAwaitingCommit,
            requestedAt: requestedAt,
            startedAt: startedAt,
            completedAt: attempt.completedAt,
            attemptID: attempt.id,
            updatedAt: attempt.completedAt
        )
    }

    func completing(with cycle: CoachingCycleSnapshot) -> TrainingRunSnapshot? {
        guard status == .active,
              cycle.id == id,
              cycle.athleteID == athleteID,
              cycle.eventID == eventID,
              cycle.techniqueID == techniqueID,
              cycle.attempts.count == CoachingCycleSession.requiredAttempts * 2,
              let startedAt,
              cycle.completedAt >= startedAt
        else { return nil }
        return TrainingRunSnapshot(
            id: id,
            athleteID: athleteID,
            eventID: eventID,
            techniqueID: techniqueID,
            status: .completedAwaitingCommit,
            requestedAt: requestedAt,
            startedAt: startedAt,
            completedAt: cycle.completedAt,
            attemptID: id,
            updatedAt: cycle.completedAt
        )
    }

    func committing(at date: Date) -> TrainingRunSnapshot? {
        guard status == .completedAwaitingCommit,
              let startedAt,
              let completedAt,
              let attemptID
        else { return nil }
        return TrainingRunSnapshot(
            id: id,
            athleteID: athleteID,
            eventID: eventID,
            techniqueID: techniqueID,
            status: .committed,
            requestedAt: requestedAt,
            startedAt: startedAt,
            completedAt: completedAt,
            attemptID: attemptID,
            updatedAt: date
        )
    }

    func aborting(at date: Date) -> TrainingRunSnapshot? {
        guard status == .reserved || status == .active else { return nil }
        return TrainingRunSnapshot(
            id: id,
            athleteID: athleteID,
            eventID: eventID,
            techniqueID: techniqueID,
            status: .aborted,
            requestedAt: requestedAt,
            startedAt: startedAt,
            completedAt: date,
            attemptID: nil,
            updatedAt: date
        )
    }
}

nonisolated enum EventAwardKind: String, Codable, CaseIterable, Hashable, Sendable {
    case completion
    case personalBest
    case mostImproved
    case eventChampion
}

nonisolated struct EventAward: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let eventID: UUID
    let athleteID: UUID
    let publicHandleSnapshot: ParticipantPublicHandle
    let kind: EventAwardKind
    let attemptID: UUID?
    let awardedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case eventID
        case athleteID
        case publicHandleSnapshot
        case kind
        case attemptID
        case awardedAt
    }

    init?(
        id: UUID,
        eventID: UUID,
        athleteID: UUID,
        publicHandleSnapshot: ParticipantPublicHandle,
        kind: EventAwardKind,
        attemptID: UUID?,
        awardedAt: Date
    ) {
        guard publicHandleSnapshot.eventID == eventID,
              awardedAt.timeIntervalSinceReferenceDate.isFinite
        else { return nil }

        self.id = id
        self.eventID = eventID
        self.athleteID = athleteID
        self.publicHandleSnapshot = publicHandleSnapshot
        self.kind = kind
        self.attemptID = attemptID
        self.awardedAt = awardedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let eventID = try container.decode(UUID.self, forKey: .eventID)
        let athleteID = try container.decode(UUID.self, forKey: .athleteID)
        let publicHandleSnapshot = try container.decode(
            ParticipantPublicHandle.self,
            forKey: .publicHandleSnapshot
        )
        let kind = try container.decode(EventAwardKind.self, forKey: .kind)
        let attemptID = try container.decodeIfPresent(UUID.self, forKey: .attemptID)
        let awardedAt = try container.decode(Date.self, forKey: .awardedAt)

        guard let validated = EventAward(
            id: id,
            eventID: eventID,
            athleteID: athleteID,
            publicHandleSnapshot: publicHandleSnapshot,
            kind: kind,
            attemptID: attemptID,
            awardedAt: awardedAt
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .publicHandleSnapshot,
                in: container,
                debugDescription: "Event award handle must belong to its event and use a finite award time."
            )
        }
        self = validated
    }
}
