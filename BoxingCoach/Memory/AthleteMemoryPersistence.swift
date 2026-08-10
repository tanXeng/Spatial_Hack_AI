import Foundation
import SwiftData

nonisolated private enum AthleteMemoryPersistenceError: Error {
    case incompatibleMemoryKey
    case incompatibleRunIdentity
}

enum CompetitionSchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            EventEditionRecord.self,
            CompetitionPlayerRecord.self,
            TechniqueAttemptRecord.self,
            AthleteSkillMemoryRecord.self,
            CoachingCycleRecord.self,
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

    /// V3 retains the participant entity name so SwiftData maps every immutable V2 row.
    @Model
    final class CompetitionPlayerRecord {
        @Attribute(.unique) var id: UUID
        var normalizedName: String
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
        var snapshotData: Data?

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
            snapshotData = try? JSONEncoder().encode(attempt)
        }

        var snapshot: TechniqueAttemptSnapshot? {
            if let snapshotData {
                guard let decoded = try? JSONDecoder().decode(
                    TechniqueAttemptSnapshot.self,
                    from: snapshotData
                ),
                      decoded.id == id,
                      decoded.athleteID == athleteID,
                      decoded.eventID == eventID,
                      decoded.techniqueID == techniqueID,
                      decoded.score == score,
                      decoded.scoringVersion == scoringVersion,
                      decoded.calibrationVersion == calibrationVersion,
                      decoded.startedAt == startedAt,
                      decoded.completedAt == completedAt,
                      decoded.publicHandleSnapshot?.displayName == publicDisplayName,
                      decoded.publicHandleSnapshot?.displayCode == publicDisplayCode,
                      decoded.publicHandleSnapshot == publicHandle(
                          eventID: eventID,
                          displayName: publicDisplayName,
                          displayCode: publicDisplayCode
                      )
                else { return nil }
                return decoded
            }
            return TechniqueAttemptSnapshot(
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
            id = memory.key.storageKey
            athleteID = memory.athleteID
            techniqueID = memory.techniqueID
            experienceLevelRawValue = memory.experienceLevel.rawValue
            attemptIDs = memory.attempts.map(\.id)
            pastSelfTraceData = try memory.pastSelfTrace.map { try JSONEncoder().encode($0) }
            updatedAt = memory.updatedAt
        }

        func apply(_ memory: AthleteSkillMemory) throws {
            guard id == memory.key.storageKey else {
                throw AthleteMemoryPersistenceError.incompatibleMemoryKey
            }
            athleteID = memory.athleteID
            techniqueID = memory.techniqueID
            experienceLevelRawValue = memory.experienceLevel.rawValue
            attemptIDs = memory.attempts.map(\.id)
            pastSelfTraceData = try memory.pastSelfTrace.map { try JSONEncoder().encode($0) }
            updatedAt = memory.updatedAt
        }

        func snapshot(attempts: [TechniqueAttemptSnapshot]) -> AthleteSkillMemory? {
            let keys = Set(attempts.compactMap(\.memoryKey))
            guard keys.count == 1,
                  let key = keys.first,
                  id == key.storageKey,
                  athleteID == key.athleteID,
                  techniqueID == key.techniqueID,
                  let experienceLevel = ExperienceLevel(rawValue: experienceLevelRawValue),
                  let rebuilt = AthleteSkillMemory.rebuilding(
                      key: key,
                      experienceLevel: experienceLevel,
                      from: attempts
                  )
            else { return nil }

            let storedTrace: PastSelfTrace?
            do {
                storedTrace = try pastSelfTraceData.map {
                    try JSONDecoder().decode(PastSelfTrace.self, from: $0)
                }
            } catch {
                return nil
            }
            guard attemptIDs == rebuilt.attempts.map(\.id),
                  storedTrace == rebuilt.pastSelfTrace,
                  updatedAt == rebuilt.updatedAt
            else { return nil }
            return rebuilt
        }
    }

    @Model
    final class PendingTrainingRunRecord {
        @Attribute(.unique) var id: UUID
        var athleteID: UUID
        var eventID: UUID?
        var techniqueID: String
        var requestedAt: Date
        var snapshotData: Data?

        init(_ run: PendingTrainingRun) {
            id = run.id
            athleteID = run.athleteID
            eventID = run.eventID
            techniqueID = run.techniqueID
            requestedAt = run.requestedAt
            snapshotData = TrainingRunSnapshot(run).flatMap { try? JSONEncoder().encode($0) }
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

        var runSnapshot: TrainingRunSnapshot? {
            if let snapshotData {
                guard let decoded = try? JSONDecoder().decode(
                    TrainingRunSnapshot.self,
                    from: snapshotData
                ),
                      decoded.id == id,
                      decoded.athleteID == athleteID,
                      decoded.eventID == eventID,
                      decoded.techniqueID == techniqueID,
                      decoded.requestedAt == requestedAt
                else { return nil }
                return decoded
            }
            return snapshot.flatMap(TrainingRunSnapshot.init)
        }

        func apply(_ run: TrainingRunSnapshot) throws {
            guard run.id == id,
                  run.athleteID == athleteID,
                  run.eventID == eventID,
                  run.techniqueID == techniqueID,
                  run.requestedAt == requestedAt
            else { throw AthleteMemoryPersistenceError.incompatibleRunIdentity }
            snapshotData = try JSONEncoder().encode(run)
        }
    }

    /// V3 likewise keeps the submission entity name so V2 history maps without identity loss.
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

/// Reconstructable coaching-cycle memory stored alongside the existing V3 athlete-memory models.
extension CompetitionSchemaV3 {
    @Model
    final class CoachingCycleRecord {
        @Attribute(.unique) var id: UUID
        var athleteID: UUID
        var techniqueID: String
        var snapshotData: Data

        init(_ snapshot: CoachingCycleSnapshot) throws {
            id = snapshot.id
            athleteID = snapshot.athleteID
            techniqueID = snapshot.techniqueID
            snapshotData = try JSONEncoder().encode(snapshot)
        }

        var snapshot: CoachingCycleSnapshot? {
            try? JSONDecoder().decode(CoachingCycleSnapshot.self, from: snapshotData)
        }
    }
}

/// V4 adds a sidecar payload for crash-safe coaching completion. Every shipped V3 model type is
/// reused unchanged, preserving the V3 schema checksum and its migration contract.
enum CompetitionSchemaV4: VersionedSchema {
    static var versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        CompetitionSchemaV3.models + [
            TrainingRunDescriptorRecord.self,
            CoachingRunCompletionRecord.self,
        ]
    }

    @Model
    final class TrainingRunDescriptorRecord {
        @Attribute(.unique) var runID: UUID
        var descriptorData: Data
        var resultAcknowledgedAt: Date?

        init(_ descriptor: DurableTrainingRunDescriptor) throws {
            runID = descriptor.runID
            descriptorData = try JSONEncoder().encode(descriptor)
            resultAcknowledgedAt = nil
        }

        var descriptor: DurableTrainingRunDescriptor? {
            guard let decoded = try? JSONDecoder().decode(
                DurableTrainingRunDescriptor.self,
                from: descriptorData
            ), decoded.runID == runID else { return nil }
            return decoded
        }
    }

    @Model
    final class CoachingRunCompletionRecord {
        @Attribute(.unique) var runID: UUID
        var transactionData: Data

        init(runID: UUID, transaction: CoachingCycleMemoryTransaction) throws {
            self.runID = runID
            transactionData = try JSONEncoder().encode(transaction)
        }

        var transaction: CoachingCycleMemoryTransaction? {
            guard let decoded = try? JSONDecoder().decode(
                CoachingCycleMemoryTransaction.self,
                from: transactionData
            ), decoded.cycle.id == runID else { return nil }
            return decoded
        }
    }
}

nonisolated enum CompetitionRunV4Migration {
    static func migrate(_ context: ModelContext) throws {
        let runs = try context.fetch(
            FetchDescriptor<CompetitionSchemaV3.PendingTrainingRunRecord>()
        )
        let existing = try context.fetch(
            FetchDescriptor<CompetitionSchemaV4.TrainingRunDescriptorRecord>()
        )
        let existingIDs = Set(existing.map(\.runID))
        for run in runs where !existingIDs.contains(run.id) {
            context.insert(try CompetitionSchemaV4.TrainingRunDescriptorRecord(
                .legacy(runID: run.id)
            ))
        }
        try context.save()
    }
}
