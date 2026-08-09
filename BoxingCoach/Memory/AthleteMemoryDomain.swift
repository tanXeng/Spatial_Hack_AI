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

nonisolated struct TechniqueAttemptSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let athleteID: UUID
    let eventID: UUID?
    let techniqueID: String
    let score: Float
    let scoringVersion: Int
    let calibrationVersion: Int?
    let startedAt: Date
    let completedAt: Date
    let publicHandleSnapshot: ParticipantPublicHandle?

    private enum CodingKeys: String, CodingKey {
        case id
        case athleteID
        case eventID
        case techniqueID
        case score
        case scoringVersion
        case calibrationVersion
        case startedAt
        case completedAt
        case publicHandleSnapshot
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
        guard !techniqueID.isEmpty,
              score.isFinite,
              (0...100).contains(score),
              scoringVersion > 0,
              calibrationVersion.map({ $0 > 0 }) ?? true,
              startedAt.timeIntervalSinceReferenceDate.isFinite,
              completedAt.timeIntervalSinceReferenceDate.isFinite,
              completedAt >= startedAt,
              publicHandleSnapshot.map({ $0.eventID == eventID }) ?? true
        else { return nil }

        self.id = id
        self.athleteID = athleteID
        self.eventID = eventID
        self.techniqueID = techniqueID
        self.score = score
        self.scoringVersion = scoringVersion
        self.calibrationVersion = calibrationVersion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.publicHandleSnapshot = publicHandleSnapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let athleteID = try container.decode(UUID.self, forKey: .athleteID)
        let eventID = try container.decodeIfPresent(UUID.self, forKey: .eventID)
        let techniqueID = try container.decode(String.self, forKey: .techniqueID)
        let score = try container.decode(Float.self, forKey: .score)
        let scoringVersion = try container.decode(Int.self, forKey: .scoringVersion)
        let calibrationVersion = try container.decodeIfPresent(Int.self, forKey: .calibrationVersion)
        let startedAt = try container.decode(Date.self, forKey: .startedAt)
        let completedAt = try container.decode(Date.self, forKey: .completedAt)
        let publicHandleSnapshot = try container.decodeIfPresent(
            ParticipantPublicHandle.self,
            forKey: .publicHandleSnapshot
        )

        guard let validated = TechniqueAttemptSnapshot(
            id: id,
            athleteID: athleteID,
            eventID: eventID,
            techniqueID: techniqueID,
            score: score,
            scoringVersion: scoringVersion,
            calibrationVersion: calibrationVersion,
            startedAt: startedAt,
            completedAt: completedAt,
            publicHandleSnapshot: publicHandleSnapshot
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .score,
                in: container,
                debugDescription: "Technique attempt fields violate score, version, time, or event provenance invariants."
            )
        }
        self = validated
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

nonisolated struct AthleteSkillMemory: Codable, Hashable, Sendable {
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
        guard !techniqueID.isEmpty,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              attempts.allSatisfy({
                  $0.athleteID == athleteID
                      && $0.techniqueID == techniqueID
                      && $0.completedAt <= updatedAt
              }),
              pastSelfTrace.map({ trace in attempts.contains { $0.id == trace.attemptID } }) ?? true
        else { return nil }

        self.athleteID = athleteID
        self.techniqueID = techniqueID
        self.experienceLevel = experienceLevel
        self.attempts = attempts
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
            return $0.completedAt > $1.completedAt
        }
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
