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
    func player(normalizedName: String) async throws -> CompetitionPlayer?
    func player(id: UUID) async throws -> CompetitionPlayer?
    func save(player: CompetitionPlayer) async throws
    func submit(_ submission: CompetitionSubmission) async throws -> CompetitionSubmission
    func submissions() async throws -> [CompetitionSubmission]
    func reset() async throws
}

@MainActor
final class InMemoryCompetitionRepository: CompetitionRepository {
    private var players: [UUID: CompetitionPlayer] = [:]
    private var values: [UUID: CompetitionSubmission] = [:]

    func player(normalizedName: String) async throws -> CompetitionPlayer? {
        players.values.first { $0.normalizedName == normalizedName }
    }

    func player(id: UUID) async throws -> CompetitionPlayer? { players[id] }

    func save(player: CompetitionPlayer) async throws { players[player.id] = player }

    func submit(_ submission: CompetitionSubmission) async throws -> CompetitionSubmission {
        if let existing = values[submission.id] { return existing }
        guard players[submission.playerID] != nil else { throw CompetitionRepositoryError.playerNotFound }
        values[submission.id] = submission
        return submission
    }

    func submissions() async throws -> [CompetitionSubmission] {
        values.values.sorted { $0.endedAt > $1.endedAt }
    }

    func reset() async throws {
        players.removeAll()
        values.removeAll()
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
        [CompetitionSchemaV1.self, CompetitionSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: CompetitionSchemaV1.self,
                toVersion: CompetitionSchemaV2.self,
                willMigrate: nil,
                didMigrate: CompetitionLegacyMigration.migrate
            )
        ]
    }
}

enum CompetitionModelContainer {
    static let configurationName = "BoxingCoachAthleteMemory"
    private static let legacyConfigurationName = "BoxingCoachCompetitionV1"

    static func make(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CompetitionSchemaV2.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(
                configurationName,
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: true,
                groupContainer: .automatic,
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                configurationName,
                schema: schema,
                url: legacyStoreURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
        }
        return try make(schema: schema, configuration: configuration)
    }

    static func make(storeURL: URL, allowsSave: Bool = true) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CompetitionSchemaV2.self)
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
        // Keep the shipped V1 file URL while giving the V2 configuration a version-neutral name.
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

    init(container: ModelContainer) {
        self.container = container
        context = Self.makeContext(container: container)
    }

    func player(normalizedName: String) async throws -> CompetitionPlayer? {
        try context.fetch(FetchDescriptor<CompetitionSchemaV2.CompetitionPlayerRecord>())
            .first { $0.normalizedName == normalizedName }?.snapshot
    }

    func player(id: UUID) async throws -> CompetitionPlayer? {
        try playerRecord(id: id)?.snapshot
    }

    func save(player: CompetitionPlayer) async throws {
        if let existing = try playerRecord(id: player.id) {
            existing.apply(player)
        } else {
            context.insert(CompetitionSchemaV2.CompetitionPlayerRecord(player))
        }
        try saveContext()
    }

    func submit(_ submission: CompetitionSubmission) async throws -> CompetitionSubmission {
        if let existing = try submissionRecord(id: submission.id)?.snapshot { return existing }
        guard try playerRecord(id: submission.playerID) != nil else {
            throw CompetitionRepositoryError.playerNotFound
        }
        context.insert(CompetitionSchemaV2.CompetitionSubmissionRecord(submission))
        try saveContext()
        return submission
    }

    func submissions() async throws -> [CompetitionSubmission] {
        try context.fetch(FetchDescriptor<CompetitionSchemaV2.CompetitionSubmissionRecord>())
            .compactMap(\.snapshot)
            .sorted { $0.endedAt > $1.endedAt }
    }

    func reset() async throws {
        try context.delete(model: CompetitionSchemaV2.CompetitionSubmissionRecord.self)
        try context.delete(model: CompetitionSchemaV2.CompetitionPlayerRecord.self)
        try saveContext()
    }

    private func playerRecord(id: UUID) throws -> CompetitionSchemaV2.CompetitionPlayerRecord? {
        try context.fetch(FetchDescriptor<CompetitionSchemaV2.CompetitionPlayerRecord>())
            .first { $0.id == id }
    }

    private func submissionRecord(id: UUID) throws -> CompetitionSchemaV2.CompetitionSubmissionRecord? {
        try context.fetch(FetchDescriptor<CompetitionSchemaV2.CompetitionSubmissionRecord>())
            .first { $0.id == id }
    }

    private func saveContext() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            context = Self.makeContext(container: container)
            throw CompetitionRepositoryError.saveFailed("Competition data could not be saved. Nothing was changed.")
        }
    }

    private static func makeContext(container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }
}

nonisolated enum CompetitionLegacyMigration {
    static let eventID = UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!
    private static let legacyScoringVersion = 1

    static func migrate(_ context: ModelContext) throws {
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

            try context.save()
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
