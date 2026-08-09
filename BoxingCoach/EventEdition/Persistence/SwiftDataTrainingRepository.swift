import Foundation
import SwiftData

@MainActor
final class SwiftDataTrainingRepository: TrainingRepository {
    let isPersistent = true

    let container: ModelContainer
    private let context: ModelContext
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
        context.autosaveEnabled = false
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    func loadActiveEvent() async throws -> EventSnapshot? {
        try await events().first { $0.status == .open || $0.status == .draft }
    }

    func events() async throws -> [EventSnapshot] {
        try context.fetch(FetchDescriptor<EventRecord>())
            .map(\.snapshot)
            .sorted { $0.createdAt > $1.createdAt }
    }

    func event(id: UUID) async throws -> EventSnapshot? {
        try eventRecord(id: id)?.snapshot
    }

    func createEvent(_ snapshot: EventSnapshot) async throws {
        let records = try context.fetch(FetchDescriptor<EventRecord>())
        guard !records.contains(where: { $0.statusRawValue == EventStatus.open.rawValue }) else {
            throw TrainingRepositoryError.activeEventAlreadyExists
        }
        context.insert(EventRecord(snapshot: snapshot))
        try save()
    }

    func updateEvent(_ snapshot: EventSnapshot) async throws {
        guard let record = try eventRecord(id: snapshot.id) else { throw TrainingRepositoryError.eventNotFound }
        record.title = snapshot.title
        record.timeZoneIdentifier = snapshot.timeZoneIdentifier
        record.statusRawValue = snapshot.status.rawValue
        record.createdAt = snapshot.createdAt
        record.startedAt = snapshot.startedAt
        record.closedAt = snapshot.closedAt
        record.challengeID = snapshot.challengeID
        record.scoringVersion = snapshot.scoringVersion
        record.rulesData = snapshot.rulesData
        record.rulesDigest = snapshot.rulesDigest
        record.maxOfficialAttempts = snapshot.maxOfficialAttempts
        try save()
    }

    func nextCompetitorNumber(eventID: UUID) async throws -> Int {
        try context.fetch(FetchDescriptor<EventEntryRecord>())
            .filter { $0.eventID == eventID }
            .map(\.competitorNumber)
            .max()
            .map { $0 + 1 } ?? 1
    }

    func createParticipant(_ snapshot: ParticipantSnapshot) async throws {
        guard try eventRecord(id: snapshot.eventID) != nil else { throw TrainingRepositoryError.eventNotFound }
        context.insert(ParticipantRecord(
            id: snapshot.id,
            alias: snapshot.alias,
            normalizedAlias: snapshot.normalizedAlias,
            avatarID: snapshot.avatarID,
            stance: snapshot.stance,
            createdAt: snapshot.createdAt,
            lastSeenAt: snapshot.lastSeenAt,
            archived: snapshot.archived
        ))
        context.insert(EventEntryRecord(
            id: snapshot.entryID,
            eventID: snapshot.eventID,
            participantID: snapshot.id,
            competitorNumber: snapshot.competitorNumber,
            isLeaderboardPublic: snapshot.isLeaderboardPublic,
            lessonCompletedAt: snapshot.lessonCompletedAt,
            coachOverrideAt: snapshot.coachOverrideAt
        ))
        try save()
    }

    func updateParticipant(_ snapshot: ParticipantSnapshot) async throws {
        guard let participant = try participantRecord(id: snapshot.id),
              let entry = try entryRecord(id: snapshot.entryID),
              entry.eventID == snapshot.eventID
        else { throw TrainingRepositoryError.participantNotFound }

        participant.alias = snapshot.alias
        participant.normalizedAlias = snapshot.normalizedAlias
        participant.avatarID = snapshot.avatarID
        participant.preferredStanceRawValue = snapshot.stance.rawValue
        participant.lastSeenAt = snapshot.lastSeenAt
        participant.archived = snapshot.archived
        entry.isLeaderboardPublic = snapshot.isLeaderboardPublic
        entry.lessonCompletedAt = snapshot.lessonCompletedAt
        entry.coachOverrideAt = snapshot.coachOverrideAt
        try save()
    }

    func participant(id: UUID, eventID: UUID) async throws -> ParticipantSnapshot? {
        guard let record = try participantRecord(id: id),
              let entry = try context.fetch(FetchDescriptor<EventEntryRecord>())
                .first(where: { $0.eventID == eventID && $0.participantID == id })
        else { return nil }
        return participantSnapshot(record: record, entry: entry)
    }

    func participantMatches(eventID: UUID, normalizedAlias: String) async throws -> [ParticipantSnapshot] {
        let records = try context.fetch(FetchDescriptor<ParticipantRecord>())
            .filter { $0.normalizedAlias == normalizedAlias && !$0.archived }
        let entries = try context.fetch(FetchDescriptor<EventEntryRecord>())
            .filter { $0.eventID == eventID }
        let entryByParticipant = Dictionary(uniqueKeysWithValues: entries.map { ($0.participantID, $0) })

        return records.compactMap { record in
            guard let entry = entryByParticipant[record.id] else { return nil }
            return participantSnapshot(record: record, entry: entry)
        }
    }

    func participants(eventID: UUID) async throws -> [ParticipantSnapshot] {
        let participantByID = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<ParticipantRecord>()).map { ($0.id, $0) }
        )
        return try context.fetch(FetchDescriptor<EventEntryRecord>())
            .filter { $0.eventID == eventID }
            .compactMap { entry in
                participantByID[entry.participantID].map { participantSnapshot(record: $0, entry: entry) }
            }
            .sorted { $0.competitorNumber < $1.competitorNumber }
    }

    func beginRun(_ contextValue: TrainingRunContext) async throws {
        if let existing = try runRecord(id: contextValue.runID) {
            if existing.statusRawValue == TrainingRunStatus.inProgress.rawValue { return }
            throw TrainingRepositoryError.finalizedRunCannotChange
        }
        context.insert(TrainingRunRecord(
            context: contextValue,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            visionOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
        ))
        try save()
    }

    func checkpoint(_ checkpoint: RunCheckpoint) async throws {
        guard let record = try runRecord(id: checkpoint.runID) else { throw TrainingRepositoryError.runNotFound }
        guard record.statusRawValue == TrainingRunStatus.inProgress.rawValue,
              record.snapshotData == nil else { throw TrainingRepositoryError.finalizedRunCannotChange }
        record.checkpointData = checkpoint.snapshotData
        record.checkpointStageID = checkpoint.completedStageID
        record.checkpointAt = checkpoint.createdAt
        try save()
    }

    func finalize(_ snapshot: TrainingRunSnapshot) async throws -> CommitOutcome {
        guard let record = try runRecord(id: snapshot.id) else { throw TrainingRepositoryError.runNotFound }
        if record.snapshotData != nil || record.statusRawValue != TrainingRunStatus.inProgress.rawValue {
            return .alreadyFinalized(runID: snapshot.id)
        }
        let encoded = try encoder.encode(snapshot)
        record.apply(snapshot, encoded: encoded)
        record.checkpointData = nil
        record.checkpointStageID = nil
        record.checkpointAt = nil
        try save()
        return .committed(runID: snapshot.id)
    }

    func run(id: UUID) async throws -> TrainingRunSnapshot? {
        guard let record = try runRecord(id: id), let data = record.snapshotData else { return nil }
        do {
            return try decoder.decode(TrainingRunSnapshot.self, from: data)
        } catch {
            throw TrainingRepositoryError.corruptedSnapshot
        }
    }

    func runs(eventID: UUID) async throws -> [TrainingRunSnapshot] {
        try context.fetch(FetchDescriptor<TrainingRunRecord>())
            .filter { $0.eventID == eventID }
            .compactMap { record in
                guard let data = record.snapshotData else { return nil }
                return try decoder.decode(TrainingRunSnapshot.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func markStaleRunsInterrupted(before cutoff: Date) async throws {
        let stale = try context.fetch(FetchDescriptor<TrainingRunRecord>()).filter {
            $0.statusRawValue == TrainingRunStatus.inProgress.rawValue && $0.startedAt < cutoff
        }
        for record in stale {
            guard let plan = TrainingPlan(rawValue: record.planRawValue),
                  let stance = Stance(rawValue: record.stanceRawValue)
            else { continue }
            let snapshot = TrainingRunSnapshot(
                id: record.id,
                eventID: record.eventID,
                participantID: record.participantID,
                entryID: record.entryID,
                aliasSnapshot: record.aliasSnapshot,
                avatarIDSnapshot: record.avatarIDSnapshot,
                plan: plan,
                status: .interrupted,
                stance: stance,
                startedAt: record.startedAt,
                endedAt: cutoff,
                officialOrdinal: record.officialOrdinal,
                rulesDigest: record.rulesDigest,
                trackingSummary: "Interrupted before finalization",
                optedIntoLeaderboard: false,
                eligibilityReason: .partialResult
            )
            record.apply(snapshot, encoded: try encoder.encode(snapshot))
        }
        if !stale.isEmpty { try save() }
    }

    func awards(eventID: UUID) async throws -> [AwardSnapshot] {
        try context.fetch(FetchDescriptor<AwardRecord>())
            .filter { $0.eventID == eventID }
            .compactMap(\.snapshot)
            .sorted { lhs, rhs in
                if lhs.category.rawValue == rhs.category.rawValue { return lhs.rank < rhs.rank }
                return lhs.category.rawValue < rhs.category.rawValue
            }
    }

    func replaceAwards(eventID: UUID, with awards: [AwardSnapshot]) async throws {
        for record in try context.fetch(FetchDescriptor<AwardRecord>()) where record.eventID == eventID {
            context.delete(record)
        }
        for award in awards { context.insert(AwardRecord(award)) }
        try save()
    }

    func closeEvent(_ event: EventSnapshot, awards: [AwardSnapshot]) async throws {
        guard let eventRecord = try eventRecord(id: event.id) else {
            throw TrainingRepositoryError.eventNotFound
        }
        eventRecord.statusRawValue = event.status.rawValue
        eventRecord.closedAt = event.closedAt
        for record in try context.fetch(FetchDescriptor<AwardRecord>()) where record.eventID == event.id {
            context.delete(record)
        }
        for award in awards { context.insert(AwardRecord(award)) }
        try save()
    }

    private func eventRecord(id: UUID) throws -> EventRecord? {
        try context.fetch(FetchDescriptor<EventRecord>()).first { $0.id == id }
    }

    private func participantRecord(id: UUID) throws -> ParticipantRecord? {
        try context.fetch(FetchDescriptor<ParticipantRecord>()).first { $0.id == id }
    }

    private func entryRecord(id: UUID) throws -> EventEntryRecord? {
        try context.fetch(FetchDescriptor<EventEntryRecord>()).first { $0.id == id }
    }

    private func runRecord(id: UUID) throws -> TrainingRunRecord? {
        try context.fetch(FetchDescriptor<TrainingRunRecord>()).first { $0.id == id }
    }

    private func participantSnapshot(
        record: ParticipantRecord,
        entry: EventEntryRecord
    ) -> ParticipantSnapshot {
        ParticipantSnapshot(
            id: record.id,
            eventID: entry.eventID,
            entryID: entry.id,
            alias: record.alias,
            normalizedAlias: record.normalizedAlias,
            avatarID: record.avatarID,
            stance: Stance(rawValue: record.preferredStanceRawValue) ?? .orthodox,
            competitorNumber: entry.competitorNumber,
            isLeaderboardPublic: entry.isLeaderboardPublic,
            lessonCompletedAt: entry.lessonCompletedAt,
            coachOverrideAt: entry.coachOverrideAt,
            createdAt: record.createdAt,
            lastSeenAt: record.lastSeenAt,
            archived: record.archived
        )
    }

    private func save() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw TrainingRepositoryError.saveFailed("The result could not be saved. Nothing was changed.")
        }
    }
}
