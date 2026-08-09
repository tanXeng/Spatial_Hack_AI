import Foundation
import SwiftData

enum CompetitionSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            EventEditionRecord.self,
            CompetitionPlayerRecord.self,
            TechniqueAttemptRecord.self,
            AthleteSkillMemoryRecord.self,
            PendingTrainingRunRecord.self,
            CompetitionSubmissionRecord.self,
            EventAwardRecord.self
        ]
    }

    @Model
    final class EventEditionRecord {
        @Attribute(.unique) var id: UUID
        var title: String
        var statusRawValue: String
        var openedAt: Date
        var closedAt: Date?
        var scoringVersion: Int
        var calibrationVersion: Int

        init(
            id: UUID,
            title: String,
            statusRawValue: String,
            openedAt: Date,
            closedAt: Date?,
            scoringVersion: Int,
            calibrationVersion: Int
        ) {
            self.id = id
            self.title = title
            self.statusRawValue = statusRawValue
            self.openedAt = openedAt
            self.closedAt = closedAt
            self.scoringVersion = scoringVersion
            self.calibrationVersion = calibrationVersion
        }

        convenience init(_ event: EventEdition) {
            self.init(
                id: event.id,
                title: event.title,
                statusRawValue: event.status.rawValue,
                openedAt: event.openedAt,
                closedAt: event.closedAt,
                scoringVersion: event.scoringVersion,
                calibrationVersion: event.calibrationVersion
            )
        }

        var snapshot: EventEdition? {
            guard let status = EventEditionStatus(rawValue: statusRawValue) else { return nil }
            return EventEdition(
                id: id,
                title: title,
                status: status,
                openedAt: openedAt,
                closedAt: closedAt,
                scoringVersion: scoringVersion,
                calibrationVersion: calibrationVersion
            )
        }
    }

    /// The V2 participant entity intentionally retains the V1 entity name so SwiftData can
    /// map every existing player row before the custom `didMigrate` stage enriches it.
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
        var experienceLevelRawValue: String = ExperienceLevel.beginner.rawValue
        var eventID: UUID?
        var publicDisplayName: String?
        var publicDisplayCode: String?

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
            experienceLevelRawValue = player.experienceLevel.rawValue
            eventID = player.publicHandle?.eventID
            publicDisplayName = player.publicHandle?.displayName
            publicDisplayCode = player.publicHandle?.displayCode
        }

        var snapshot: CompetitionPlayer {
            CompetitionPlayer(
                id: id,
                name: name,
                normalizedName: normalizedName,
                rememberedStance: Stance(rawValue: stanceRawValue) ?? .orthodox,
                reach: leftReach.flatMap { left in
                    rightReach.flatMap { BilateralReach(left: left, right: $0) }
                },
                calibrationVersion: calibrationVersion,
                calibratedAt: calibratedAt,
                createdAt: createdAt,
                lastSeenAt: lastSeenAt,
                experienceLevel: ExperienceLevel(rawValue: experienceLevelRawValue) ?? .beginner,
                publicHandle: Self.publicHandle(
                    eventID: eventID,
                    displayName: publicDisplayName,
                    displayCode: publicDisplayCode
                )
            )
        }

        func apply(_ player: CompetitionPlayer) {
            normalizedName = player.normalizedName
            name = player.name
            stanceRawValue = player.rememberedStance.rawValue
            leftReach = player.reach?.left
            rightReach = player.reach?.right
            calibrationVersion = player.calibrationVersion
            calibratedAt = player.calibratedAt
            lastSeenAt = player.lastSeenAt
            experienceLevelRawValue = player.experienceLevel.rawValue
            eventID = player.publicHandle?.eventID
            publicDisplayName = player.publicHandle?.displayName
            publicDisplayCode = player.publicHandle?.displayCode
        }

        private static func publicHandle(
            eventID: UUID?,
            displayName: String?,
            displayCode: String?
        ) -> ParticipantPublicHandle? {
            guard let eventID, let displayName, let displayCode else { return nil }
            return ParticipantPublicHandle.reserving(
                eventID: eventID,
                displayName: displayName,
                displayCode: displayCode,
                against: []
            )
        }
    }

    @Model
    final class TechniqueAttemptRecord {
        @Attribute(.unique) var id: UUID
        var athleteID: UUID
        var eventID: UUID?
        var techniqueID: String
        var score: Float
        var scoringVersion: Int
        var calibrationVersion: Int?
        var startedAt: Date
        var completedAt: Date
        var publicDisplayName: String?
        var publicDisplayCode: String?

        init(_ attempt: TechniqueAttemptSnapshot) {
            id = attempt.id
            athleteID = attempt.athleteID
            eventID = attempt.eventID
            techniqueID = attempt.techniqueID
            score = attempt.score
            scoringVersion = attempt.scoringVersion
            calibrationVersion = attempt.calibrationVersion
            startedAt = attempt.startedAt
            completedAt = attempt.completedAt
            publicDisplayName = attempt.publicHandleSnapshot?.displayName
            publicDisplayCode = attempt.publicHandleSnapshot?.displayCode
        }

        var snapshot: TechniqueAttemptSnapshot? {
            TechniqueAttemptSnapshot(
                id: id,
                athleteID: athleteID,
                eventID: eventID,
                techniqueID: techniqueID,
                score: score,
                scoringVersion: scoringVersion,
                calibrationVersion: calibrationVersion,
                startedAt: startedAt,
                completedAt: completedAt,
                publicHandleSnapshot: publicHandle(
                    eventID: eventID,
                    displayName: publicDisplayName,
                    displayCode: publicDisplayCode
                )
            )
        }
    }

    @Model
    final class AthleteSkillMemoryRecord {
        @Attribute(.unique) var id: String
        var athleteID: UUID
        var techniqueID: String
        var experienceLevelRawValue: String
        var attemptIDs: [UUID]
        var pastSelfTraceData: Data?
        var updatedAt: Date

        init(_ memory: AthleteSkillMemory) throws {
            id = Self.key(athleteID: memory.athleteID, techniqueID: memory.techniqueID)
            athleteID = memory.athleteID
            techniqueID = memory.techniqueID
            experienceLevelRawValue = memory.experienceLevel.rawValue
            attemptIDs = memory.attempts.map(\.id)
            pastSelfTraceData = try memory.pastSelfTrace.map { try JSONEncoder().encode($0) }
            updatedAt = memory.updatedAt
        }

        func snapshot(attempts: [TechniqueAttemptSnapshot]) -> AthleteSkillMemory? {
            let attemptsByID = Dictionary(uniqueKeysWithValues: attempts.map { ($0.id, $0) })
            let orderedAttempts = attemptIDs.compactMap { attemptsByID[$0] }
            guard orderedAttempts.count == attemptIDs.count,
                  let experienceLevel = ExperienceLevel(rawValue: experienceLevelRawValue)
            else { return nil }

            let trace: PastSelfTrace?
            do {
                trace = try pastSelfTraceData.map { try JSONDecoder().decode(PastSelfTrace.self, from: $0) }
            } catch {
                return nil
            }
            return AthleteSkillMemory(
                athleteID: athleteID,
                techniqueID: techniqueID,
                experienceLevel: experienceLevel,
                attempts: orderedAttempts,
                pastSelfTrace: trace,
                updatedAt: updatedAt
            )
        }

        private static func key(athleteID: UUID, techniqueID: String) -> String {
            "\(athleteID.uuidString.lowercased())|\(techniqueID)"
        }
    }

    @Model
    final class PendingTrainingRunRecord {
        @Attribute(.unique) var id: UUID
        var athleteID: UUID
        var eventID: UUID?
        var techniqueID: String
        var requestedAt: Date

        init(_ run: PendingTrainingRun) {
            id = run.id
            athleteID = run.athleteID
            eventID = run.eventID
            techniqueID = run.techniqueID
            requestedAt = run.requestedAt
        }

        var snapshot: PendingTrainingRun? {
            PendingTrainingRun(
                id: id,
                athleteID: athleteID,
                eventID: eventID,
                techniqueID: techniqueID,
                requestedAt: requestedAt
            )
        }
    }

    /// This type likewise keeps the V1 entity name so UUIDs, timestamps, scores, and tie-break
    /// fields are mapped by SwiftData before V2 event provenance is added.
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
        var eventID: UUID?
        var scoringVersion: Int = 1
        var calibrationVersion: Int?
        var publicDisplayName: String?
        var publicDisplayCode: String?

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
            eventID = value.eventID
            scoringVersion = value.scoringVersion
            calibrationVersion = value.calibrationVersion
            publicDisplayName = value.publicHandleSnapshot?.displayName
            publicDisplayCode = value.publicHandleSnapshot?.displayCode
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
                trackingStatus: tracking,
                eventID: eventID,
                scoringVersion: scoringVersion,
                calibrationVersion: calibrationVersion,
                publicHandleSnapshot: publicHandle(
                    eventID: eventID,
                    displayName: publicDisplayName,
                    displayCode: publicDisplayCode
                )
            )
        }
    }

    @Model
    final class EventAwardRecord {
        @Attribute(.unique) var id: UUID
        var eventID: UUID
        var athleteID: UUID
        var publicDisplayName: String
        var publicDisplayCode: String
        var kindRawValue: String
        var attemptID: UUID?
        var awardedAt: Date

        init(_ award: EventAward) {
            id = award.id
            eventID = award.eventID
            athleteID = award.athleteID
            publicDisplayName = award.publicHandleSnapshot.displayName
            publicDisplayCode = award.publicHandleSnapshot.displayCode
            kindRawValue = award.kind.rawValue
            attemptID = award.attemptID
            awardedAt = award.awardedAt
        }

        var snapshot: EventAward? {
            guard let kind = EventAwardKind(rawValue: kindRawValue),
                  let handle = ParticipantPublicHandle.reserving(
                      eventID: eventID,
                      displayName: publicDisplayName,
                      displayCode: publicDisplayCode,
                      against: []
                  )
            else { return nil }
            return EventAward(
                id: id,
                eventID: eventID,
                athleteID: athleteID,
                publicHandleSnapshot: handle,
                kind: kind,
                attemptID: attemptID,
                awardedAt: awardedAt
            )
        }
    }

    private static func publicHandle(
        eventID: UUID?,
        displayName: String?,
        displayCode: String?
    ) -> ParticipantPublicHandle? {
        guard let eventID, let displayName, let displayCode else { return nil }
        return ParticipantPublicHandle.reserving(
            eventID: eventID,
            displayName: displayName,
            displayCode: displayCode,
            against: []
        )
    }
}
