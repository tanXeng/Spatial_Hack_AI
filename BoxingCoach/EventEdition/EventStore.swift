import Foundation

enum EventLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

struct PendingRunSnapshot: Sendable, Equatable {
    let snapshot: TrainingRunSnapshot
    let reason: String
}

enum EventStoreError: LocalizedError, Equatable, Sendable {
    case repositoryUnavailable
    case noActiveEvent
    case eventNotOpen
    case eventNotDraft
    case noActiveParticipant
    case existingPlayerName
    case participantNotFound
    case activeRunPreventsClosure
    case savePending
    case recoveryFailed
    case wrapped(String)

    var errorDescription: String? {
        switch self {
        case .repositoryUnavailable: return "Saved profiles are unavailable. Open Recovery before continuing."
        case .noActiveEvent: return "No event is ready yet."
        case .eventNotOpen: return "The competition is not open."
        case .eventNotDraft: return "Only a draft event can be opened."
        case .noActiveParticipant: return "Choose a participant before starting."
        case .existingPlayerName: return "That player name is already in use for this event."
        case .participantNotFound: return "We couldn’t find that player name for this event."
        case .activeRunPreventsClosure: return "Finish or end the active session before closing the competition."
        case .savePending: return "The session is safe in memory, but saving is not complete. Try again."
        case .recoveryFailed: return "The result was committed, but its recovery snapshot could not be updated. Try again."
        case .wrapped(let message): return message
        }
    }
}

@Observable
@MainActor
final class EventStore {
    private(set) var loadState: EventLoadState = .idle
    private(set) var activeEvent: EventSnapshot?
    private(set) var activeParticipant: ParticipantSnapshot?
    private(set) var activeRunID: UUID?
    private(set) var pendingSave: PendingRunSnapshot?
    private(set) var presentationError: EventStoreError?
    private(set) var leaderboardEntries: [LeaderboardEntry] = []
    private(set) var selectedLeaderboardCategory: LeaderboardCategory = .overall
    private(set) var hasSafetyConfirmation = false
    private(set) var handoffMessage: String?

    private let repository: (any TrainingRepository)?
    private let recoveryStore: RecoverySnapshotStore?
    private let now: () -> Date

    init(
        repository: (any TrainingRepository)?,
        recoveryStore: RecoverySnapshotStore? = nil,
        startupError: EventStoreError? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.recoveryStore = recoveryStore
        self.now = now
        if let startupError {
            loadState = .failed(startupError.localizedDescription)
            presentationError = startupError
        }
    }

    static func live() -> EventStore {
        do {
            let container = try BoxingCoachModelContainer.make(inMemory: false)
            return EventStore(
                repository: SwiftDataTrainingRepository(container: container),
                recoveryStore: try RecoverySnapshotStore.live()
            )
        } catch {
            return EventStore(
                repository: nil,
                startupError: .wrapped("Saved event data could not be opened. Nothing was deleted.")
            )
        }
    }

    static func preview() -> EventStore {
        EventStore(repository: InMemoryTrainingRepository())
    }

    func bootstrap() async {
        guard loadState != .loading else { return }
        guard let repository else {
            loadState = .failed(EventStoreError.repositoryUnavailable.localizedDescription)
            return
        }

        loadState = .loading
        presentationError = nil
        activeParticipant = nil
        activeRunID = nil
        hasSafetyConfirmation = false
        do {
            try await repository.markStaleRunsInterrupted(before: now())
            activeEvent = try await repository.loadActiveEvent()
            loadState = .ready
        } catch {
            let wrapped = EventStoreError.wrapped(error.localizedDescription)
            presentationError = wrapped
            loadState = .failed(wrapped.localizedDescription)
        }
    }

    func createEvent(_ draft: EventDraft) async throws -> UUID {
        let repository = try requireRepository()
        let title = try EventInputValidator.eventTitle(draft.title)
        let timeZone = try EventInputValidator.timeZone(draft.timeZoneIdentifier)
        let rules = ChallengeRulesV1.eventEdition
        let eventID = UUID()
        let createdAt = now()
        let snapshot = EventSnapshot(
            id: eventID,
            title: title,
            timeZoneIdentifier: timeZone,
            status: .draft,
            createdAt: createdAt,
            startedAt: nil,
            closedAt: nil,
            challengeID: rules.challengeID,
            scoringVersion: rules.scoringVersion,
            rulesData: try rules.encoded(),
            rulesDigest: try rules.digest(),
            maxOfficialAttempts: rules.maxOfficialAttempts
        )
        do {
            try await repository.createEvent(snapshot)
            activeEvent = snapshot
            presentationError = nil
            return eventID
        } catch {
            throw present(error)
        }
    }

    func activateEvent(id: UUID) async throws {
        let repository = try requireRepository()
        guard var event = try await repository.event(id: id) else { throw EventStoreError.noActiveEvent }
        guard event.status == .draft else { throw EventStoreError.eventNotDraft }
        event.status = .open
        event.startedAt = now()
        do {
            try await repository.updateEvent(event)
            activeEvent = event
            presentationError = nil
        } catch {
            throw present(error)
        }
    }

    func createParticipant(_ draft: ParticipantDraft) async throws -> UUID {
        let repository = try requireRepository()
        guard let event = activeEvent else { throw EventStoreError.noActiveEvent }
        guard event.status == .open else { throw EventStoreError.eventNotOpen }

        let alias = try EventInputValidator.alias(draft.alias)
        let normalized = EventInputValidator.normalizedAlias(alias)
        let candidates = try await repository.participantMatches(
            eventID: event.id,
            normalizedAlias: normalized
        )
        if !candidates.isEmpty {
            throw present(EventStoreError.existingPlayerName)
        }

        let participantID = UUID()
        let timestamp = now()
        let snapshot = ParticipantSnapshot(
            id: participantID,
            eventID: event.id,
            entryID: UUID(),
            alias: alias,
            normalizedAlias: normalized,
            avatarID: AvatarChoice.all.contains(where: { $0.id == draft.avatarID })
                ? draft.avatarID
                : AvatarChoice.all[0].id,
            stance: draft.stance,
            competitorNumber: try await repository.nextCompetitorNumber(eventID: event.id),
            isLeaderboardPublic: draft.isLeaderboardPublic,
            lessonCompletedAt: nil,
            coachOverrideAt: nil,
            createdAt: timestamp,
            lastSeenAt: timestamp,
            archived: false
        )
        do {
            try await repository.createParticipant(snapshot)
            activeParticipant = snapshot
            presentationError = nil
            return participantID
        } catch {
            throw present(error)
        }
    }

    func openParticipant(alias rawAlias: String) async throws -> UUID {
        let repository = try requireRepository()
        guard let event = activeEvent else { throw EventStoreError.noActiveEvent }
        let normalized = EventInputValidator.normalizedAlias(try EventInputValidator.alias(rawAlias))
        let candidates = try await repository.participantMatches(
            eventID: event.id,
            normalizedAlias: normalized
        )
        guard var match = candidates.first else {
            throw present(EventStoreError.participantNotFound)
        }

        match.lastSeenAt = now()
        try await repository.updateParticipant(match)
        activeParticipant = match
        presentationError = nil
        return match.id
    }

    func selectParticipant(id: UUID) async throws {
        let repository = try requireRepository()
        guard let event = activeEvent,
              let participant = try await repository.participant(id: id, eventID: event.id),
              !participant.archived
        else { throw EventStoreError.noActiveParticipant }
        activeParticipant = participant
        hasSafetyConfirmation = false
    }

    func setSafetyConfirmation(_ confirmed: Bool) {
        hasSafetyConfirmation = confirmed
    }

    func updateParticipantPrivacy(_ isPublic: Bool) async throws {
        let repository = try requireRepository()
        guard var participant = activeParticipant else { throw EventStoreError.noActiveParticipant }
        participant.isLeaderboardPublic = isPublic
        participant.lastSeenAt = now()
        try await repository.updateParticipant(participant)
        activeParticipant = participant
    }

    func updateParticipantStance(_ stance: Stance) async throws {
        let repository = try requireRepository()
        guard var participant = activeParticipant else { throw EventStoreError.noActiveParticipant }
        participant.stance = stance
        participant.lastSeenAt = now()
        try await repository.updateParticipant(participant)
        activeParticipant = participant
    }

    func markLessonCompleted() async throws {
        let repository = try requireRepository()
        guard var participant = activeParticipant else { throw EventStoreError.noActiveParticipant }
        participant.lessonCompletedAt = now()
        participant.lastSeenAt = now()
        try await repository.updateParticipant(participant)
        activeParticipant = participant
    }

    func beginRun(_ context: TrainingRunContext) async throws {
        let repository = try requireRepository()
        guard activeRunID == nil else { throw EventStoreError.wrapped("A training session is already active.") }
        do {
            try await repository.beginRun(context)
            activeRunID = context.runID
        } catch {
            throw present(error)
        }
    }

    func checkpoint(_ snapshot: RunCheckpoint) async throws {
        guard activeRunID == snapshot.runID else { throw EventStoreError.noActiveParticipant }
        do {
            try await requireRepository().checkpoint(snapshot)
        } catch {
            throw present(error)
        }
    }

    func finalizeRun(_ snapshot: TrainingRunSnapshot) async throws -> CommitOutcome {
        let repository = try requireRepository()
        pendingSave = PendingRunSnapshot(snapshot: snapshot, reason: "Awaiting durable commit")
        do {
            let outcome = try await repository.finalize(snapshot)
            pendingSave = PendingRunSnapshot(snapshot: snapshot, reason: "Updating recovery snapshot")
            do {
                try await writeRecovery(eventID: snapshot.eventID)
            } catch {
                presentationError = .recoveryFailed
                throw EventStoreError.recoveryFailed
            }
            pendingSave = nil
            activeRunID = nil
            presentationError = nil
            return outcome
        } catch let error as EventStoreError {
            throw error
        } catch {
            presentationError = .savePending
            throw EventStoreError.savePending
        }
    }

    func retryPendingSave() async throws -> CommitOutcome {
        guard let pendingSave else { throw EventStoreError.wrapped("There is no pending result.") }
        return try await finalizeRun(pendingSave.snapshot)
    }

    func run(id: UUID) async throws -> TrainingRunSnapshot? {
        try await requireRepository().run(id: id)
    }

    func runsForActiveParticipant() async throws -> [TrainingRunSnapshot] {
        guard let event = activeEvent, let participant = activeParticipant else {
            throw EventStoreError.noActiveParticipant
        }
        return try await requireRepository().runs(eventID: event.id)
            .filter { $0.participantID == participant.id }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func officialAttemptsRemaining() async throws -> Int {
        guard let event = activeEvent else { throw EventStoreError.noActiveEvent }
        let completed = try await runsForActiveParticipant().filter {
            $0.plan == .controlledOneTwoOfficial
                && $0.status == .completed
                && $0.officialOrdinal != nil
                && $0.endedAt <= (event.closedAt ?? .distantFuture)
        }.count
        return max(0, event.maxOfficialAttempts - completed)
    }

    func leaderboard(
        eventID: UUID,
        category: LeaderboardCategory
    ) async throws -> [LeaderboardEntry] {
        let repository = try requireRepository()
        guard let event = try await repository.event(id: eventID) else { throw EventStoreError.noActiveEvent }
        let entries = LeaderboardCalculator.standings(
            event: event,
            participants: try await repository.participants(eventID: eventID),
            runs: try await repository.runs(eventID: eventID),
            category: category
        )
        selectedLeaderboardCategory = category
        leaderboardEntries = entries
        return entries
    }

    func closeAndDeclareWinners(eventID: UUID) async throws -> [AwardSnapshot] {
        guard activeRunID == nil, pendingSave == nil else { throw EventStoreError.activeRunPreventsClosure }
        let repository = try requireRepository()
        guard var event = try await repository.event(id: eventID) else { throw EventStoreError.noActiveEvent }
        guard event.status == .open else { throw EventStoreError.eventNotOpen }
        let timestamp = now()
        event.status = .closed
        event.closedAt = timestamp
        let awards = LeaderboardCalculator.awards(
            event: event,
            participants: try await repository.participants(eventID: eventID),
            runs: try await repository.runs(eventID: eventID),
            declaredAt: timestamp
        )
        try await repository.closeEvent(event, awards: awards)
        activeEvent = event
        try await writeRecovery(eventID: eventID)
        return awards
    }

    func publicCSV(eventID: UUID) async throws -> String {
        let repository = try requireRepository()
        guard let event = try await repository.event(id: eventID) else { throw EventStoreError.noActiveEvent }
        let runs = try await repository.runs(eventID: eventID)
        let entries = LeaderboardCalculator.standings(
            event: event,
            participants: try await repository.participants(eventID: eventID),
            runs: runs,
            category: .overall
        )
        return EventExportBuilder.publicCSV(event: event, entries: entries, runs: runs)
    }

    func allEvents() async throws -> [EventSnapshot] {
        try await requireRepository().events()
    }

    func fullEventJSON(eventID: UUID) async throws -> Data {
        let repository = try requireRepository()
        guard let event = try await repository.event(id: eventID) else { throw EventStoreError.noActiveEvent }
        return try EventExportBuilder.fullEventJSON(
            event: event,
            participants: try await repository.participants(eventID: eventID),
            runs: try await repository.runs(eventID: eventID),
            awards: try await repository.awards(eventID: eventID)
        )
    }

    func clearActiveParticipant() {
        activeParticipant = nil
        activeRunID = nil
        pendingSave = nil
        hasSafetyConfirmation = false
        leaderboardEntries = []
        presentationError = nil
        handoffMessage = "Ready for the next participant"
    }

    func consumeHandoffMessage() {
        handoffMessage = nil
    }

    func clearPresentationError() {
        presentationError = nil
    }

    private func requireRepository() throws -> any TrainingRepository {
        guard let repository else { throw present(EventStoreError.repositoryUnavailable) }
        return repository
    }

    private func writeRecovery(eventID: UUID) async throws {
        guard let repository else { throw EventStoreError.repositoryUnavailable }
        guard repository.isPersistent else { return }
        guard let recoveryStore else { throw EventStoreError.recoveryFailed }
        guard let event = try await repository.event(id: eventID) else { throw EventStoreError.noActiveEvent }
        try await recoveryStore.write(EventRecoveryPayload(
            schemaVersion: 1,
            generatedAt: now(),
            event: event,
            participants: try await repository.participants(eventID: eventID),
            runs: try await repository.runs(eventID: eventID),
            awards: try await repository.awards(eventID: eventID)
        ))
    }

    @discardableResult
    private func present(_ error: Error) -> EventStoreError {
        let value = error as? EventStoreError ?? .wrapped(error.localizedDescription)
        presentationError = value
        return value
    }
}
