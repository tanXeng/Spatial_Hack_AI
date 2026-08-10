import Foundation
import SwiftData

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
    func reset() async throws
}

@MainActor
extension CompetitionRepository {
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
}

@MainActor
final class InMemoryCompetitionRepository: CompetitionRepository {
    private var events: [UUID: EventEdition] = [:]
    private var players: [UUID: CompetitionPlayer] = [:]
    private var values: [UUID: CompetitionSubmission] = [:]
    private var attemptValues: [UUID: TechniqueAttemptSnapshot] = [:]
    private var memoryValues: [String: AthleteSkillMemory] = [:]
    private var coachingCycleValues: [UUID: CoachingCycleSnapshot] = [:]

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
            .sorted { $0.completedAt < $1.completedAt }
    }

    func save(skillMemory: AthleteSkillMemory) async throws {
        memoryValues[Self.memoryKey(
            athleteID: skillMemory.athleteID,
            techniqueID: skillMemory.techniqueID
        )] = skillMemory
    }

    func skillMemory(
        athleteID: UUID,
        techniqueID: String
    ) async throws -> AthleteSkillMemory? {
        memoryValues[Self.memoryKey(athleteID: athleteID, techniqueID: techniqueID)]
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
        nextMemory[Self.memoryKey(
            athleteID: transaction.skillMemory.athleteID,
            techniqueID: transaction.skillMemory.techniqueID
        )] = transaction.skillMemory
        nextCycles[transaction.cycle.id] = transaction.cycle

        attemptValues = nextAttempts
        players = nextPlayers
        memoryValues = nextMemory
        coachingCycleValues = nextCycles
    }

    func coachingCycle(id: UUID) async throws -> CoachingCycleSnapshot? {
        coachingCycleValues[id]
    }

    func reset() async throws {
        events.removeAll()
        players.removeAll()
        values.removeAll()
        attemptValues.removeAll()
        memoryValues.removeAll()
        coachingCycleValues.removeAll()
    }

    private static func memoryKey(athleteID: UUID, techniqueID: String) -> String {
        "\(athleteID.uuidString.lowercased())|\(techniqueID)"
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
        [CompetitionSchemaV1.self, CompetitionSchemaV2.self, CompetitionSchemaV3.self]
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
            )
        ]
    }
}

enum CompetitionModelContainer {
    static let configurationName = "BoxingCoachAthleteMemory"
    private static let legacyConfigurationName = "BoxingCoachCompetitionV1"

    static func make(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CompetitionSchemaV3.self)
        return try make(schema: schema, configuration: configuration(inMemory: inMemory))
    }

    static func configuration(inMemory: Bool) -> ModelConfiguration {
        let schema = Schema(versionedSchema: CompetitionSchemaV3.self)
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
        let schema = Schema(versionedSchema: CompetitionSchemaV3.self)
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

    init(
        container: ModelContainer,
        afterParticipantProfileMutation: @escaping () throws -> Void = {}
    ) {
        self.container = container
        self.afterParticipantProfileMutation = afterParticipantProfileMutation
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
            .sorted { $0.completedAt < $1.completedAt }
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
            let cycles = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.CoachingCycleRecord>()
            )
            if let existing = cycles.first(where: { $0.id == transaction.cycle.id }) {
                guard existing.snapshot == transaction.cycle else {
                    throw CompetitionRepositoryError.invalidSubmission
                }
                return
            }

            if let existingPlayer = try playerRecord(id: transaction.player.id) {
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
                        throw CompetitionRepositoryError.invalidSubmission
                    }
                } else {
                    context.insert(CompetitionSchemaV3.TechniqueAttemptRecord(attempt))
                }
            }

            let memoryRecords = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.AthleteSkillMemoryRecord>()
            )
            if let existingMemory = memoryRecords.first(where: {
                $0.athleteID == transaction.skillMemory.athleteID
                    && $0.techniqueID == transaction.skillMemory.techniqueID
            }) {
                context.delete(existingMemory)
            }
            context.insert(try CompetitionSchemaV3.AthleteSkillMemoryRecord(
                transaction.skillMemory
            ))
            context.insert(try CompetitionSchemaV3.CoachingCycleRecord(transaction.cycle))
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

    func reset() async throws {
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

    private func saveContext() throws {
        do {
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
