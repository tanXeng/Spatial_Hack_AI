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
    static var schemas: [any VersionedSchema.Type] { [CompetitionSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum CompetitionModelContainer {
    static func make(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CompetitionSchemaV1.self)
        let configuration = ModelConfiguration(
            "BoxingCoachCompetitionV1",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            allowsSave: true,
            groupContainer: .automatic,
            cloudKitDatabase: .none
        )
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
    private let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func player(normalizedName: String) async throws -> CompetitionPlayer? {
        try context.fetch(FetchDescriptor<CompetitionPlayerRecord>())
            .first { $0.normalizedName == normalizedName }?.snapshot
    }

    func player(id: UUID) async throws -> CompetitionPlayer? {
        try playerRecord(id: id)?.snapshot
    }

    func save(player: CompetitionPlayer) async throws {
        if let existing = try playerRecord(id: player.id) {
            existing.apply(player)
        } else {
            context.insert(CompetitionPlayerRecord(player))
        }
        try saveContext()
    }

    func submit(_ submission: CompetitionSubmission) async throws -> CompetitionSubmission {
        if let existing = try submissionRecord(id: submission.id)?.snapshot { return existing }
        guard try playerRecord(id: submission.playerID) != nil else {
            throw CompetitionRepositoryError.playerNotFound
        }
        context.insert(CompetitionSubmissionRecord(submission))
        try saveContext()
        return submission
    }

    func submissions() async throws -> [CompetitionSubmission] {
        try context.fetch(FetchDescriptor<CompetitionSubmissionRecord>())
            .compactMap(\.snapshot)
            .sorted { $0.endedAt > $1.endedAt }
    }

    func reset() async throws {
        try context.delete(model: CompetitionSubmissionRecord.self)
        try context.delete(model: CompetitionPlayerRecord.self)
        try saveContext()
    }

    private func playerRecord(id: UUID) throws -> CompetitionPlayerRecord? {
        try context.fetch(FetchDescriptor<CompetitionPlayerRecord>()).first { $0.id == id }
    }

    private func submissionRecord(id: UUID) throws -> CompetitionSubmissionRecord? {
        try context.fetch(FetchDescriptor<CompetitionSubmissionRecord>()).first { $0.id == id }
    }

    private func saveContext() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw CompetitionRepositoryError.saveFailed("Competition data could not be saved. Nothing was changed.")
        }
    }
}
