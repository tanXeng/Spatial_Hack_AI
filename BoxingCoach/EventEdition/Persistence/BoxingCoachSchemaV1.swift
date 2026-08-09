import Foundation
import SwiftData

enum BoxingCoachSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static let models: [any PersistentModel.Type] = [
        EventRecord.self,
        ParticipantRecord.self,
        EventEntryRecord.self,
        TrainingRunRecord.self,
        AwardRecord.self
    ]
}

enum BoxingCoachMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [BoxingCoachSchemaV1.self]
    static let stages: [MigrationStage] = []
}

@Model
final class EventRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var timeZoneIdentifier: String
    var statusRawValue: String
    var createdAt: Date
    var startedAt: Date?
    var closedAt: Date?
    var challengeID: String
    var scoringVersion: Int
    var rulesData: Data
    var rulesDigest: String
    var maxOfficialAttempts: Int

    init(snapshot: EventSnapshot) {
        id = snapshot.id
        title = snapshot.title
        timeZoneIdentifier = snapshot.timeZoneIdentifier
        statusRawValue = snapshot.status.rawValue
        createdAt = snapshot.createdAt
        startedAt = snapshot.startedAt
        closedAt = snapshot.closedAt
        challengeID = snapshot.challengeID
        scoringVersion = snapshot.scoringVersion
        rulesData = snapshot.rulesData
        rulesDigest = snapshot.rulesDigest
        maxOfficialAttempts = snapshot.maxOfficialAttempts
    }

    var snapshot: EventSnapshot {
        EventSnapshot(
            id: id,
            title: title,
            timeZoneIdentifier: timeZoneIdentifier,
            status: EventStatus(rawValue: statusRawValue) ?? .draft,
            createdAt: createdAt,
            startedAt: startedAt,
            closedAt: closedAt,
            challengeID: challengeID,
            scoringVersion: scoringVersion,
            rulesData: rulesData,
            rulesDigest: rulesDigest,
            maxOfficialAttempts: maxOfficialAttempts
        )
    }
}

@Model
final class ParticipantRecord {
    @Attribute(.unique) var id: UUID
    var alias: String
    var normalizedAlias: String
    var avatarID: String
    var preferredStanceRawValue: String
    var createdAt: Date
    var lastSeenAt: Date
    var archived: Bool

    init(
        id: UUID,
        alias: String,
        normalizedAlias: String,
        avatarID: String,
        stance: Stance,
        createdAt: Date,
        lastSeenAt: Date,
        archived: Bool = false
    ) {
        self.id = id
        self.alias = alias
        self.normalizedAlias = normalizedAlias
        self.avatarID = avatarID
        preferredStanceRawValue = stance.rawValue
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.archived = archived
    }
}

@Model
final class EventEntryRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var eventParticipantKey: String
    var eventID: UUID
    var participantID: UUID
    var competitorNumber: Int
    var isLeaderboardPublic: Bool
    var lessonCompletedAt: Date?
    var coachOverrideAt: Date?
    var coachOverrideHostID: UUID?

    init(
        id: UUID,
        eventID: UUID,
        participantID: UUID,
        competitorNumber: Int,
        isLeaderboardPublic: Bool,
        lessonCompletedAt: Date? = nil,
        coachOverrideAt: Date? = nil,
        coachOverrideHostID: UUID? = nil
    ) {
        self.id = id
        eventParticipantKey = Self.key(eventID: eventID, participantID: participantID)
        self.eventID = eventID
        self.participantID = participantID
        self.competitorNumber = competitorNumber
        self.isLeaderboardPublic = isLeaderboardPublic
        self.lessonCompletedAt = lessonCompletedAt
        self.coachOverrideAt = coachOverrideAt
        self.coachOverrideHostID = coachOverrideHostID
    }

    static func key(eventID: UUID, participantID: UUID) -> String {
        "\(eventID.uuidString.lowercased()):\(participantID.uuidString.lowercased())"
    }
}

@Model
final class TrainingRunRecord {
    @Attribute(.unique) var id: UUID
    var eventID: UUID
    var participantID: UUID?
    var entryID: UUID?
    var aliasSnapshot: String?
    var avatarIDSnapshot: String?
    var planRawValue: String
    var statusRawValue: String
    var stanceRawValue: String
    var startedAt: Date
    var endedAt: Date?
    var officialOrdinal: Int?
    var eligibilityReasonRawValue: String
    var rulesDigest: String
    var totalPoints: Int
    var contactPoints: Int
    var accuracyPoints: Int
    var guardPoints: Int
    var trackingSummary: String
    var appVersion: String
    var buildVersion: String
    var visionOSVersion: String
    var snapshotData: Data?
    var checkpointData: Data?
    var checkpointStageID: String?
    var checkpointAt: Date?
    var voided: Bool

    init(context: TrainingRunContext, appVersion: String, buildVersion: String, visionOSVersion: String) {
        id = context.runID
        eventID = context.eventID
        participantID = context.participantID
        entryID = context.entryID
        aliasSnapshot = context.aliasSnapshot
        avatarIDSnapshot = context.avatarIDSnapshot
        planRawValue = context.plan.rawValue
        statusRawValue = TrainingRunStatus.inProgress.rawValue
        stanceRawValue = context.stance.rawValue
        startedAt = context.startedAt
        officialOrdinal = context.officialOrdinal
        eligibilityReasonRawValue = EligibilityReason.unofficial.rawValue
        rulesDigest = context.rulesDigest
        totalPoints = 0
        contactPoints = 0
        accuracyPoints = 0
        guardPoints = 0
        trackingSummary = ""
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.visionOSVersion = visionOSVersion
        voided = false
    }

    func apply(_ snapshot: TrainingRunSnapshot, encoded: Data) {
        statusRawValue = snapshot.status.rawValue
        endedAt = snapshot.endedAt
        eligibilityReasonRawValue = snapshot.eligibilityReason.rawValue
        trackingSummary = snapshot.trackingSummary
        snapshotData = encoded
        voided = snapshot.voided
        let score = ChallengeScorer.score(snapshot)
        totalPoints = score.totalPoints
        contactPoints = score.contactPoints
        accuracyPoints = score.accuracyPoints
        guardPoints = score.guardPoints
    }
}

@Model
final class AwardRecord {
    @Attribute(.unique) var id: UUID
    var eventID: UUID
    var categoryRawValue: String
    var rank: Int
    var participantID: UUID
    var winningRunID: UUID
    var aliasSnapshot: String
    var avatarIDSnapshot: String
    var displayedValue: Int
    var declaredAt: Date
    var rulesDigest: String
    var tieExplanation: String?

    init(_ snapshot: AwardSnapshot) {
        id = snapshot.id
        eventID = snapshot.eventID
        categoryRawValue = snapshot.category.rawValue
        rank = snapshot.rank
        participantID = snapshot.participantID
        winningRunID = snapshot.winningRunID
        aliasSnapshot = snapshot.aliasSnapshot
        avatarIDSnapshot = snapshot.avatarIDSnapshot
        displayedValue = snapshot.displayedValue
        declaredAt = snapshot.declaredAt
        rulesDigest = snapshot.rulesDigest
        tieExplanation = snapshot.tieExplanation
    }

    var snapshot: AwardSnapshot? {
        guard let category = LeaderboardCategory(rawValue: categoryRawValue) else { return nil }
        return AwardSnapshot(
            id: id,
            eventID: eventID,
            category: category,
            rank: rank,
            participantID: participantID,
            winningRunID: winningRunID,
            aliasSnapshot: aliasSnapshot,
            avatarIDSnapshot: avatarIDSnapshot,
            displayedValue: displayedValue,
            declaredAt: declaredAt,
            rulesDigest: rulesDigest,
            tieExplanation: tieExplanation
        )
    }
}

enum BoxingCoachModelContainer {
    static func make(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: BoxingCoachSchemaV1.self)
        let configuration = ModelConfiguration(
            "BoxingCoachEventEdition",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            allowsSave: true,
            groupContainer: .automatic,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: BoxingCoachMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
