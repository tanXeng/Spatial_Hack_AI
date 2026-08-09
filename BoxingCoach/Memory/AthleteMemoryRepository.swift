import Foundation
import SwiftData

nonisolated enum AthleteMemoryRepositoryError: Error, Equatable, Sendable {
    case invalidEvent
    case activeEventExists
    case eventNotFound
    case eventClosed
    case participantEventMismatch
    case duplicateDisplayCode
    case participantNotFound
    case attemptParticipantMismatch
    case incompatibleProof
    case runNotFound
    case runParticipantMismatch
    case invalidRunTransition
    case submissionMismatch
    case awardMismatch
    case corruptData
    case saveFailed
}

@MainActor
protocol AthleteMemoryRepository: AnyObject {
    func activeEvent() throws -> EventEdition?
    func createEvent(_ event: EventEdition) throws -> EventEdition
    func archivedEvents() throws -> [EventEdition]
    func closeEvent(id: UUID, at date: Date) throws -> EventEdition

    func saveParticipant(_ participant: CompetitionPlayer) throws -> CompetitionPlayer
    func participant(eventID: UUID, displayCode: String) throws -> CompetitionPlayer?
    func participants(eventID: UUID) throws -> [CompetitionPlayer]

    func insertAttempt(_ attempt: TechniqueAttemptSnapshot) throws -> TechniqueAttemptSnapshot
    func attempts(for key: AthleteSkillMemoryKey) throws -> [TechniqueAttemptSnapshot]
    func memory(for key: AthleteSkillMemoryKey) throws -> AthleteSkillMemory?
    func rebuildMemory(for key: AthleteSkillMemoryKey) throws -> AthleteSkillMemory?

    func reserveRun(_ run: PendingTrainingRun) throws -> TrainingRunSnapshot
    func run(id: UUID) throws -> TrainingRunSnapshot?
    func startRun(id: UUID, at date: Date) throws -> TrainingRunSnapshot
    func completeRun(id: UUID, attemptID: UUID) throws -> TrainingRunSnapshot
    func commitRun(id: UUID, at date: Date) throws -> TrainingRunSnapshot
    func abortRun(id: UUID, at date: Date) throws -> TrainingRunSnapshot

    func submit(_ submission: CompetitionSubmission) throws -> CompetitionSubmission
    func submissions(eventID: UUID) throws -> [CompetitionSubmission]
    func saveAward(_ award: EventAward) throws -> EventAward
    func awards(eventID: UUID) throws -> [EventAward]
}

@MainActor
final class InMemoryAthleteMemoryRepository: AthleteMemoryRepository {
    private var events: [UUID: EventEdition] = [:]
    private var participantValues: [UUID: CompetitionPlayer] = [:]
    private var attemptValues: [UUID: TechniqueAttemptSnapshot] = [:]
    private var memoryValues: [AthleteSkillMemoryKey: AthleteSkillMemory] = [:]
    private var runValues: [UUID: TrainingRunSnapshot] = [:]
    private var submissionValues: [UUID: CompetitionSubmission] = [:]
    private var awardValues: [UUID: EventAward] = [:]

    func activeEvent() throws -> EventEdition? {
        events.values.first(where: \.isOpen)
    }

    func createEvent(_ event: EventEdition) throws -> EventEdition {
        if let existing = events[event.id] { return existing }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.invalidEvent }
        guard try activeEvent() == nil else {
            throw AthleteMemoryRepositoryError.activeEventExists
        }
        events[event.id] = event
        return event
    }

    func archivedEvents() throws -> [EventEdition] {
        events.values.filter { !$0.isOpen }.sorted(by: Self.eventOrder)
    }

    func closeEvent(id: UUID, at date: Date) throws -> EventEdition {
        guard let event = events[id] else { throw AthleteMemoryRepositoryError.eventNotFound }
        if !event.isOpen { return event }
        guard let closed = event.closing(at: date) else {
            throw AthleteMemoryRepositoryError.invalidEvent
        }
        events[id] = closed
        return closed
    }

    func saveParticipant(_ participant: CompetitionPlayer) throws -> CompetitionPlayer {
        let event = try openEvent(for: participant)
        guard event.id == participant.eventID else {
            throw AthleteMemoryRepositoryError.participantEventMismatch
        }
        if participantValues.values.contains(where: {
            $0.id != participant.id
                && $0.eventID == participant.eventID
                && $0.publicHandle?.displayCode == participant.publicHandle?.displayCode
        }) {
            throw AthleteMemoryRepositoryError.duplicateDisplayCode
        }
        participantValues[participant.id] = participant
        return participant
    }

    func participant(eventID: UUID, displayCode: String) throws -> CompetitionPlayer? {
        participantValues.values.first {
            $0.eventID == eventID && $0.publicHandle?.displayCode == displayCode
        }
    }

    func participants(eventID: UUID) throws -> [CompetitionPlayer] {
        participantValues.values.filter { $0.eventID == eventID }.sorted(by: Self.participantOrder)
    }

    func insertAttempt(_ attempt: TechniqueAttemptSnapshot) throws -> TechniqueAttemptSnapshot {
        if let existing = attemptValues[attempt.id] { return existing }
        let participant = try participantForAttempt(attempt)
        try validateProof(attempt)

        let key = try memoryKey(for: attempt)
        let proposedAttempts = Array(attemptValues.values) + [attempt]
        let rebuilt = AthleteSkillMemory.rebuilding(
            key: key,
            experienceLevel: participant.experienceLevel,
            from: proposedAttempts
        )
        attemptValues[attempt.id] = attempt
        memoryValues[key] = rebuilt
        return attempt
    }

    func attempts(for key: AthleteSkillMemoryKey) throws -> [TechniqueAttemptSnapshot] {
        attemptValues.values.filter { $0.memoryKey == key }.sorted(by: Self.attemptOrder)
    }

    func memory(for key: AthleteSkillMemoryKey) throws -> AthleteSkillMemory? {
        memoryValues[key]
    }

    func rebuildMemory(for key: AthleteSkillMemoryKey) throws -> AthleteSkillMemory? {
        guard let participant = participantValues[key.athleteID],
              participant.eventID == key.eventID
        else { throw AthleteMemoryRepositoryError.participantNotFound }
        let rebuilt = AthleteSkillMemory.rebuilding(
            key: key,
            experienceLevel: participant.experienceLevel,
            from: Array(attemptValues.values)
        )
        memoryValues[key] = rebuilt
        return rebuilt
    }

    func reserveRun(_ run: PendingTrainingRun) throws -> TrainingRunSnapshot {
        if let existing = runValues[run.id] { return existing }
        try validateRunOwner(run)
        guard let snapshot = TrainingRunSnapshot(run) else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        runValues[run.id] = snapshot
        return snapshot
    }

    func run(id: UUID) throws -> TrainingRunSnapshot? { runValues[id] }

    func startRun(id: UUID, at date: Date) throws -> TrainingRunSnapshot {
        guard let existing = runValues[id] else {
            throw AthleteMemoryRepositoryError.runNotFound
        }
        guard let updated = existing.starting(at: date) else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        runValues[id] = updated
        return updated
    }

    func completeRun(id: UUID, attemptID: UUID) throws -> TrainingRunSnapshot {
        guard let existing = runValues[id] else {
            throw AthleteMemoryRepositoryError.runNotFound
        }
        guard let attempt = attemptValues[attemptID],
              let updated = existing.completing(with: attempt)
        else { throw AthleteMemoryRepositoryError.invalidRunTransition }
        runValues[id] = updated
        return updated
    }

    func commitRun(id: UUID, at date: Date) throws -> TrainingRunSnapshot {
        guard let existing = runValues[id] else {
            throw AthleteMemoryRepositoryError.runNotFound
        }
        guard let updated = existing.committing(at: date) else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        runValues[id] = updated
        return updated
    }

    func abortRun(id: UUID, at date: Date) throws -> TrainingRunSnapshot {
        guard let existing = runValues[id] else {
            throw AthleteMemoryRepositoryError.runNotFound
        }
        guard let updated = existing.aborting(at: date) else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        runValues[id] = updated
        return updated
    }

    func submit(_ submission: CompetitionSubmission) throws -> CompetitionSubmission {
        if let existing = submissionValues[submission.id] { return existing }
        try validateSubmission(submission)
        submissionValues[submission.id] = submission
        return submission
    }

    func submissions(eventID: UUID) throws -> [CompetitionSubmission] {
        submissionValues.values.filter { $0.eventID == eventID }.sorted(by: Self.submissionOrder)
    }

    func saveAward(_ award: EventAward) throws -> EventAward {
        if let existing = awardValues[award.id] { return existing }
        try validateAward(award)
        awardValues[award.id] = award
        return award
    }

    func awards(eventID: UUID) throws -> [EventAward] {
        awardValues.values.filter { $0.eventID == eventID }.sorted(by: Self.awardOrder)
    }

    private func openEvent(for participant: CompetitionPlayer) throws -> EventEdition {
        guard let eventID = participant.eventID,
              let event = events[eventID]
        else { throw AthleteMemoryRepositoryError.participantEventMismatch }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
        return event
    }

    private func participantForAttempt(
        _ attempt: TechniqueAttemptSnapshot
    ) throws -> CompetitionPlayer {
        guard let participant = participantValues[attempt.athleteID] else {
            throw AthleteMemoryRepositoryError.participantNotFound
        }
        guard let eventID = attempt.eventID,
              participant.eventID == eventID,
              attempt.publicHandleSnapshot == participant.publicHandle
        else { throw AthleteMemoryRepositoryError.attemptParticipantMismatch }
        guard let event = events[eventID] else {
            throw AthleteMemoryRepositoryError.eventNotFound
        }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
        return participant
    }

    private func validateProof(_ attempt: TechniqueAttemptSnapshot) throws {
        guard attempt.stage == .retest else { return }
        guard let baselineID = attempt.baselineAttemptID,
              let baseline = attemptValues[baselineID],
              baseline.stage == .baseline,
              baseline.isValid,
              baseline.memoryKey == attempt.memoryKey,
              baseline.coachingCycleID == attempt.coachingCycleID,
              baseline.hasCompatibleMetricAvailability(with: attempt),
              baseline.correctionCode == attempt.correctionCode,
              baseline.completedAt <= attempt.completedAt
        else { throw AthleteMemoryRepositoryError.incompatibleProof }
    }

    private func memoryKey(
        for attempt: TechniqueAttemptSnapshot
    ) throws -> AthleteSkillMemoryKey {
        guard let key = attempt.memoryKey else {
            throw AthleteMemoryRepositoryError.attemptParticipantMismatch
        }
        return key
    }

    private func validateRunOwner(_ run: PendingTrainingRun) throws {
        guard let eventID = run.eventID,
              let participant = participantValues[run.athleteID],
              participant.eventID == eventID
        else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
        guard let event = events[eventID] else {
            throw AthleteMemoryRepositoryError.eventNotFound
        }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
    }

    private func validateSubmission(_ submission: CompetitionSubmission) throws {
        guard let eventID = submission.eventID,
              let event = events[eventID],
              let participant = participantValues[submission.playerID],
              participant.eventID == eventID,
              submission.publicHandleSnapshot == participant.publicHandle,
              submission.scoringVersion == event.scoringVersion,
              submission.calibrationVersion == participant.calibrationVersion,
              submission.trackingStatus == .complete
        else { throw AthleteMemoryRepositoryError.submissionMismatch }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
    }

    private func validateAward(_ award: EventAward) throws {
        guard events[award.eventID] != nil,
              let participant = participantValues[award.athleteID],
              participant.eventID == award.eventID,
              award.publicHandleSnapshot == participant.publicHandle
        else { throw AthleteMemoryRepositoryError.awardMismatch }
        if let attemptID = award.attemptID {
            guard let attempt = attemptValues[attemptID],
                  attempt.athleteID == award.athleteID,
                  attempt.eventID == award.eventID,
                  attempt.completedAt <= award.awardedAt
            else { throw AthleteMemoryRepositoryError.awardMismatch }
        }
    }

    private static func eventOrder(_ lhs: EventEdition, _ rhs: EventEdition) -> Bool {
        if lhs.openedAt != rhs.openedAt { return lhs.openedAt > rhs.openedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func participantOrder(
        _ lhs: CompetitionPlayer,
        _ rhs: CompetitionPlayer
    ) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private static func attemptOrder(
        _ lhs: TechniqueAttemptSnapshot,
        _ rhs: TechniqueAttemptSnapshot
    ) -> Bool {
        if lhs.completedAt != rhs.completedAt { return lhs.completedAt < rhs.completedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func submissionOrder(
        _ lhs: CompetitionSubmission,
        _ rhs: CompetitionSubmission
    ) -> Bool {
        if lhs.endedAt != rhs.endedAt { return lhs.endedAt > rhs.endedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func awardOrder(_ lhs: EventAward, _ rhs: EventAward) -> Bool {
        if lhs.awardedAt != rhs.awardedAt { return lhs.awardedAt < rhs.awardedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

@MainActor
final class SwiftDataAthleteMemoryRepository: AthleteMemoryRepository {
    let container: ModelContainer
    private var context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        context = Self.makeContext(container: container)
    }

    func activeEvent() throws -> EventEdition? {
        try eventRecords().compactMap(\.snapshot).first(where: \.isOpen)
    }

    func createEvent(_ event: EventEdition) throws -> EventEdition {
        if let existing = try eventRecord(id: event.id)?.snapshot { return existing }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.invalidEvent }
        guard try activeEvent() == nil else {
            throw AthleteMemoryRepositoryError.activeEventExists
        }
        context.insert(CompetitionSchemaV2.EventEditionRecord(event))
        try saveContext()
        return event
    }

    func archivedEvents() throws -> [EventEdition] {
        try eventRecords().compactMap(\.snapshot).filter { !$0.isOpen }.sorted {
            if $0.openedAt != $1.openedAt { return $0.openedAt > $1.openedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func closeEvent(id: UUID, at date: Date) throws -> EventEdition {
        guard let record = try eventRecord(id: id),
              let event = record.snapshot
        else { throw AthleteMemoryRepositoryError.eventNotFound }
        if !event.isOpen { return event }
        guard let closed = event.closing(at: date) else {
            throw AthleteMemoryRepositoryError.invalidEvent
        }
        record.statusRawValue = closed.status.rawValue
        record.closedAt = closed.closedAt
        try saveContext()
        return closed
    }

    func saveParticipant(_ participant: CompetitionPlayer) throws -> CompetitionPlayer {
        guard let eventID = participant.eventID,
              let event = try eventRecord(id: eventID)?.snapshot
        else { throw AthleteMemoryRepositoryError.participantEventMismatch }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }

        let records = try participantRecords()
        if records.contains(where: {
            $0.id != participant.id
                && $0.eventID == eventID
                && $0.publicDisplayCode == participant.publicHandle?.displayCode
        }) {
            throw AthleteMemoryRepositoryError.duplicateDisplayCode
        }
        if let existing = records.first(where: { $0.id == participant.id }) {
            guard existing.eventID == eventID else {
                throw AthleteMemoryRepositoryError.participantEventMismatch
            }
            existing.apply(participant)
        } else {
            context.insert(CompetitionSchemaV2.CompetitionPlayerRecord(participant))
        }
        try saveContext()
        return participant
    }

    func participant(eventID: UUID, displayCode: String) throws -> CompetitionPlayer? {
        try participantRecords().first {
            $0.eventID == eventID && $0.publicDisplayCode == displayCode
        }?.snapshot
    }

    func participants(eventID: UUID) throws -> [CompetitionPlayer] {
        try participantRecords().filter { $0.eventID == eventID }.map(\.snapshot).sorted {
            $0.id.uuidString < $1.id.uuidString
        }
    }

    func insertAttempt(_ attempt: TechniqueAttemptSnapshot) throws -> TechniqueAttemptSnapshot {
        if let existing = try attemptRecord(id: attempt.id) {
            guard let snapshot = existing.snapshot else {
                throw AthleteMemoryRepositoryError.corruptData
            }
            return snapshot
        }
        let participant = try participantForAttempt(attempt)
        try validateProof(attempt)
        guard let key = attempt.memoryKey else {
            throw AthleteMemoryRepositoryError.attemptParticipantMismatch
        }

        let record = CompetitionSchemaV2.TechniqueAttemptRecord(attempt)
        guard record.snapshot == attempt else {
            throw AthleteMemoryRepositoryError.corruptData
        }
        let proposedAttempts = try attemptSnapshots() + [attempt]
        let rebuilt = AthleteSkillMemory.rebuilding(
            key: key,
            experienceLevel: participant.experienceLevel,
            from: proposedAttempts
        )
        context.insert(record)
        try applyMemory(rebuilt, for: key)
        try saveContext()
        return attempt
    }

    func attempts(for key: AthleteSkillMemoryKey) throws -> [TechniqueAttemptSnapshot] {
        try attemptSnapshots().filter { $0.memoryKey == key }.sorted(by: Self.attemptOrder)
    }

    func memory(for key: AthleteSkillMemoryKey) throws -> AthleteSkillMemory? {
        guard let record = try memoryRecord(key: key) else { return nil }
        guard let snapshot = record.snapshot(attempts: try attempts(for: key)) else {
            throw AthleteMemoryRepositoryError.corruptData
        }
        return snapshot
    }

    func rebuildMemory(for key: AthleteSkillMemoryKey) throws -> AthleteSkillMemory? {
        guard let participant = try participantRecord(id: key.athleteID)?.snapshot,
              participant.eventID == key.eventID
        else { throw AthleteMemoryRepositoryError.participantNotFound }
        let rebuilt = AthleteSkillMemory.rebuilding(
            key: key,
            experienceLevel: participant.experienceLevel,
            from: try attemptSnapshots()
        )
        try applyMemory(rebuilt, for: key)
        try saveContext()
        return rebuilt
    }

    func reserveRun(_ run: PendingTrainingRun) throws -> TrainingRunSnapshot {
        if let existing = try runRecord(id: run.id) {
            guard let snapshot = existing.runSnapshot else {
                throw AthleteMemoryRepositoryError.corruptData
            }
            return snapshot
        }
        try validateRunOwner(run)
        let record = CompetitionSchemaV2.PendingTrainingRunRecord(run)
        guard let snapshot = record.runSnapshot else {
            throw AthleteMemoryRepositoryError.corruptData
        }
        context.insert(record)
        try saveContext()
        return snapshot
    }

    func run(id: UUID) throws -> TrainingRunSnapshot? {
        guard let record = try runRecord(id: id) else { return nil }
        guard let snapshot = record.runSnapshot else {
            throw AthleteMemoryRepositoryError.corruptData
        }
        return snapshot
    }

    func startRun(id: UUID, at date: Date) throws -> TrainingRunSnapshot {
        try updateRun(id: id) { $0.starting(at: date) }
    }

    func completeRun(id: UUID, attemptID: UUID) throws -> TrainingRunSnapshot {
        guard let attempt = try attemptRecord(id: attemptID)?.snapshot else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        return try updateRun(id: id) { $0.completing(with: attempt) }
    }

    func commitRun(id: UUID, at date: Date) throws -> TrainingRunSnapshot {
        try updateRun(id: id) { $0.committing(at: date) }
    }

    func abortRun(id: UUID, at date: Date) throws -> TrainingRunSnapshot {
        try updateRun(id: id) { $0.aborting(at: date) }
    }

    func submit(_ submission: CompetitionSubmission) throws -> CompetitionSubmission {
        if let existing = try submissionRecord(id: submission.id) {
            guard let snapshot = existing.snapshot else {
                throw AthleteMemoryRepositoryError.corruptData
            }
            return snapshot
        }
        try validateSubmission(submission)
        context.insert(CompetitionSchemaV2.CompetitionSubmissionRecord(submission))
        try saveContext()
        return submission
    }

    func submissions(eventID: UUID) throws -> [CompetitionSubmission] {
        try submissionRecords().compactMap(\.snapshot).filter { $0.eventID == eventID }.sorted {
            if $0.endedAt != $1.endedAt { return $0.endedAt > $1.endedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func saveAward(_ award: EventAward) throws -> EventAward {
        if let existing = try awardRecord(id: award.id) {
            guard let snapshot = existing.snapshot else {
                throw AthleteMemoryRepositoryError.corruptData
            }
            return snapshot
        }
        try validateAward(award)
        context.insert(CompetitionSchemaV2.EventAwardRecord(award))
        try saveContext()
        return award
    }

    func awards(eventID: UUID) throws -> [EventAward] {
        try awardRecords().compactMap(\.snapshot).filter { $0.eventID == eventID }.sorted {
            if $0.awardedAt != $1.awardedAt { return $0.awardedAt < $1.awardedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func eventRecords() throws -> [CompetitionSchemaV2.EventEditionRecord] {
        try context.fetch(FetchDescriptor<CompetitionSchemaV2.EventEditionRecord>())
    }

    private func eventRecord(id: UUID) throws -> CompetitionSchemaV2.EventEditionRecord? {
        try eventRecords().first { $0.id == id }
    }

    private func participantRecords() throws -> [CompetitionSchemaV2.CompetitionPlayerRecord] {
        try context.fetch(FetchDescriptor<CompetitionSchemaV2.CompetitionPlayerRecord>())
    }

    private func participantRecord(
        id: UUID
    ) throws -> CompetitionSchemaV2.CompetitionPlayerRecord? {
        try participantRecords().first { $0.id == id }
    }

    private func attemptRecords() throws -> [CompetitionSchemaV2.TechniqueAttemptRecord] {
        try context.fetch(FetchDescriptor<CompetitionSchemaV2.TechniqueAttemptRecord>())
    }

    private func attemptRecord(
        id: UUID
    ) throws -> CompetitionSchemaV2.TechniqueAttemptRecord? {
        try attemptRecords().first { $0.id == id }
    }

    private func attemptSnapshots() throws -> [TechniqueAttemptSnapshot] {
        try attemptRecords().map { record in
            guard let snapshot = record.snapshot else {
                throw AthleteMemoryRepositoryError.corruptData
            }
            return snapshot
        }
    }

    private func memoryRecords() throws -> [CompetitionSchemaV2.AthleteSkillMemoryRecord] {
        try context.fetch(FetchDescriptor<CompetitionSchemaV2.AthleteSkillMemoryRecord>())
    }

    private func memoryRecord(
        key: AthleteSkillMemoryKey
    ) throws -> CompetitionSchemaV2.AthleteSkillMemoryRecord? {
        try memoryRecords().first { $0.id == key.storageKey }
    }

    private func runRecords() throws -> [CompetitionSchemaV2.PendingTrainingRunRecord] {
        try context.fetch(FetchDescriptor<CompetitionSchemaV2.PendingTrainingRunRecord>())
    }

    private func runRecord(id: UUID) throws -> CompetitionSchemaV2.PendingTrainingRunRecord? {
        try runRecords().first { $0.id == id }
    }

    private func submissionRecords() throws -> [CompetitionSchemaV2.CompetitionSubmissionRecord] {
        try context.fetch(FetchDescriptor<CompetitionSchemaV2.CompetitionSubmissionRecord>())
    }

    private func submissionRecord(
        id: UUID
    ) throws -> CompetitionSchemaV2.CompetitionSubmissionRecord? {
        try submissionRecords().first { $0.id == id }
    }

    private func awardRecords() throws -> [CompetitionSchemaV2.EventAwardRecord] {
        try context.fetch(FetchDescriptor<CompetitionSchemaV2.EventAwardRecord>())
    }

    private func awardRecord(id: UUID) throws -> CompetitionSchemaV2.EventAwardRecord? {
        try awardRecords().first { $0.id == id }
    }

    private func applyMemory(
        _ memory: AthleteSkillMemory?,
        for key: AthleteSkillMemoryKey
    ) throws {
        if let memory {
            if let existing = try memoryRecord(key: key) {
                try existing.apply(memory)
            } else {
                context.insert(try CompetitionSchemaV2.AthleteSkillMemoryRecord(memory))
            }
        } else if let existing = try memoryRecord(key: key) {
            context.delete(existing)
        }
    }

    private func participantForAttempt(
        _ attempt: TechniqueAttemptSnapshot
    ) throws -> CompetitionPlayer {
        guard let participant = try participantRecord(id: attempt.athleteID)?.snapshot else {
            throw AthleteMemoryRepositoryError.participantNotFound
        }
        guard let eventID = attempt.eventID,
              participant.eventID == eventID,
              attempt.publicHandleSnapshot == participant.publicHandle
        else { throw AthleteMemoryRepositoryError.attemptParticipantMismatch }
        guard let event = try eventRecord(id: eventID)?.snapshot else {
            throw AthleteMemoryRepositoryError.eventNotFound
        }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
        return participant
    }

    private func validateProof(_ attempt: TechniqueAttemptSnapshot) throws {
        guard attempt.stage == .retest else { return }
        guard let baselineID = attempt.baselineAttemptID,
              let baseline = try attemptRecord(id: baselineID)?.snapshot,
              baseline.stage == .baseline,
              baseline.isValid,
              baseline.memoryKey == attempt.memoryKey,
              baseline.coachingCycleID == attempt.coachingCycleID,
              baseline.hasCompatibleMetricAvailability(with: attempt),
              baseline.correctionCode == attempt.correctionCode,
              baseline.completedAt <= attempt.completedAt
        else { throw AthleteMemoryRepositoryError.incompatibleProof }
    }

    private func validateRunOwner(_ run: PendingTrainingRun) throws {
        guard let eventID = run.eventID,
              let participant = try participantRecord(id: run.athleteID)?.snapshot,
              participant.eventID == eventID
        else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
        guard let event = try eventRecord(id: eventID)?.snapshot else {
            throw AthleteMemoryRepositoryError.eventNotFound
        }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
    }

    private func updateRun(
        id: UUID,
        transition: (TrainingRunSnapshot) -> TrainingRunSnapshot?
    ) throws -> TrainingRunSnapshot {
        guard let record = try runRecord(id: id) else {
            throw AthleteMemoryRepositoryError.runNotFound
        }
        guard let current = record.runSnapshot else {
            throw AthleteMemoryRepositoryError.corruptData
        }
        guard let updated = transition(current) else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        try record.apply(updated)
        try saveContext()
        return updated
    }

    private func validateSubmission(_ submission: CompetitionSubmission) throws {
        guard let eventID = submission.eventID,
              let event = try eventRecord(id: eventID)?.snapshot,
              let participant = try participantRecord(id: submission.playerID)?.snapshot,
              participant.eventID == eventID,
              submission.publicHandleSnapshot == participant.publicHandle,
              submission.scoringVersion == event.scoringVersion,
              submission.calibrationVersion == participant.calibrationVersion,
              submission.trackingStatus == .complete
        else { throw AthleteMemoryRepositoryError.submissionMismatch }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
    }

    private func validateAward(_ award: EventAward) throws {
        guard try eventRecord(id: award.eventID) != nil,
              let participant = try participantRecord(id: award.athleteID)?.snapshot,
              participant.eventID == award.eventID,
              award.publicHandleSnapshot == participant.publicHandle
        else { throw AthleteMemoryRepositoryError.awardMismatch }
        if let attemptID = award.attemptID {
            guard let attempt = try attemptRecord(id: attemptID)?.snapshot,
                  attempt.athleteID == award.athleteID,
                  attempt.eventID == award.eventID,
                  attempt.completedAt <= award.awardedAt
            else { throw AthleteMemoryRepositoryError.awardMismatch }
        }
    }

    private func saveContext() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            context = Self.makeContext(container: container)
            throw AthleteMemoryRepositoryError.saveFailed
        }
    }

    private static func makeContext(container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private static func attemptOrder(
        _ lhs: TechniqueAttemptSnapshot,
        _ rhs: TechniqueAttemptSnapshot
    ) -> Bool {
        if lhs.completedAt != rhs.completedAt { return lhs.completedAt < rhs.completedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
