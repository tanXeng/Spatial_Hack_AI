import Foundation

nonisolated enum TrainingRepositoryError: LocalizedError, Equatable, Sendable {
    case eventNotFound
    case participantNotFound
    case runNotFound
    case activeEventAlreadyExists
    case eventIsNotDraft
    case eventIsClosed
    case duplicateRun
    case finalizedRunCannotChange
    case corruptedSnapshot
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .eventNotFound: return "The event could not be found."
        case .participantNotFound: return "The participant could not be found."
        case .runNotFound: return "The training run could not be found."
        case .activeEventAlreadyExists: return "Another competition is already open."
        case .eventIsNotDraft: return "Only a draft event can be opened."
        case .eventIsClosed: return "This competition is closed."
        case .duplicateRun: return "That training run already exists."
        case .finalizedRunCannotChange: return "A finalized result cannot be changed."
        case .corruptedSnapshot: return "A saved training snapshot could not be read."
        case .saveFailed(let message): return message
        }
    }
}

@MainActor
protocol TrainingRepository: AnyObject {
    var isPersistent: Bool { get }

    func loadActiveEvent() async throws -> EventSnapshot?
    func events() async throws -> [EventSnapshot]
    func event(id: UUID) async throws -> EventSnapshot?
    func createEvent(_ snapshot: EventSnapshot) async throws
    func updateEvent(_ snapshot: EventSnapshot) async throws

    func nextCompetitorNumber(eventID: UUID) async throws -> Int
    func createParticipant(_ snapshot: ParticipantSnapshot) async throws
    func updateParticipant(_ snapshot: ParticipantSnapshot) async throws
    func participant(id: UUID, eventID: UUID) async throws -> ParticipantSnapshot?
    func participantMatches(eventID: UUID, normalizedAlias: String) async throws -> [ParticipantSnapshot]
    func participants(eventID: UUID) async throws -> [ParticipantSnapshot]

    func beginRun(_ context: TrainingRunContext) async throws
    func checkpoint(_ checkpoint: RunCheckpoint) async throws
    func finalize(_ snapshot: TrainingRunSnapshot) async throws -> CommitOutcome
    func run(id: UUID) async throws -> TrainingRunSnapshot?
    func runs(eventID: UUID) async throws -> [TrainingRunSnapshot]
    func markStaleRunsInterrupted(before cutoff: Date) async throws

    func awards(eventID: UUID) async throws -> [AwardSnapshot]
    func replaceAwards(eventID: UUID, with awards: [AwardSnapshot]) async throws
    func closeEvent(_ event: EventSnapshot, awards: [AwardSnapshot]) async throws
}
