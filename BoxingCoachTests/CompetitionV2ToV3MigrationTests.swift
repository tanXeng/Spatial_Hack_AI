import Foundation
import SwiftData
import Testing
@testable import BoxingCoach

@Suite("Competition V2 to V3 migration")
@MainActor
struct CompetitionV2ToV3MigrationTests {
    @Test("Shipped V2 rows preserve trace evidence while their derived cache is rebuilt")
    func shippedV2StoreMigratesToV3AndReopens() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CompetitionV2ToV3MigrationTests-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let storeURL = directoryURL.appendingPathComponent("competition.store")
        let fixture = try makeFixture()
        let priorTrace = try #require(fixture.memory.pastSelfTrace)
        let expectedAttempt = try #require(migratedAttempt(
            fixture.attempt,
            preserving: priorTrace
        ))
        let key = try #require(expectedAttempt.memoryKey)
        let expectedMemory = try #require(AthleteSkillMemory.rebuilding(
            key: key,
            experienceLevel: fixture.participant.experienceLevel,
            from: [expectedAttempt]
        ))

        try autoreleasepool {
            let schema = Schema(versionedSchema: CompetitionSchemaV2.self)
            let configuration = ModelConfiguration(
                "CompetitionV2Fixture",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(CompetitionSchemaV2.EventEditionRecord(fixture.event))
            context.insert(CompetitionSchemaV2.CompetitionPlayerRecord(fixture.participant))
            context.insert(CompetitionSchemaV2.TechniqueAttemptRecord(fixture.attempt))
            context.insert(try CompetitionSchemaV2.AthleteSkillMemoryRecord(fixture.memory))
            context.insert(CompetitionSchemaV2.PendingTrainingRunRecord(fixture.pendingRun))
            context.insert(CompetitionSchemaV2.CompetitionSubmissionRecord(fixture.submission))
            context.insert(CompetitionSchemaV2.EventAwardRecord(fixture.award))
            try context.save()
            #expect(try context.fetchCount(
                FetchDescriptor<CompetitionSchemaV2.AthleteSkillMemoryRecord>()
            ) == 1)
        }

        try autoreleasepool {
            let container = try CompetitionModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            let events = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.EventEditionRecord>()
            )
            let participants = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.CompetitionPlayerRecord>()
            )
            let attempts = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.TechniqueAttemptRecord>()
            )
            let runs = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.PendingTrainingRunRecord>()
            )
            let submissions = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.CompetitionSubmissionRecord>()
            )
            let awards = try context.fetch(
                FetchDescriptor<CompetitionSchemaV3.EventAwardRecord>()
            )

            #expect(events.count == 1)
            #expect(events.first?.snapshot == fixture.event)
            #expect(participants.count == 1)
            #expect(participants.first?.snapshot == fixture.participant)
            #expect(attempts.count == 1)
            #expect(attempts.first?.snapshot == expectedAttempt)
            #expect(attempts.first?.snapshotData != nil)
            #expect(runs.count == 1)
            #expect(runs.first?.snapshot == fixture.pendingRun)
            #expect(runs.first?.runSnapshot == TrainingRunSnapshot(fixture.pendingRun))
            #expect(runs.first?.snapshotData == nil)
            #expect(submissions.count == 1)
            #expect(submissions.first?.snapshot == fixture.submission)
            #expect(awards.count == 1)
            #expect(awards.first?.snapshot == fixture.award)
            #expect(try context.fetchCount(
                FetchDescriptor<CompetitionSchemaV3.AthleteSkillMemoryRecord>()
            ) == 0)

            let repository = SwiftDataAthleteMemoryRepository(container: container)
            let rebuilt = try #require(try repository.rebuildMemory(for: key))
            #expect(rebuilt == expectedMemory)
            #expect(rebuilt.pastSelfTrace == priorTrace)
        }

        try autoreleasepool {
            let reopened = try CompetitionModelContainer.make(storeURL: storeURL)
            let context = ModelContext(reopened)
            #expect(try context.fetchCount(
                FetchDescriptor<CompetitionSchemaV3.EventEditionRecord>()
            ) == 1)
            #expect(try context.fetchCount(
                FetchDescriptor<CompetitionSchemaV3.CompetitionPlayerRecord>()
            ) == 1)
            #expect(try context.fetchCount(
                FetchDescriptor<CompetitionSchemaV3.TechniqueAttemptRecord>()
            ) == 1)
            #expect(try context.fetchCount(
                FetchDescriptor<CompetitionSchemaV3.PendingTrainingRunRecord>()
            ) == 1)
            #expect(try context.fetchCount(
                FetchDescriptor<CompetitionSchemaV3.CompetitionSubmissionRecord>()
            ) == 1)
            #expect(try context.fetchCount(
                FetchDescriptor<CompetitionSchemaV3.EventAwardRecord>()
            ) == 1)
            #expect(try context.fetchCount(
                FetchDescriptor<CompetitionSchemaV3.AthleteSkillMemoryRecord>()
            ) == 1)

            let repository = SwiftDataAthleteMemoryRepository(container: reopened)
            #expect(try repository.attempts(for: key) == [expectedAttempt])
            #expect(try repository.memory(for: key) == expectedMemory)
            #expect(try repository.memory(for: key)?.pastSelfTrace == priorTrace)
        }
    }

    @Test("Malformed V2 trace data rejects migration without changing the V2 store")
    func malformedTraceRejectsMigrationWithoutLoss() throws {
        try assertTraceMigrationRejected(.malformed)
    }

    @Test("Orphaned V2 trace data rejects migration without changing the V2 store")
    func orphanTraceRejectsMigrationWithoutLoss() throws {
        try assertTraceMigrationRejected(.orphan)
    }

    private func makeFixture() throws -> V2Fixture {
        let event = try #require(EventEdition(
            id: migrationV2ID(1),
            title: "Shipped V2 Event",
            status: .open,
            openedAt: migrationV2Date(1),
            closedAt: nil,
            scoringVersion: 2,
            calibrationVersion: 1
        ))
        let handle = try #require(ParticipantPublicHandle.reserving(
            eventID: event.id,
            displayName: "Alex",
            displayCode: "0200",
            against: []
        ))
        let participant = CompetitionPlayer(
            id: migrationV2ID(2),
            name: "Alex",
            normalizedName: "alex",
            rememberedStance: .orthodox,
            reach: BilateralReach(left: 0.64, right: 0.68),
            calibrationVersion: 1,
            calibratedAt: migrationV2Date(2),
            createdAt: migrationV2Date(1),
            lastSeenAt: migrationV2Date(3),
            experienceLevel: .intermediate,
            publicHandle: handle
        )
        let attempt = try #require(TechniqueAttemptSnapshot(
            id: migrationV2ID(3),
            athleteID: participant.id,
            eventID: event.id,
            techniqueID: Technique.jab.id,
            score: 84,
            scoringVersion: event.scoringVersion,
            calibrationVersion: participant.calibrationVersion,
            startedAt: migrationV2Date(10),
            completedAt: migrationV2Date(11),
            publicHandleSnapshot: handle
        ))
        let trace = try #require(PastSelfTrace(
            attemptID: attempt.id,
            coordinateSpace: .normalizedBody,
            samples: [
                NormalizedTraceSample(time: 0, position: SIMD3(0.1, 0.2, 0.3)),
                NormalizedTraceSample(time: 1, position: SIMD3(0.7, 0.4, 0.2))
            ]
        ))
        let memory = try #require(AthleteSkillMemory(
            athleteID: participant.id,
            techniqueID: attempt.techniqueID,
            experienceLevel: participant.experienceLevel,
            attempts: [attempt],
            pastSelfTrace: trace,
            updatedAt: attempt.completedAt
        ))
        let pendingRun = try #require(PendingTrainingRun(
            id: migrationV2ID(4),
            athleteID: participant.id,
            eventID: event.id,
            techniqueID: Technique.cross.id,
            requestedAt: migrationV2Date(12)
        ))
        let submission = CompetitionSubmission(
            id: migrationV2ID(5),
            playerID: participant.id,
            playerName: participant.name,
            normalizedPlayerName: participant.normalizedName,
            mode: .reactiveStrike,
            score: 91,
            validSteps: 7,
            totalSteps: 8,
            completedRepetitions: 0,
            meanCentreErrorMeters: 0.02,
            speedTieBreakSeconds: 0.31,
            startedAt: migrationV2Date(20),
            endedAt: migrationV2Date(21),
            trackingStatus: .complete,
            eventID: event.id,
            scoringVersion: event.scoringVersion,
            calibrationVersion: participant.calibrationVersion,
            publicHandleSnapshot: handle
        )
        let award = try #require(EventAward(
            id: migrationV2ID(6),
            eventID: event.id,
            athleteID: participant.id,
            publicHandleSnapshot: handle,
            kind: .personalBest,
            attemptID: attempt.id,
            awardedAt: migrationV2Date(22)
        ))
        return V2Fixture(
            event: event,
            participant: participant,
            attempt: attempt,
            memory: memory,
            pendingRun: pendingRun,
            submission: submission,
            award: award
        )
    }

    private func migratedAttempt(
        _ attempt: TechniqueAttemptSnapshot,
        preserving trace: PastSelfTrace
    ) -> TechniqueAttemptSnapshot? {
        TechniqueAttemptSnapshot(
            id: attempt.id,
            athleteID: attempt.athleteID,
            eventID: attempt.eventID,
            coachingCycleID: nil,
            stage: .practice,
            techniqueID: attempt.techniqueID,
            stance: .orthodox,
            score: attempt.score,
            metrics: [],
            trackedFraction: 1,
            duration: attempt.completedAt.timeIntervalSince(attempt.startedAt),
            isValid: true,
            wrongHand: false,
            scoringVersion: attempt.scoringVersion,
            referenceVersion: 1,
            calibrationVersion: attempt.calibrationVersion,
            correctionCode: nil,
            baselineAttemptID: nil,
            startedAt: attempt.startedAt,
            completedAt: attempt.completedAt,
            pastSelfTrace: trace,
            publicHandleSnapshot: attempt.publicHandleSnapshot
        )
    }

    private func assertTraceMigrationRejected(_ corruption: V2TraceCorruption) throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CompetitionV2TraceRejectionTests-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let storeURL = directoryURL.appendingPathComponent("competition.store")
        let fixture = try makeFixture()
        let corruptTraceData: Data
        switch corruption {
        case .malformed:
            corruptTraceData = Data("not-json".utf8)
        case .orphan:
            let orphanTrace = try #require(PastSelfTrace(
                attemptID: migrationV2ID(99),
                coordinateSpace: .normalizedBody,
                samples: [NormalizedTraceSample(time: 0, position: .zero)]
            ))
            corruptTraceData = try JSONEncoder().encode(orphanTrace)
        }

        try autoreleasepool {
            let schema = Schema(versionedSchema: CompetitionSchemaV2.self)
            let configuration = ModelConfiguration(
                "CompetitionV2RejectedTraceFixture",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(CompetitionSchemaV2.EventEditionRecord(fixture.event))
            context.insert(CompetitionSchemaV2.CompetitionPlayerRecord(fixture.participant))
            context.insert(CompetitionSchemaV2.TechniqueAttemptRecord(fixture.attempt))
            let cache = try CompetitionSchemaV2.AthleteSkillMemoryRecord(fixture.memory)
            cache.pastSelfTraceData = corruptTraceData
            context.insert(cache)
            context.insert(CompetitionSchemaV2.PendingTrainingRunRecord(fixture.pendingRun))
            context.insert(CompetitionSchemaV2.CompetitionSubmissionRecord(fixture.submission))
            context.insert(CompetitionSchemaV2.EventAwardRecord(fixture.award))
            try context.save()
        }

        var migrationWasRejected = false
        do {
            try autoreleasepool {
                _ = try CompetitionModelContainer.make(storeURL: storeURL)
            }
        } catch {
            migrationWasRejected = true
        }
        #expect(migrationWasRejected)

        try autoreleasepool {
            let schema = Schema(versionedSchema: CompetitionSchemaV2.self)
            let configuration = ModelConfiguration(
                "CompetitionV2RejectedTraceVerification",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let events = try context.fetch(FetchDescriptor<CompetitionSchemaV2.EventEditionRecord>())
            let participants = try context.fetch(
                FetchDescriptor<CompetitionSchemaV2.CompetitionPlayerRecord>()
            )
            let attempts = try context.fetch(
                FetchDescriptor<CompetitionSchemaV2.TechniqueAttemptRecord>()
            )
            let caches = try context.fetch(
                FetchDescriptor<CompetitionSchemaV2.AthleteSkillMemoryRecord>()
            )
            #expect(events.map(\.snapshot) == [fixture.event])
            #expect(participants.map(\.snapshot) == [fixture.participant])
            #expect(attempts.compactMap(\.snapshot) == [fixture.attempt])
            #expect(caches.count == 1)
            #expect(caches.first?.attemptIDs == [fixture.attempt.id])
            #expect(caches.first?.pastSelfTraceData == corruptTraceData)
            #expect(try context.fetchCount(
                FetchDescriptor<CompetitionSchemaV2.PendingTrainingRunRecord>()
            ) == 1)
            #expect(try context.fetchCount(
                FetchDescriptor<CompetitionSchemaV2.CompetitionSubmissionRecord>()
            ) == 1)
            #expect(try context.fetchCount(
                FetchDescriptor<CompetitionSchemaV2.EventAwardRecord>()
            ) == 1)
        }
    }
}

private enum V2TraceCorruption {
    case malformed
    case orphan
}

private struct V2Fixture {
    let event: EventEdition
    let participant: CompetitionPlayer
    let attempt: TechniqueAttemptSnapshot
    let memory: AthleteSkillMemory
    let pendingRun: PendingTrainingRun
    let submission: CompetitionSubmission
    let award: EventAward
}

private func migrationV2Date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func migrationV2ID(_ suffix: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, suffix))
}
