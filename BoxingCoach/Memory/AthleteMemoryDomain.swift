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
    let code: String

    var displayValue: String { "\(displayName) #\(code)" }

    private enum CodingKeys: String, CodingKey {
        case eventID
        case displayName
        case code
    }

    private init(eventID: UUID, displayName: String, code: String) {
        self.eventID = eventID
        self.displayName = displayName
        self.code = code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let eventID = try container.decode(UUID.self, forKey: .eventID)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let code = try container.decode(String.self, forKey: .code)
        guard let validated = Self.reserving(
            eventID: eventID,
            displayName: displayName,
            code: code,
            against: []
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .code,
                in: container,
                debugDescription: "Participant code must contain exactly four ASCII digits."
            )
        }
        self = validated
    }

    static func reserving(
        eventID: UUID,
        displayName: String,
        code: String,
        against existing: [ParticipantPublicHandle]
    ) -> ParticipantPublicHandle? {
        guard isFourDigitCode(code),
              !existing.contains(where: { $0.eventID == eventID && $0.code == code }),
              let validatedName = try? CompetitionName.display(displayName)
        else { return nil }

        return ParticipantPublicHandle(
            eventID: eventID,
            displayName: validatedName,
            code: code
        )
    }

    static func allocating(
        eventID: UUID,
        displayName: String,
        against existing: [ParticipantPublicHandle]
    ) -> ParticipantPublicHandle? {
        let reserved = Set(existing.lazy.filter { $0.eventID == eventID }.map(\.code))
        guard reserved.count < 10_000 else { return nil }

        for candidate in 0..<10_000 {
            let code = String(format: "%04d", candidate)
            guard !reserved.contains(code) else { continue }
            return reserving(
                eventID: eventID,
                displayName: displayName,
                code: code,
                against: existing
            )
        }
        return nil
    }

    private static func isFourDigitCode(_ value: String) -> Bool {
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

    fileprivate init(pending: PendingTrainingRun, startedAt: Date) {
        id = pending.id
        athleteID = pending.athleteID
        eventID = pending.eventID
        techniqueID = pending.techniqueID
        requestedAt = pending.requestedAt
        self.startedAt = startedAt
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

    fileprivate init(active: ActiveTrainingRun, attempt: TechniqueAttemptSnapshot) {
        runID = active.id
        athleteID = active.athleteID
        eventID = active.eventID
        techniqueID = active.techniqueID
        startedAt = active.startedAt
        completedAt = attempt.completedAt
        attemptID = attempt.id
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

    fileprivate init(active: ActiveTrainingRun, cancelledAt: Date) {
        runID = active.id
        athleteID = active.athleteID
        eventID = active.eventID
        techniqueID = active.techniqueID
        startedAt = active.startedAt
        self.cancelledAt = cancelledAt
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
}
