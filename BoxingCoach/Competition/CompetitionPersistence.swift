import Foundation
import SwiftData

private nonisolated func stableAttemptOrder(
    _ lhs: TechniqueAttemptSnapshot,
    _ rhs: TechniqueAttemptSnapshot
) -> Bool {
    if lhs.completedAt != rhs.completedAt { return lhs.completedAt < rhs.completedAt }
    if lhs.coachingCycleID == rhs.coachingCycleID, lhs.stage != rhs.stage {
        return lhs.stage == .baseline
    }
    if lhs.coachingCycleID == rhs.coachingCycleID,
       lhs.cycleOrdinal != rhs.cycleOrdinal {
        return (lhs.cycleOrdinal ?? .max) < (rhs.cycleOrdinal ?? .max)
    }
    return lhs.id.uuidString < rhs.id.uuidString
}

nonisolated enum CompetitionRepositoryError: LocalizedError, Equatable, Sendable {
    case playerNotFound
    case invalidSubmission
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .playerNotFound: return "The player could not be found."
        case .invalidSubmission: return "That competition result could not be saved."
        case .saveFailed(let message): return message
        }
    }
}

@MainActor
protocol CompetitionRepository: AnyObject {
    // Sole production persistence façade. Event selection, participant identity, competition
    // results, and coaching memory share one actor-isolated repository/context.
    func activeEvent() async throws -> EventEdition?
    func create(event: EventEdition) async throws -> EventEdition
    func closeEvent(id: UUID, at date: Date) async throws -> EventEdition
    func participants(eventID: UUID) async throws -> [CompetitionPlayer]
    func participant(eventID: UUID, displayCode: String) async throws -> CompetitionPlayer?
    func createParticipant(
        eventID: UUID,
        displayName: String,
        experienceLevel: ExperienceLevel,
        stance: Stance,
        at date: Date
    ) async throws -> CompetitionPlayer
    func saveParticipant(_ participant: CompetitionPlayer) async throws -> CompetitionPlayer
    func player(normalizedName: String) async throws -> CompetitionPlayer?
    func player(id: UUID) async throws -> CompetitionPlayer?
    func save(player: CompetitionPlayer) async throws
    func submit(_ submission: CompetitionSubmission) async throws -> CompetitionSubmission
    func submissions() async throws -> [CompetitionSubmission]
    func submissions(eventID: UUID) async throws -> [CompetitionSubmission]
    func save(techniqueAttempts: [TechniqueAttemptSnapshot]) async throws
    func techniqueAttempts(athleteID: UUID, techniqueID: String) async throws
        -> [TechniqueAttemptSnapshot]
    func save(skillMemory: AthleteSkillMemory) async throws
    func skillMemory(athleteID: UUID, techniqueID: String) async throws
        -> AthleteSkillMemory?
    func save(coachingCycle transaction: CoachingCycleMemoryTransaction) async throws
    func coachingCycle(id: UUID) async throws -> CoachingCycleSnapshot?
    func reserveTrainingRun(
        _ run: PendingTrainingRun,
        descriptor: DurableTrainingRunDescriptor
    ) async throws -> TrainingRunSnapshot
    func trainingRunDescriptor(id: UUID) async throws -> DurableTrainingRunDescriptor?
    func isAuraResultDeliveryAcknowledged(runID: UUID) async throws -> Bool
    func acknowledgeAuraResultDelivery(runID: UUID, at date: Date) async throws
    func trainingRun(id: UUID) async throws -> TrainingRunSnapshot?
    func trainingRuns() async throws -> [TrainingRunSnapshot]
    func activateTrainingRun(id: UUID, at date: Date) async throws -> TrainingRunSnapshot
    func stageCoachingCycle(
        runID: UUID,
        transaction: CoachingCycleMemoryTransaction
    ) async throws -> TrainingRunSnapshot
    func commitCoachingCycle(runID: UUID, at date: Date) async throws -> TrainingRunSnapshot
    func abortTrainingRun(id: UUID, at date: Date) async throws -> TrainingRunSnapshot
    func reset() async throws
}

@MainActor
extension CompetitionRepository {
    func reserveTrainingRun(_ run: PendingTrainingRun) async throws -> TrainingRunSnapshot {
        try await reserveTrainingRun(run, descriptor: .legacy(runID: run.id))
    }
    func activeEvent() async throws -> EventEdition? { nil }

    func create(event: EventEdition) async throws -> EventEdition {
        _ = event
        throw CompetitionRepositoryError.saveFailed("Event persistence is unavailable.")
    }

    func closeEvent(id: UUID, at date: Date) async throws -> EventEdition {
        _ = id
        _ = date
        throw CompetitionRepositoryError.saveFailed("Event persistence is unavailable.")
    }

    func participants(eventID: UUID) async throws -> [CompetitionPlayer] {
        _ = eventID
        return []
    }

    func participant(eventID: UUID, displayCode: String) async throws -> CompetitionPlayer? {
        _ = eventID
        _ = displayCode
        return nil
    }

    func createParticipant(
        eventID: UUID,
        displayName: String,
        experienceLevel: ExperienceLevel,
        stance: Stance,
        at date: Date
    ) async throws -> CompetitionPlayer {
        _ = eventID
        _ = displayName
        _ = experienceLevel
        _ = stance
        _ = date
        throw CompetitionRepositoryError.saveFailed("Event participant creation is unavailable.")
    }

    func saveParticipant(_ participant: CompetitionPlayer) async throws -> CompetitionPlayer {
        try await save(player: participant)
        return participant
    }

    func submissions(eventID: UUID) async throws -> [CompetitionSubmission] {
        try await submissions().filter { $0.eventID == eventID }
    }

    func save(coachingCycle transaction: CoachingCycleMemoryTransaction) async throws {
        _ = transaction
        throw CompetitionRepositoryError.saveFailed("Coaching-cycle persistence is unavailable.")
    }

    func coachingCycle(id: UUID) async throws -> CoachingCycleSnapshot? {
        _ = id
        return nil
    }

    func reserveTrainingRun(
        _ run: PendingTrainingRun,
        descriptor: DurableTrainingRunDescriptor
    ) async throws -> TrainingRunSnapshot {
        _ = run
        _ = descriptor
        throw CompetitionRepositoryError.saveFailed("Training-run persistence is unavailable.")
    }

    func trainingRunDescriptor(id: UUID) async throws -> DurableTrainingRunDescriptor? {
        _ = id
        return nil
    }

    func isAuraResultDeliveryAcknowledged(runID: UUID) async throws -> Bool {
        _ = runID
        return false
    }

    func acknowledgeAuraResultDelivery(runID: UUID, at date: Date) async throws {
        _ = runID
        _ = date
        throw CompetitionRepositoryError.saveFailed("Result acknowledgement persistence is unavailable.")
    }

    func trainingRun(id: UUID) async throws -> TrainingRunSnapshot? {
        _ = id
        return nil
    }

    func trainingRuns() async throws -> [TrainingRunSnapshot] { [] }

    func activateTrainingRun(id: UUID, at date: Date) async throws -> TrainingRunSnapshot {
        _ = id
        _ = date
        throw CompetitionRepositoryError.saveFailed("Training-run persistence is unavailable.")
    }

    func stageCoachingCycle(
        runID: UUID,
        transaction: CoachingCycleMemoryTransaction
    ) async throws -> TrainingRunSnapshot {
        _ = runID
        _ = transaction
        throw CompetitionRepositoryError.saveFailed("Training-run persistence is unavailable.")
    }

    func commitCoachingCycle(runID: UUID, at date: Date) async throws -> TrainingRunSnapshot {
        _ = runID
        _ = date
        throw CompetitionRepositoryError.saveFailed("Training-run persistence is unavailable.")
    }

    func abortTrainingRun(id: UUID, at date: Date) async throws -> TrainingRunSnapshot {
        _ = id
        _ = date
        throw CompetitionRepositoryError.saveFailed("Training-run persistence is unavailable.")
    }
}

@MainActor
final class InMemoryCompetitionRepository: CompetitionRepository {
    private var events: [UUID: EventEdition] = [:]
    private var players: [UUID: CompetitionPlayer] = [:]
    private var values: [UUID: CompetitionSubmission] = [:]
    private var attemptValues: [UUID: TechniqueAttemptSnapshot] = [:]
    private var memoryValues: [String: AthleteSkillMemory] = [:]
    private var coachingCycleValues: [UUID: CoachingCycleSnapshot] = [:]
    private var trainingRunValues: [UUID: TrainingRunSnapshot] = [:]
    private var stagedCoachingCycles: [UUID: CoachingCycleMemoryTransaction] = [:]
    private var trainingRunDescriptors: [UUID: DurableTrainingRunDescriptor] = [:]
    private var acknowledgedAuraResultIDs: Set<UUID> = []

    func activeEvent() async throws -> EventEdition? {
        events.values.first(where: \.isOpen)
    }

    func create(event: EventEdition) async throws -> EventEdition {
        if let existing = events[event.id] { return existing }
        guard event.isOpen, events.values.allSatisfy({ !$0.isOpen }) else {
            throw AthleteMemoryRepositoryError.activeEventExists
        }
        events[event.id] = event
        return event
    }

    func closeEvent(id: UUID, at date: Date) async throws -> EventEdition {
        guard let event = events[id] else { throw AthleteMemoryRepositoryError.eventNotFound }
        if !event.isOpen { return event }
        guard let closed = event.closing(at: date) else {
            throw AthleteMemoryRepositoryError.invalidEvent
        }
        events[id] = closed
        return closed
    }

    func participants(eventID: UUID) async throws -> [CompetitionPlayer] {
        players.values
            .filter { $0.eventID == eventID }
            .sorted { ($0.publicHandle?.displayCode ?? "") < ($1.publicHandle?.displayCode ?? "") }
    }

    func participant(eventID: UUID, displayCode: String) async throws -> CompetitionPlayer? {
        players.values.first {
            $0.eventID == eventID && $0.publicHandle?.displayCode == displayCode
        }
    }

    func createParticipant(
        eventID: UUID,
        displayName: String,
        experienceLevel: ExperienceLevel,
        stance: Stance,
        at date: Date
    ) async throws -> CompetitionPlayer {
        guard let event = events[eventID] else {
            throw AthleteMemoryRepositoryError.eventNotFound
        }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
        let name = try CompetitionName.display(displayName)
        guard let handle = ParticipantPublicHandle.allocating(
            eventID: eventID,
            displayName: name,
            against: players.values.compactMap(\.publicHandle)
        ) else { throw AthleteMemoryRepositoryError.duplicateDisplayCode }
        let participant = CompetitionPlayer(
            id: UUID(), name: name, normalizedName: CompetitionName.normalized(name),
            rememberedStance: stance, reach: nil, calibrationVersion: nil,
            calibratedAt: nil, createdAt: date, lastSeenAt: date,
            experienceLevel: experienceLevel, publicHandle: handle
        )
        players[participant.id] = participant
        return participant
    }

    func saveParticipant(_ participant: CompetitionPlayer) async throws -> CompetitionPlayer {
        guard let eventID = participant.eventID,
              let event = events[eventID]
        else { throw AthleteMemoryRepositoryError.eventNotFound }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
        if players.values.contains(where: {
            $0.id != participant.id
                && $0.eventID == eventID
                && $0.publicHandle?.displayCode == participant.publicHandle?.displayCode
        }) {
            throw AthleteMemoryRepositoryError.duplicateDisplayCode
        }
        players[participant.id] = participant
        return participant
    }

    func player(normalizedName: String) async throws -> CompetitionPlayer? {
        players.values.first { $0.normalizedName == normalizedName }
    }

    func player(id: UUID) async throws -> CompetitionPlayer? { players[id] }

    func save(player: CompetitionPlayer) async throws {
        if player.eventID != nil {
            _ = try await saveParticipant(player)
        } else {
            players[player.id] = player
        }
    }

    func submit(_ submission: CompetitionSubmission) async throws -> CompetitionSubmission {
        if let existing = values[submission.id] { return existing }
        guard players[submission.playerID] != nil else { throw CompetitionRepositoryError.playerNotFound }
        if let eventID = submission.eventID {
            guard let event = events[eventID] else {
                throw AthleteMemoryRepositoryError.eventNotFound
            }
            guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
        }
        values[submission.id] = submission
        return submission
    }

    func submissions() async throws -> [CompetitionSubmission] {
        values.values.sorted { $0.endedAt > $1.endedAt }
    }

    func submissions(eventID: UUID) async throws -> [CompetitionSubmission] {
        values.values
            .filter { $0.eventID == eventID }
            .sorted { $0.endedAt > $1.endedAt }
    }

    func save(techniqueAttempts: [TechniqueAttemptSnapshot]) async throws {
        for attempt in techniqueAttempts {
            if let existing = attemptValues[attempt.id], existing != attempt {
                throw CompetitionRepositoryError.invalidSubmission
            }
            attemptValues[attempt.id] = attempt
        }
    }

    func techniqueAttempts(
        athleteID: UUID,
        techniqueID: String
    ) async throws -> [TechniqueAttemptSnapshot] {
        attemptValues.values
            .filter { $0.athleteID == athleteID && $0.techniqueID == techniqueID }
            .sorted(by: stableAttemptOrder)
    }

    func save(skillMemory: AthleteSkillMemory) async throws {
        memoryValues[skillMemory.key.storageKey] = skillMemory
    }

    func skillMemory(
        athleteID: UUID,
        techniqueID: String
    ) async throws -> AthleteSkillMemory? {
        memoryValues.values
            .filter { $0.athleteID == athleteID && $0.techniqueID == techniqueID }
            .max { $0.updatedAt < $1.updatedAt }
    }

    func save(coachingCycle transaction: CoachingCycleMemoryTransaction) async throws {
        if let existing = coachingCycleValues[transaction.cycle.id] {
            guard existing == transaction.cycle else {
                throw CompetitionRepositoryError.invalidSubmission
            }
            return
        }

        var nextAttempts = attemptValues
        for attempt in transaction.legacyAttempts {
            if let existing = nextAttempts[attempt.id], existing != attempt {
                throw CompetitionRepositoryError.invalidSubmission
            }
            nextAttempts[attempt.id] = attempt
        }
        var nextPlayers = players
        var nextMemory = memoryValues
        var nextCycles = coachingCycleValues
        nextPlayers[transaction.player.id] = transaction.player
        nextMemory[transaction.skillMemory.key.storageKey] = transaction.skillMemory
        nextCycles[transaction.cycle.id] = transaction.cycle

        attemptValues = nextAttempts
        players = nextPlayers
        memoryValues = nextMemory
        coachingCycleValues = nextCycles
    }

    func coachingCycle(id: UUID) async throws -> CoachingCycleSnapshot? {
        coachingCycleValues[id]
    }

    func reserveTrainingRun(
        _ run: PendingTrainingRun,
        descriptor: DurableTrainingRunDescriptor
    ) async throws -> TrainingRunSnapshot {
        guard descriptor.validates(run) else {
            throw AthleteMemoryRepositoryError.runParticipantMismatch
        }
        if let existing = trainingRunValues[run.id] {
            guard existing.athleteID == run.athleteID,
                  existing.eventID == run.eventID,
                  existing.techniqueID == run.techniqueID,
                  existing.requestedAt == run.requestedAt
            else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
            guard trainingRunDescriptors[run.id] == descriptor else {
                throw AthleteMemoryRepositoryError.runParticipantMismatch
            }
            return existing
        }
        try validateTrainingRunOwner(run)
        guard let snapshot = TrainingRunSnapshot(run) else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        trainingRunValues[run.id] = snapshot
        trainingRunDescriptors[run.id] = descriptor
        return snapshot
    }

    func trainingRunDescriptor(id: UUID) async throws -> DurableTrainingRunDescriptor? {
        trainingRunDescriptors[id]
    }

    func isAuraResultDeliveryAcknowledged(runID: UUID) async throws -> Bool {
        acknowledgedAuraResultIDs.contains(runID)
    }

    func acknowledgeAuraResultDelivery(runID: UUID, at date: Date) async throws {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              trainingRunDescriptors[runID]?.kind == .auraCoaching,
              trainingRunValues[runID]?.status == .committed
        else { throw AthleteMemoryRepositoryError.invalidRunTransition }
        acknowledgedAuraResultIDs.insert(runID)
    }

    func trainingRun(id: UUID) async throws -> TrainingRunSnapshot? { trainingRunValues[id] }

    func trainingRuns() async throws -> [TrainingRunSnapshot] {
        trainingRunValues.values.sorted { $0.requestedAt < $1.requestedAt }
    }

    func activateTrainingRun(id: UUID, at date: Date) async throws -> TrainingRunSnapshot {
        guard let existing = trainingRunValues[id] else {
            throw AthleteMemoryRepositoryError.runNotFound
        }
        if existing.status == .active { return existing }
        guard let active = existing.starting(at: date) else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        trainingRunValues[id] = active
        return active
    }

    func stageCoachingCycle(
        runID: UUID,
        transaction: CoachingCycleMemoryTransaction
    ) async throws -> TrainingRunSnapshot {
        guard transaction.cycle.id == runID,
              let existing = trainingRunValues[runID]
        else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
        try validateCoachingTransaction(transaction, for: existing, requiresOpenEvent: true)
        if existing.status == .completedAwaitingCommit || existing.status == .committed {
            guard stagedCoachingCycles[runID] == transaction else {
                throw AthleteMemoryRepositoryError.runParticipantMismatch
            }
            return existing
        }
        guard let completed = existing.completing(with: transaction.cycle) else {
            throw AthleteMemoryRepositoryError.runParticipantMismatch
        }
        stagedCoachingCycles[runID] = transaction
        trainingRunValues[runID] = completed
        return completed
    }

    func commitCoachingCycle(runID: UUID, at date: Date) async throws -> TrainingRunSnapshot {
        guard let run = trainingRunValues[runID],
              let transaction = stagedCoachingCycles[runID]
        else { throw AthleteMemoryRepositoryError.runNotFound }
        try validateCoachingTransaction(transaction, for: run, requiresOpenEvent: false)
        let committed: TrainingRunSnapshot
        if run.status == .committed {
            committed = run
        } else {
            guard let transitioned = run.committing(at: date) else {
                throw AthleteMemoryRepositoryError.invalidRunTransition
            }
            committed = transitioned
        }

        var nextAttempts = attemptValues
        for attempt in transaction.legacyAttempts {
            if let existing = nextAttempts[attempt.id], existing != attempt {
                throw AthleteMemoryRepositoryError.attemptParticipantMismatch
            }
            nextAttempts[attempt.id] = attempt
        }
        var nextPlayers = players
        var nextMemory = memoryValues
        var nextCycles = coachingCycleValues
        var nextRuns = trainingRunValues
        if let existingCycle = nextCycles[runID], existingCycle != transaction.cycle {
            throw AthleteMemoryRepositoryError.runParticipantMismatch
        }
        nextPlayers[transaction.player.id] = transaction.player
        nextMemory[transaction.skillMemory.key.storageKey] = transaction.skillMemory
        nextCycles[runID] = transaction.cycle
        nextRuns[runID] = committed

        attemptValues = nextAttempts
        players = nextPlayers
        memoryValues = nextMemory
        coachingCycleValues = nextCycles
        trainingRunValues = nextRuns
        return committed
    }

    func abortTrainingRun(id: UUID, at date: Date) async throws -> TrainingRunSnapshot {
        guard let existing = trainingRunValues[id] else {
            throw AthleteMemoryRepositoryError.runNotFound
        }
        if existing.status == .aborted { return existing }
        guard let aborted = existing.aborting(at: date) else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        trainingRunValues[id] = aborted
        stagedCoachingCycles.removeValue(forKey: id)
        return aborted
    }

    func reset() async throws {
        events.removeAll()
        players.removeAll()
        values.removeAll()
        attemptValues.removeAll()
        memoryValues.removeAll()
        coachingCycleValues.removeAll()
        trainingRunValues.removeAll()
        stagedCoachingCycles.removeAll()
        trainingRunDescriptors.removeAll()
        acknowledgedAuraResultIDs.removeAll()
    }

    private func validateTrainingRunOwner(_ run: PendingTrainingRun) throws {
        guard let participant = players[run.athleteID],
              participant.eventID == run.eventID
        else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
        if let eventID = run.eventID {
            guard let event = events[eventID] else {
                throw AthleteMemoryRepositoryError.eventNotFound
            }
            guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
        }
    }

    private func validateCoachingTransaction(
        _ transaction: CoachingCycleMemoryTransaction,
        for run: TrainingRunSnapshot,
        requiresOpenEvent: Bool
    ) throws {
        guard transaction.cycle.id == run.id,
              transaction.cycle.athleteID == run.athleteID,
              transaction.cycle.eventID == run.eventID,
              transaction.cycle.techniqueID == run.techniqueID,
              let participant = players[run.athleteID],
              participant.eventID == run.eventID,
              participant.name == transaction.player.name,
              participant.normalizedName == transaction.player.normalizedName,
              participant.experienceLevel == transaction.player.experienceLevel,
              participant.publicHandle == transaction.player.publicHandle,
              transaction.player.reach == transaction.cycle.fittedReach,
              transaction.player.rememberedStance == transaction.cycle.stance,
              transaction.legacyAttempts.allSatisfy({
                  $0.calibrationVersion == transaction.player.calibrationVersion
              })
        else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
        guard let descriptor = trainingRunDescriptors[run.id] else {
            throw AthleteMemoryRepositoryError.corruptData
        }
        guard descriptor.kind == .auraCoaching,
              descriptor.track?.id == transaction.cycle.trackID,
              descriptor.techniqueID == transaction.cycle.techniqueID,
              descriptor.stance == transaction.cycle.stance
        else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
        if requiresOpenEvent, let eventID = run.eventID {
            guard let event = events[eventID] else {
                throw AthleteMemoryRepositoryError.eventNotFound
            }
            guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
        }
    }

}

@Model
final class CompetitionPlayerRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var normalizedName: String
    var name: String
    var stanceRawValue: String
    var leftReach: Float?
    var rightReach: Float?
    var calibrationVersion: Int?
    var calibratedAt: Date?
    var createdAt: Date
    var lastSeenAt: Date

    init(_ player: CompetitionPlayer) {
        id = player.id
        normalizedName = player.normalizedName
        name = player.name
        stanceRawValue = player.rememberedStance.rawValue
        leftReach = player.reach?.left
        rightReach = player.reach?.right
        calibrationVersion = player.calibrationVersion
        calibratedAt = player.calibratedAt
        createdAt = player.createdAt
        lastSeenAt = player.lastSeenAt
    }

    var snapshot: CompetitionPlayer {
        CompetitionPlayer(
            id: id,
            name: name,
            normalizedName: normalizedName,
            rememberedStance: Stance(rawValue: stanceRawValue) ?? .orthodox,
            reach: leftReach.flatMap { left in rightReach.flatMap { BilateralReach(left: left, right: $0) } },
            calibrationVersion: calibrationVersion,
            calibratedAt: calibratedAt,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt
        )
    }

    func apply(_ player: CompetitionPlayer) {
        name = player.name
        stanceRawValue = player.rememberedStance.rawValue
        leftReach = player.reach?.left
        rightReach = player.reach?.right
        calibrationVersion = player.calibrationVersion
        calibratedAt = player.calibratedAt
        lastSeenAt = player.lastSeenAt
    }
}

@Model
final class CompetitionSubmissionRecord {
    @Attribute(.unique) var id: UUID
    var playerID: UUID
    var playerName: String
    var normalizedPlayerName: String
    var modeRawValue: String
    var score: Int
    var validSteps: Int
    var totalSteps: Int
    var completedRepetitions: Int
    var meanCentreErrorMeters: Float?
    var speedTieBreakSeconds: TimeInterval?
    var startedAt: Date
    var endedAt: Date
    var trackingStatusRawValue: String

    init(_ value: CompetitionSubmission) {
        id = value.id
        playerID = value.playerID
        playerName = value.playerName
        normalizedPlayerName = value.normalizedPlayerName
        modeRawValue = value.mode.rawValue
        score = value.score
        validSteps = value.validSteps
        totalSteps = value.totalSteps
        completedRepetitions = value.completedRepetitions
        meanCentreErrorMeters = value.meanCentreErrorMeters
        speedTieBreakSeconds = value.speedTieBreakSeconds
        startedAt = value.startedAt
        endedAt = value.endedAt
        trackingStatusRawValue = value.trackingStatus.rawValue
    }

    var snapshot: CompetitionSubmission? {
        guard let mode = CompetitionMode(rawValue: modeRawValue),
              let tracking = CompetitionTrackingStatus(rawValue: trackingStatusRawValue)
        else { return nil }
        return CompetitionSubmission(
            id: id,
            playerID: playerID,
            playerName: playerName,
            normalizedPlayerName: normalizedPlayerName,
            mode: mode,
            score: score,
            validSteps: validSteps,
            totalSteps: totalSteps,
            completedRepetitions: completedRepetitions,
            meanCentreErrorMeters: meanCentreErrorMeters,
            speedTieBreakSeconds: speedTieBreakSeconds,
            startedAt: startedAt,
            endedAt: endedAt,
            trackingStatus: tracking
        )
    }
}

enum CompetitionSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [CompetitionPlayerRecord.self, CompetitionSubmissionRecord.self]
    }
}

enum CompetitionMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            CompetitionSchemaV1.self,
            CompetitionSchemaV2.self,
            CompetitionSchemaV3.self,
            CompetitionSchemaV4.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: CompetitionSchemaV1.self,
                toVersion: CompetitionSchemaV2.self,
                willMigrate: nil,
                didMigrate: { context in
                    try CompetitionLegacyMigration.migrate(context)
                }
            ),
            .custom(
                fromVersion: CompetitionSchemaV2.self,
                toVersion: CompetitionSchemaV3.self,
                willMigrate: nil,
                didMigrate: { context in
                    try CompetitionMemoryV3Migration.migrate(context)
                }
            ),
            .custom(
                fromVersion: CompetitionSchemaV3.self,
                toVersion: CompetitionSchemaV4.self,
                willMigrate: nil,
                didMigrate: { context in
                    try CompetitionRunV4Migration.migrate(context)
                }
            )
        ]
    }
}

enum CompetitionModelContainer {
    static let configurationName = "BoxingCoachAthleteMemory"
    private static let legacyConfigurationName = "BoxingCoachCompetitionV1"

    static func make(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CompetitionSchemaV4.self)
        return try make(schema: schema, configuration: configuration(inMemory: inMemory))
    }

    static func configuration(inMemory: Bool) -> ModelConfiguration {
        let schema = Schema(versionedSchema: CompetitionSchemaV4.self)
        if inMemory {
            return ModelConfiguration(
                configurationName,
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: true,
                groupContainer: .automatic,
                cloudKitDatabase: .none
            )
        }
        return ModelConfiguration(
            configurationName,
            schema: schema,
            url: legacyStoreURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
    }

    static func make(storeURL: URL, allowsSave: Bool = true) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CompetitionSchemaV4.self)
        let configuration = ModelConfiguration(
            configurationName,
            schema: schema,
            url: storeURL,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try make(schema: schema, configuration: configuration)
    }

    private static var legacyStoreURL: URL {
        // Keep the shipped V1 file URL while giving the current configuration a version-neutral name.
        // Changing both would abandon the existing store instead of migrating it.
        ModelConfiguration(
            legacyConfigurationName,
            schema: Schema(versionedSchema: CompetitionSchemaV1.self),
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .automatic,
            cloudKitDatabase: .none
        ).url
    }

    private static func make(
        schema: Schema,
        configuration: ModelConfiguration
    ) throws -> ModelContainer {
        return try ModelContainer(
            for: schema,
            migrationPlan: CompetitionMigrationPlan.self,
            configurations: [configuration]
        )
    }
}

@MainActor
final class SwiftDataCompetitionRepository: CompetitionRepository {
    let container: ModelContainer
    private var context: ModelContext
    private let afterParticipantProfileMutation: () throws -> Void
    private let beforeSave: () throws -> Void

    init(
        container: ModelContainer,
        afterParticipantProfileMutation: @escaping () throws -> Void = {},
        beforeSave: @escaping () throws -> Void = {}
    ) {
        self.container = container
        self.afterParticipantProfileMutation = afterParticipantProfileMutation
        self.beforeSave = beforeSave
        context = Self.makeContext(container: container)
    }

    func activeEvent() async throws -> EventEdition? {
        try context.fetch(FetchDescriptor<CompetitionSchemaV3.EventEditionRecord>())
            .compactMap(\.snapshot)
            .first(where: \.isOpen)
    }

    func create(event: EventEdition) async throws -> EventEdition {
        let records = try context.fetch(FetchDescriptor<CompetitionSchemaV3.EventEditionRecord>())
        if let existing = records.first(where: { $0.id == event.id })?.snapshot {
            return existing
        }
        guard event.isOpen,
              !records.compactMap(\.snapshot).contains(where: \.isOpen)
        else { throw AthleteMemoryRepositoryError.activeEventExists }
        context.insert(CompetitionSchemaV3.EventEditionRecord(event))
        try saveContext()
        return event
    }

    func closeEvent(id: UUID, at date: Date) async throws -> EventEdition {
        let records = try context.fetch(FetchDescriptor<CompetitionSchemaV3.EventEditionRecord>())
        guard let record = records.first(where: { $0.id == id }),
              let event = record.snapshot else {
            throw AthleteMemoryRepositoryError.eventNotFound
        }
        if !event.isOpen { return event }
        guard let closed = event.closing(at: date) else {
            throw AthleteMemoryRepositoryError.invalidEvent
        }
        record.statusRawValue = closed.status.rawValue
        record.closedAt = closed.closedAt
        try saveContext()
        return closed
    }

    func participants(eventID: UUID) async throws -> [CompetitionPlayer] {
        try context.fetch(FetchDescriptor<CompetitionSchemaV3.CompetitionPlayerRecord>())
            .filter { $0.eventID == eventID }
            .map(\.snapshot)
            .sorted { ($0.publicHandle?.displayCode ?? "") < ($1.publicHandle?.displayCode ?? "") }
    }

    func participant(eventID: UUID, displayCode: String) async throws -> CompetitionPlayer? {
        try context.fetch(FetchDescriptor<CompetitionSchemaV3.CompetitionPlayerRecord>())
            .first { $0.eventID == eventID && $0.publicDisplayCode == displayCode }?
            .snapshot
    }

    func createParticipant(
        eventID: UUID,
        displayName: String,
        experienceLevel: ExperienceLevel,
        stance: Stance,
        at date: Date
    ) async throws -> CompetitionPlayer {
        guard let event = try context.fetch(
            FetchDescriptor<CompetitionSchemaV3.EventEditionRecord>()
        ).first(where: { $0.id == eventID })?.snapshot else {
            throw AthleteMemoryRepositoryError.eventNotFound
        }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
        let name = try CompetitionName.display(displayName)
        let records = try context.fetch(
            FetchDescriptor<CompetitionSchemaV3.CompetitionPlayerRecord>()
        )
        guard let handle = ParticipantPublicHandle.allocating(
            eventID: eventID,
            displayName: name,
            against: records.map(\.snapshot).compactMap(\.publicHandle)
        ) else { throw AthleteMemoryRepositoryError.duplicateDisplayCode }
        let participant = CompetitionPlayer(
            id: UUID(), name: name, normalizedName: CompetitionName.normalized(name),
            rememberedStance: stance, reach: nil, calibrationVersion: nil,
            calibratedAt: nil, createdAt: date, lastSeenAt: date,
            experienceLevel: experienceLevel, publicHandle: handle
        )
        context.insert(CompetitionSchemaV3.CompetitionPlayerRecord(participant))
        try saveContext()
        return participant
    }

    func saveParticipant(_ participant: CompetitionPlayer) async throws -> CompetitionPlayer {
        guard let eventID = participant.eventID,
              let event = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.EventEditionRecord>()
              ).first(where: { $0.id == eventID })?.snapshot
        else { throw AthleteMemoryRepositoryError.eventNotFound }
        guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
        do {
            let saved = try SwiftDataParticipantPersistence.upsert(
                participant,
                in: context,
                afterProfileMutation: afterParticipantProfileMutation
            )
            try saveContext()
            return saved
        } catch {
            rollbackContext()
            throw error
        }
    }

    func player(normalizedName: String) async throws -> CompetitionPlayer? {
        try context.fetch(FetchDescriptor<CompetitionSchemaV3.CompetitionPlayerRecord>())
            .first { $0.normalizedName == normalizedName }?.snapshot
    }

    func player(id: UUID) async throws -> CompetitionPlayer? {
        try playerRecord(id: id)?.snapshot
    }

    func save(player: CompetitionPlayer) async throws {
        if player.eventID != nil {
            _ = try await saveParticipant(player)
            return
        }
        do {
            _ = try SwiftDataParticipantPersistence.upsert(
                player,
                in: context,
                afterProfileMutation: afterParticipantProfileMutation
            )
        } catch {
            rollbackContext()
            throw error
        }
        try saveContext()
    }

    func submit(_ submission: CompetitionSubmission) async throws -> CompetitionSubmission {
        if let existing = try submissionRecord(id: submission.id)?.snapshot { return existing }
        guard try playerRecord(id: submission.playerID) != nil else {
            throw CompetitionRepositoryError.playerNotFound
        }
        if let eventID = submission.eventID {
            guard let event = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.EventEditionRecord>()
            ).first(where: { $0.id == eventID })?.snapshot else {
                throw AthleteMemoryRepositoryError.eventNotFound
            }
            guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
        }
        context.insert(CompetitionSchemaV3.CompetitionSubmissionRecord(submission))
        try saveContext()
        return submission
    }

    func submissions() async throws -> [CompetitionSubmission] {
        try context.fetch(FetchDescriptor<CompetitionSchemaV3.CompetitionSubmissionRecord>())
            .compactMap(\.snapshot)
            .sorted { $0.endedAt > $1.endedAt }
    }

    func submissions(eventID: UUID) async throws -> [CompetitionSubmission] {
        try context.fetch(FetchDescriptor<CompetitionSchemaV3.CompetitionSubmissionRecord>())
            .compactMap(\.snapshot)
            .filter { $0.eventID == eventID }
            .sorted { $0.endedAt > $1.endedAt }
    }

    func save(techniqueAttempts: [TechniqueAttemptSnapshot]) async throws {
        let existing = try context.fetch(
            FetchDescriptor<CompetitionSchemaV3.TechniqueAttemptRecord>()
        )
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for attempt in techniqueAttempts {
            if let record = existingByID[attempt.id] {
                guard record.snapshot == attempt else {
                    throw CompetitionRepositoryError.invalidSubmission
                }
            } else {
                context.insert(CompetitionSchemaV3.TechniqueAttemptRecord(attempt))
            }
        }
        try saveContext()
    }

    func techniqueAttempts(
        athleteID: UUID,
        techniqueID: String
    ) async throws -> [TechniqueAttemptSnapshot] {
        try context.fetch(FetchDescriptor<CompetitionSchemaV3.TechniqueAttemptRecord>())
            .compactMap(\.snapshot)
            .filter { $0.athleteID == athleteID && $0.techniqueID == techniqueID }
            .sorted(by: stableAttemptOrder)
    }

    func save(skillMemory: AthleteSkillMemory) async throws {
        let records = try context.fetch(
            FetchDescriptor<CompetitionSchemaV3.AthleteSkillMemoryRecord>()
        )
        if let existing = records.first(where: {
            $0.athleteID == skillMemory.athleteID
                && $0.techniqueID == skillMemory.techniqueID
        }) {
            context.delete(existing)
        }
        context.insert(try CompetitionSchemaV3.AthleteSkillMemoryRecord(skillMemory))
        try saveContext()
    }

    func skillMemory(
        athleteID: UUID,
        techniqueID: String
    ) async throws -> AthleteSkillMemory? {
        let attempts = try await techniqueAttempts(
            athleteID: athleteID,
            techniqueID: techniqueID
        )
        return try context.fetch(
            FetchDescriptor<CompetitionSchemaV3.AthleteSkillMemoryRecord>()
        )
        .first { $0.athleteID == athleteID && $0.techniqueID == techniqueID }?
        .snapshot(attempts: attempts)
    }

    func save(coachingCycle transaction: CoachingCycleMemoryTransaction) async throws {
        do {
            let inserted = try applyCoachingCycle(transaction)
            guard inserted else { return }
            try saveContext()
        } catch {
            context.rollback()
            context = Self.makeContext(container: container)
            if let repositoryError = error as? CompetitionRepositoryError {
                throw repositoryError
            }
            throw CompetitionRepositoryError.saveFailed(
                "The coaching cycle could not be saved. Nothing was changed."
            )
        }
    }

    func coachingCycle(id: UUID) async throws -> CoachingCycleSnapshot? {
        try context.fetch(FetchDescriptor<CompetitionSchemaV3.CoachingCycleRecord>())
            .first { $0.id == id }?.snapshot
    }

    func reserveTrainingRun(
        _ run: PendingTrainingRun,
        descriptor: DurableTrainingRunDescriptor
    ) async throws -> TrainingRunSnapshot {
        guard descriptor.validates(run) else {
            throw AthleteMemoryRepositoryError.runParticipantMismatch
        }
        if let existing = try trainingRunRecord(id: run.id)?.runSnapshot {
            guard existing.athleteID == run.athleteID,
                  existing.eventID == run.eventID,
                  existing.techniqueID == run.techniqueID,
                  existing.requestedAt == run.requestedAt
            else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
            guard try await trainingRunDescriptor(id: run.id) == descriptor else {
                throw AthleteMemoryRepositoryError.runParticipantMismatch
            }
            return existing
        }
        try validateTrainingRunOwner(run)
        let record = CompetitionSchemaV3.PendingTrainingRunRecord(run)
        guard let snapshot = record.runSnapshot else {
            throw AthleteMemoryRepositoryError.corruptData
        }
        context.insert(record)
        context.insert(try CompetitionSchemaV4.TrainingRunDescriptorRecord(descriptor))
        try saveContext()
        return snapshot
    }

    func trainingRunDescriptor(id: UUID) async throws -> DurableTrainingRunDescriptor? {
        guard let record = try descriptorRecord(runID: id) else { return nil }
        guard let descriptor = record.descriptor else {
            throw AthleteMemoryRepositoryError.corruptData
        }
        return descriptor
    }

    func isAuraResultDeliveryAcknowledged(runID: UUID) async throws -> Bool {
        try descriptorRecord(runID: runID)?.resultAcknowledgedAt != nil
    }

    func acknowledgeAuraResultDelivery(runID: UUID, at date: Date) async throws {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              let descriptor = try descriptorRecord(runID: runID),
              descriptor.descriptor?.kind == .auraCoaching,
              try trainingRunRecord(id: runID)?.runSnapshot?.status == .committed
        else { throw AthleteMemoryRepositoryError.invalidRunTransition }
        guard descriptor.resultAcknowledgedAt == nil else { return }
        descriptor.resultAcknowledgedAt = date
        try saveContext()
    }

    func trainingRun(id: UUID) async throws -> TrainingRunSnapshot? {
        guard let record = try trainingRunRecord(id: id) else { return nil }
        guard let snapshot = record.runSnapshot else {
            throw AthleteMemoryRepositoryError.corruptData
        }
        return snapshot
    }

    func trainingRuns() async throws -> [TrainingRunSnapshot] {
        try context.fetch(FetchDescriptor<CompetitionSchemaV3.PendingTrainingRunRecord>())
            .map { record in
                guard let snapshot = record.runSnapshot else {
                    throw AthleteMemoryRepositoryError.corruptData
                }
                return snapshot
            }
            .sorted { $0.requestedAt < $1.requestedAt }
    }

    func activateTrainingRun(id: UUID, at date: Date) async throws -> TrainingRunSnapshot {
        guard let record = try trainingRunRecord(id: id),
              let current = record.runSnapshot
        else { throw AthleteMemoryRepositoryError.runNotFound }
        if current.status == .active { return current }
        guard let active = current.starting(at: date) else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        try record.apply(active)
        try saveContext()
        return active
    }

    func stageCoachingCycle(
        runID: UUID,
        transaction: CoachingCycleMemoryTransaction
    ) async throws -> TrainingRunSnapshot {
        guard transaction.cycle.id == runID,
              let runRecord = try trainingRunRecord(id: runID),
              let current = runRecord.runSnapshot
        else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
        try validateCoachingTransaction(transaction, for: current, requiresOpenEvent: true)

        if current.status == .completedAwaitingCommit || current.status == .committed {
            guard let staged = try completionRecord(runID: runID)?.transaction,
                  staged == transaction
            else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
            return current
        }
        guard let completed = current.completing(with: transaction.cycle) else {
            throw AthleteMemoryRepositoryError.runParticipantMismatch
        }
        do {
            if let existing = try completionRecord(runID: runID) {
                guard existing.transaction == transaction else {
                    throw AthleteMemoryRepositoryError.runParticipantMismatch
                }
            } else {
                context.insert(try CompetitionSchemaV4.CoachingRunCompletionRecord(
                    runID: runID,
                    transaction: transaction
                ))
            }
            try runRecord.apply(completed)
            try saveContext()
            return completed
        } catch {
            rollbackContext()
            throw error
        }
    }

    func commitCoachingCycle(runID: UUID, at date: Date) async throws -> TrainingRunSnapshot {
        guard let runRecord = try trainingRunRecord(id: runID),
              let current = runRecord.runSnapshot,
              let completion = try completionRecord(runID: runID),
              let transaction = completion.transaction
        else { throw AthleteMemoryRepositoryError.runNotFound }
        try validateCoachingTransaction(transaction, for: current, requiresOpenEvent: false)
        if current.status == .committed {
            _ = try applyCoachingCycle(transaction)
            try saveContext()
            return current
        }
        guard let committed = current.committing(at: date) else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }

        do {
            _ = try applyCoachingCycle(transaction)
            try runRecord.apply(committed)
            try saveContext()
            return committed
        } catch {
            rollbackContext()
            throw error
        }
    }

    func abortTrainingRun(id: UUID, at date: Date) async throws -> TrainingRunSnapshot {
        guard let record = try trainingRunRecord(id: id),
              let current = record.runSnapshot
        else { throw AthleteMemoryRepositoryError.runNotFound }
        if current.status == .aborted { return current }
        guard let aborted = current.aborting(at: date) else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        do {
            try record.apply(aborted)
            if let completion = try completionRecord(runID: id) {
                context.delete(completion)
            }
            try saveContext()
            return aborted
        } catch {
            rollbackContext()
            throw error
        }
    }

    func reset() async throws {
        try context.delete(model: CompetitionSchemaV4.CoachingRunCompletionRecord.self)
        try context.delete(model: CompetitionSchemaV4.TrainingRunDescriptorRecord.self)
        try context.delete(model: CompetitionSchemaV3.CoachingCycleRecord.self)
        try context.delete(model: CompetitionSchemaV3.AthleteSkillMemoryRecord.self)
        try context.delete(model: CompetitionSchemaV3.TechniqueAttemptRecord.self)
        try context.delete(model: CompetitionSchemaV3.CompetitionSubmissionRecord.self)
        try context.delete(model: CompetitionSchemaV3.CompetitionPlayerRecord.self)
        try context.delete(model: CompetitionSchemaV3.EventAwardRecord.self)
        try context.delete(model: CompetitionSchemaV3.PendingTrainingRunRecord.self)
        try context.delete(model: CompetitionSchemaV3.EventEditionRecord.self)
        try saveContext()
    }

    private func playerRecord(id: UUID) throws -> CompetitionSchemaV3.CompetitionPlayerRecord? {
        try context.fetch(FetchDescriptor<CompetitionSchemaV3.CompetitionPlayerRecord>())
            .first { $0.id == id }
    }

    private func submissionRecord(id: UUID) throws -> CompetitionSchemaV3.CompetitionSubmissionRecord? {
        try context.fetch(FetchDescriptor<CompetitionSchemaV3.CompetitionSubmissionRecord>())
            .first { $0.id == id }
    }

    private func trainingRunRecord(
        id: UUID
    ) throws -> CompetitionSchemaV3.PendingTrainingRunRecord? {
        try context.fetch(FetchDescriptor<CompetitionSchemaV3.PendingTrainingRunRecord>())
            .first { $0.id == id }
    }

    private func completionRecord(
        runID: UUID
    ) throws -> CompetitionSchemaV4.CoachingRunCompletionRecord? {
        try context.fetch(FetchDescriptor<CompetitionSchemaV4.CoachingRunCompletionRecord>())
            .first { $0.runID == runID }
    }

    private func descriptorRecord(
        runID: UUID
    ) throws -> CompetitionSchemaV4.TrainingRunDescriptorRecord? {
        try context.fetch(FetchDescriptor<CompetitionSchemaV4.TrainingRunDescriptorRecord>())
            .first { $0.runID == runID }
    }

    private func validateTrainingRunOwner(_ run: PendingTrainingRun) throws {
        guard let participant = try playerRecord(id: run.athleteID)?.snapshot,
              participant.eventID == run.eventID
        else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
        if let eventID = run.eventID {
            guard let event = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.EventEditionRecord>()
            ).first(where: { $0.id == eventID })?.snapshot else {
                throw AthleteMemoryRepositoryError.eventNotFound
            }
            guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
        }
    }

    private func validateCoachingTransaction(
        _ transaction: CoachingCycleMemoryTransaction,
        for run: TrainingRunSnapshot,
        requiresOpenEvent: Bool
    ) throws {
        guard transaction.cycle.id == run.id,
              transaction.cycle.athleteID == run.athleteID,
              transaction.cycle.eventID == run.eventID,
              transaction.cycle.techniqueID == run.techniqueID,
              let participant = try playerRecord(id: run.athleteID)?.snapshot,
              participant.eventID == run.eventID,
              participant.name == transaction.player.name,
              participant.normalizedName == transaction.player.normalizedName,
              participant.experienceLevel == transaction.player.experienceLevel,
              participant.publicHandle == transaction.player.publicHandle,
              transaction.player.reach == transaction.cycle.fittedReach,
              transaction.player.rememberedStance == transaction.cycle.stance,
              transaction.legacyAttempts.allSatisfy({
                  $0.calibrationVersion == transaction.player.calibrationVersion
              })
        else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
        guard let descriptor = try descriptorRecord(runID: run.id)?.descriptor else {
            throw AthleteMemoryRepositoryError.corruptData
        }
        guard descriptor.kind == .auraCoaching,
              descriptor.track?.id == transaction.cycle.trackID,
              descriptor.techniqueID == transaction.cycle.techniqueID,
              descriptor.stance == transaction.cycle.stance
        else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
        if requiresOpenEvent, let eventID = run.eventID {
            guard let event = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.EventEditionRecord>()
            ).first(where: { $0.id == eventID })?.snapshot else {
                throw AthleteMemoryRepositoryError.eventNotFound
            }
            guard event.isOpen else { throw AthleteMemoryRepositoryError.eventClosed }
        }
    }

    /// Applies every coaching-memory row to this context without saving. Its callers either save
    /// once with the run transition or roll the entire context back.
    @discardableResult
    private func applyCoachingCycle(
        _ transaction: CoachingCycleMemoryTransaction
    ) throws -> Bool {
        let cycles = try context.fetch(
            FetchDescriptor<CompetitionSchemaV3.CoachingCycleRecord>()
        )
        let existingCycle = cycles.first(where: { $0.id == transaction.cycle.id })
        if let existing = existingCycle {
            guard existing.snapshot == transaction.cycle else {
                throw AthleteMemoryRepositoryError.runParticipantMismatch
            }
        }

        if let existingPlayer = try playerRecord(id: transaction.player.id) {
            guard existingPlayer.snapshot.eventID == transaction.player.eventID else {
                throw AthleteMemoryRepositoryError.participantEventMismatch
            }
            existingPlayer.apply(transaction.player)
        } else {
            context.insert(CompetitionSchemaV3.CompetitionPlayerRecord(transaction.player))
        }

        let existingAttempts = try context.fetch(
            FetchDescriptor<CompetitionSchemaV3.TechniqueAttemptRecord>()
        )
        let existingByID = Dictionary(uniqueKeysWithValues: existingAttempts.map { ($0.id, $0) })
        for attempt in transaction.legacyAttempts {
            if let record = existingByID[attempt.id] {
                guard record.snapshot == attempt else {
                    throw AthleteMemoryRepositoryError.attemptParticipantMismatch
                }
            } else {
                context.insert(CompetitionSchemaV3.TechniqueAttemptRecord(attempt))
            }
        }

        let memoryRecords = try context.fetch(
            FetchDescriptor<CompetitionSchemaV3.AthleteSkillMemoryRecord>()
        )
        if let existingMemory = memoryRecords.first(where: {
            $0.id == transaction.skillMemory.key.storageKey
        }) {
            try existingMemory.apply(transaction.skillMemory)
        } else {
            context.insert(try CompetitionSchemaV3.AthleteSkillMemoryRecord(
                transaction.skillMemory
            ))
        }
        if existingCycle == nil {
            context.insert(try CompetitionSchemaV3.CoachingCycleRecord(transaction.cycle))
        }
        return true
    }

    private func saveContext() throws {
        do {
            try beforeSave()
            try context.save()
        } catch {
            rollbackContext()
            throw CompetitionRepositoryError.saveFailed("Competition data could not be saved. Nothing was changed.")
        }
    }

    private func rollbackContext() {
        context.rollback()
        context = Self.makeContext(container: container)
    }

    private static func makeContext(container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }
}

@MainActor
enum CompetitionLiveRepositoryFactory {
    static func makeLiveRepository(
        container: ModelContainer
    ) -> SwiftDataCompetitionRepository {
        SwiftDataCompetitionRepository(container: container)
    }
}

nonisolated enum CompetitionMemoryV3Migration {
    static func migrate(_ context: ModelContext) throws {
        do {
            let caches = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.AthleteSkillMemoryRecord>()
            )
            let attempts = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.TechniqueAttemptRecord>()
            )
            var attemptsByID: [UUID: CompetitionSchemaV3.TechniqueAttemptRecord] = [:]
            for attempt in attempts {
                guard attemptsByID.updateValue(attempt, forKey: attempt.id) == nil else {
                    throw AthleteMemoryRepositoryError.corruptData
                }
            }

            var attachments: [(CompetitionSchemaV3.TechniqueAttemptRecord, Data)] = []
            var claimedAttemptIDs: Set<UUID> = []
            for cache in caches {
                guard let traceData = cache.pastSelfTraceData else { continue }
                let trace = try JSONDecoder().decode(PastSelfTrace.self, from: traceData)
                guard let traceRecord = attemptsByID[trace.attemptID],
                      let traceAttempt = traceRecord.snapshot,
                      traceAttempt.pastSelfTrace == nil,
                      traceAttempt.athleteID == cache.athleteID,
                      traceAttempt.techniqueID == cache.techniqueID,
                      !claimedAttemptIDs.contains(trace.attemptID)
                else { throw AthleteMemoryRepositoryError.corruptData }

                let memoryAttempts = try cache.attemptIDs.map { attemptID in
                    guard let attempt = attemptsByID[attemptID]?.snapshot else {
                        throw AthleteMemoryRepositoryError.corruptData
                    }
                    return attempt
                }
                guard isValidV2Cache(cache, attempts: memoryAttempts, trace: trace),
                      let evidence = attaching(trace, to: traceAttempt)
                else { throw AthleteMemoryRepositoryError.corruptData }

                claimedAttemptIDs.insert(trace.attemptID)
                attachments.append((traceRecord, try JSONEncoder().encode(evidence)))
            }

            for (attempt, snapshotData) in attachments {
                attempt.snapshotData = snapshotData
            }
            for cache in caches {
                context.delete(cache)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func isValidV2Cache(
        _ cache: CompetitionSchemaV3.AthleteSkillMemoryRecord,
        attempts: [TechniqueAttemptSnapshot],
        trace: PastSelfTrace
    ) -> Bool {
        !cache.techniqueID.isEmpty
            && cache.updatedAt.timeIntervalSinceReferenceDate.isFinite
            && ExperienceLevel(rawValue: cache.experienceLevelRawValue) != nil
            && attempts.allSatisfy {
                $0.athleteID == cache.athleteID
                    && $0.techniqueID == cache.techniqueID
                    && $0.completedAt <= cache.updatedAt
            }
            && attempts.contains { $0.id == trace.attemptID }
    }

    private static func attaching(
        _ trace: PastSelfTrace,
        to attempt: TechniqueAttemptSnapshot
    ) -> TechniqueAttemptSnapshot? {
        TechniqueAttemptSnapshot(
            id: attempt.id,
            athleteID: attempt.athleteID,
            eventID: attempt.eventID,
            coachingCycleID: attempt.coachingCycleID,
            stage: attempt.stage,
            techniqueID: attempt.techniqueID,
            stance: attempt.stance,
            score: attempt.score,
            metrics: attempt.metrics,
            trackedFraction: attempt.trackedFraction,
            duration: attempt.duration,
            isValid: attempt.isValid,
            wrongHand: attempt.wrongHand,
            scoringVersion: attempt.scoringVersion,
            referenceVersion: attempt.referenceVersion,
            calibrationVersion: attempt.calibrationVersion,
            correctionCode: attempt.correctionCode,
            baselineAttemptID: attempt.baselineAttemptID,
            startedAt: attempt.startedAt,
            completedAt: attempt.completedAt,
            pastSelfTrace: trace,
            publicHandleSnapshot: attempt.publicHandleSnapshot
        )
    }
}

nonisolated enum CompetitionLegacyMigration {
    static let eventID = UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!
    private static let legacyScoringVersion = 1

    static func migrate(_ context: ModelContext) throws {
        try migrate(context, save: { try $0.save() })
    }

    static func migrate(
        _ context: ModelContext,
        save: (ModelContext) throws -> Void
    ) throws {
        do {
            let existingEvents = try context.fetch(
                FetchDescriptor<CompetitionSchemaV2.EventEditionRecord>()
            )
            guard existingEvents.isEmpty else {
                throw CompetitionRepositoryError.saveFailed(
                    "Legacy competition data could not be archived because an event already exists."
                )
            }

            let players = try context.fetch(
                FetchDescriptor<CompetitionSchemaV2.CompetitionPlayerRecord>()
            )
            let submissions = try context.fetch(
                FetchDescriptor<CompetitionSchemaV2.CompetitionSubmissionRecord>()
            )
            let participantIDs = Set(players.map(\.id) + submissions.map(\.playerID))
            guard participantIDs.count <= 10_000 else {
                throw CompetitionRepositoryError.saveFailed(
                    "Legacy competition data has too many participants for unique display codes."
                )
            }

            let sortedIDs = participantIDs.sorted { $0.uuidString < $1.uuidString }
            let displayCodes = Dictionary(uniqueKeysWithValues: sortedIDs.enumerated().map {
                ($0.element, String(format: "%04d", $0.offset))
            })
            let timestamps = migrationTimestamps(players: players, submissions: submissions)
            context.insert(CompetitionSchemaV2.EventEditionRecord(
                id: eventID,
                title: "Legacy Event",
                statusRawValue: EventEditionStatus.closed.rawValue,
                openedAt: timestamps.openedAt,
                closedAt: timestamps.closedAt,
                scoringVersion: legacyScoringVersion,
                calibrationVersion: CompetitionPlayer.calibrationVersion
            ))

            let calibrationVersions = Dictionary(uniqueKeysWithValues: players.map {
                ($0.id, $0.calibrationVersion)
            })
            for player in players {
                player.experienceLevelRawValue = ExperienceLevel.beginner.rawValue
                player.eventID = eventID
                player.publicDisplayName = player.name
                player.publicDisplayCode = displayCodes[player.id]
            }
            for submission in submissions {
                guard let displayCode = displayCodes[submission.playerID] else {
                    throw CompetitionRepositoryError.saveFailed(
                        "Legacy competition data contains an unidentifiable submission."
                    )
                }
                submission.eventID = eventID
                submission.scoringVersion = legacyScoringVersion
                submission.calibrationVersion = calibrationVersions[submission.playerID] ?? nil
                submission.publicDisplayName = submission.playerName
                submission.publicDisplayCode = displayCode
            }

            try save(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func migrationTimestamps(
        players: [CompetitionSchemaV2.CompetitionPlayerRecord],
        submissions: [CompetitionSchemaV2.CompetitionSubmissionRecord]
    ) -> (openedAt: Date, closedAt: Date) {
        let playerDates = players.flatMap { player in
            [player.createdAt, player.lastSeenAt] + [player.calibratedAt].compactMap { $0 }
        }
        let submissionDates = submissions.flatMap { [$0.startedAt, $0.endedAt] }
        let dates = playerDates + submissionDates
        let fallback = Date(timeIntervalSince1970: 0)
        return (dates.min() ?? fallback, dates.max() ?? fallback)
    }
}
