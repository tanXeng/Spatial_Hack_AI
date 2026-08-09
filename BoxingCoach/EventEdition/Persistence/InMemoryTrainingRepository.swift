import Foundation

@MainActor
final class InMemoryTrainingRepository: TrainingRepository {
    let isPersistent = false

    private var eventValues: [UUID: EventSnapshot] = [:]
    private var participantValues: [UUID: ParticipantSnapshot] = [:]
    private var runContexts: [UUID: TrainingRunContext] = [:]
    private var runValues: [UUID: TrainingRunSnapshot] = [:]
    private var checkpoints: [UUID: RunCheckpoint] = [:]
    private var awardValues: [UUID: AwardSnapshot] = [:]

    var forcedFailure: TrainingRepositoryError?

    func loadActiveEvent() async throws -> EventSnapshot? {
        try failIfNeeded()
        return eventValues.values
            .filter { $0.status == .open || $0.status == .draft }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    func events() async throws -> [EventSnapshot] {
        try failIfNeeded()
        return eventValues.values.sorted { $0.createdAt > $1.createdAt }
    }

    func event(id: UUID) async throws -> EventSnapshot? {
        try failIfNeeded()
        return eventValues[id]
    }

    func createEvent(_ snapshot: EventSnapshot) async throws {
        try failIfNeeded()
        if eventValues.values.contains(where: { $0.status == .open }) {
            throw TrainingRepositoryError.activeEventAlreadyExists
        }
        eventValues[snapshot.id] = snapshot
    }

    func updateEvent(_ snapshot: EventSnapshot) async throws {
        try failIfNeeded()
        guard eventValues[snapshot.id] != nil else { throw TrainingRepositoryError.eventNotFound }
        eventValues[snapshot.id] = snapshot
    }

    func nextCompetitorNumber(eventID: UUID) async throws -> Int {
        try failIfNeeded()
        return participantValues.values
            .filter { $0.eventID == eventID }
            .map(\.competitorNumber)
            .max()
            .map { $0 + 1 } ?? 1
    }

    func createParticipant(_ snapshot: ParticipantSnapshot) async throws {
        try failIfNeeded()
        guard eventValues[snapshot.eventID] != nil else { throw TrainingRepositoryError.eventNotFound }
        participantValues[snapshot.id] = snapshot
    }

    func updateParticipant(_ snapshot: ParticipantSnapshot) async throws {
        try failIfNeeded()
        guard participantValues[snapshot.id] != nil else { throw TrainingRepositoryError.participantNotFound }
        participantValues[snapshot.id] = snapshot
    }

    func participant(id: UUID, eventID: UUID) async throws -> ParticipantSnapshot? {
        try failIfNeeded()
        guard let participant = participantValues[id], participant.eventID == eventID else { return nil }
        return participant
    }

    func participantMatches(eventID: UUID, normalizedAlias: String) async throws -> [ParticipantSnapshot] {
        try failIfNeeded()
        return participantValues.values.filter {
            $0.eventID == eventID && $0.normalizedAlias == normalizedAlias && !$0.archived
        }
    }

    func participants(eventID: UUID) async throws -> [ParticipantSnapshot] {
        try failIfNeeded()
        return participantValues.values
            .filter { $0.eventID == eventID }
            .sorted { $0.competitorNumber < $1.competitorNumber }
    }

    func beginRun(_ context: TrainingRunContext) async throws {
        try failIfNeeded()
        if let finalized = runValues[context.runID], finalized.status != .inProgress {
            throw TrainingRepositoryError.finalizedRunCannotChange
        }
        if runContexts[context.runID] != nil { return }
        runContexts[context.runID] = context
    }

    func checkpoint(_ checkpoint: RunCheckpoint) async throws {
        try failIfNeeded()
        guard runContexts[checkpoint.runID] != nil else { throw TrainingRepositoryError.runNotFound }
        guard runValues[checkpoint.runID] == nil else { throw TrainingRepositoryError.finalizedRunCannotChange }
        checkpoints[checkpoint.runID] = checkpoint
    }

    func finalize(_ snapshot: TrainingRunSnapshot) async throws -> CommitOutcome {
        try failIfNeeded()
        guard runContexts[snapshot.id] != nil else { throw TrainingRepositoryError.runNotFound }
        if runValues[snapshot.id] != nil { return .alreadyFinalized(runID: snapshot.id) }
        runValues[snapshot.id] = snapshot
        checkpoints[snapshot.id] = nil
        return .committed(runID: snapshot.id)
    }

    func run(id: UUID) async throws -> TrainingRunSnapshot? {
        try failIfNeeded()
        return runValues[id]
    }

    func runs(eventID: UUID) async throws -> [TrainingRunSnapshot] {
        try failIfNeeded()
        return runValues.values
            .filter { $0.eventID == eventID }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func markStaleRunsInterrupted(before cutoff: Date) async throws {
        try failIfNeeded()
        for (runID, context) in runContexts where context.startedAt < cutoff && runValues[runID] == nil {
            runValues[runID] = TrainingRunSnapshot(
                id: runID,
                eventID: context.eventID,
                participantID: context.participantID,
                entryID: context.entryID,
                aliasSnapshot: context.aliasSnapshot,
                avatarIDSnapshot: context.avatarIDSnapshot,
                plan: context.plan,
                status: .interrupted,
                stance: context.stance,
                startedAt: context.startedAt,
                endedAt: cutoff,
                officialOrdinal: context.officialOrdinal,
                rulesDigest: context.rulesDigest,
                trackingSummary: "Interrupted before finalization",
                optedIntoLeaderboard: false,
                eligibilityReason: .partialResult
            )
        }
    }

    func awards(eventID: UUID) async throws -> [AwardSnapshot] {
        try failIfNeeded()
        return awardValues.values
            .filter { $0.eventID == eventID }
            .sorted { lhs, rhs in
                if lhs.category.rawValue == rhs.category.rawValue { return lhs.rank < rhs.rank }
                return lhs.category.rawValue < rhs.category.rawValue
            }
    }

    func replaceAwards(eventID: UUID, with awards: [AwardSnapshot]) async throws {
        try failIfNeeded()
        awardValues = awardValues.filter { $0.value.eventID != eventID }
        for award in awards { awardValues[award.id] = award }
    }

    func closeEvent(_ event: EventSnapshot, awards: [AwardSnapshot]) async throws {
        try failIfNeeded()
        guard eventValues[event.id] != nil else { throw TrainingRepositoryError.eventNotFound }
        eventValues[event.id] = event
        awardValues = awardValues.filter { $0.value.eventID != event.id }
        for award in awards { awardValues[award.id] = award }
    }

    private func failIfNeeded() throws {
        if let forcedFailure { throw forcedFailure }
    }
}
