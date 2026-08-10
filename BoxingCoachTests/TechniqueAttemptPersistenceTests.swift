import Foundation
import SwiftData
import Testing
@testable import BoxingCoach

@Suite("Durable coaching proof")
@MainActor
struct TechniqueAttemptPersistenceTests {
    @Test("Aura reservation durably binds kind, track, stance, and technique")
    func auraDescriptorIsBoundAtReservation() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository)
        await store.bootstrap()
        let runID = UUID(uuidString: "00000000-0000-0000-0000-00000000E500")!
        _ = try await store.reserveAuraRun(.aura(
            track: .technicalCamp,
            technique: .uppercut,
            stance: .southpaw
        ), id: runID)

        #expect(try await repository.trainingRunDescriptor(id: runID) ==
            DurableTrainingRunDescriptor.aura(
                runID: runID,
                track: .technicalCamp,
                technique: .uppercut,
                stance: .southpaw
            ))
    }

    @Test("Session-only fallback blocks proof Aura before immersion")
    func sessionOnlyFallbackBlocksAuraReservation() async throws {
        let store = CompetitionStore(
            repository: InMemoryCompetitionRepository(),
            coachingCyclePersistenceScope: .sessionOnly
        )
        await store.bootstrap()

        await #expect(throws: CompetitionStoreError.durableMemoryRequired) {
            _ = try await store.reserveAuraRun(.aura(
                track: .firstRound,
                technique: .jab,
                stance: .orthodox
            ))
        }
        #expect(store.coachingCyclePersistenceOutcome == .idle)
    }

    @Test("A coaching run is reserved, activated, staged, and committed exactly once")
    func exactOnceLifecycleInMemory() async throws {
        let repository = InMemoryCompetitionRepository()
        let clock = Date(timeIntervalSince1970: 1_000)
        let store = CompetitionStore(repository: repository, now: { clock })
        await store.bootstrap()

        let runID = UUID(uuidString: "00000000-0000-0000-0000-00000000E501")!
        let selection = TrainingSelection.aura(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        let reserved = try await store.reserveAuraRun(selection, id: runID)
        #expect(reserved == runID)
        #expect(try await repository.trainingRun(id: runID)?.status == .reserved)

        try await store.activateAuraRun(id: runID)
        #expect(try await repository.trainingRun(id: runID)?.status == .active)

        let completed = try completedCycle(id: runID)
        let first = try await store.persistReservedAuraCoachingCycle(
            completed.result,
            fittedReach: completed.reach,
            runID: runID
        )
        let duplicate = try await store.persistReservedAuraCoachingCycle(
            completed.result,
            fittedReach: completed.reach,
            runID: runID
        )

        #expect(first == .durable)
        #expect(duplicate == .durable)
        #expect(try await repository.trainingRun(id: runID)?.status == .committed)
        #expect(try await repository.coachingCycle(id: runID)?.attempts.count == 6)
        #expect(store.coachingCyclePersistenceOutcome == .committed(runID))
        let persistedAttempts = try await repository.techniqueAttempts(
            athleteID: try #require(try await repository.trainingRun(id: runID)?.athleteID),
            techniqueID: Technique.jab.id
        )
        #expect(persistedAttempts.map(\.cycleOrdinal) == [1, 2, 3, 1, 2, 3])
        #expect(persistedAttempts.map(\.stage) == [.baseline, .baseline, .baseline, .retest, .retest, .retest])
    }

    @Test("A staged completion survives reopen and bootstrap commits it")
    func completedAwaitingCommitRecoversAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TechniqueAttemptPersistence-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("athlete-memory.store")
        let runID = UUID(uuidString: "00000000-0000-0000-0000-00000000E502")!
        let completed = try completedCycle(id: runID)

        do {
            let repository = SwiftDataCompetitionRepository(
                container: try CompetitionModelContainer.make(storeURL: storeURL)
            )
            let store = CompetitionStore(repository: repository, now: {
                Date(timeIntervalSince1970: 1_000)
            })
            await store.bootstrap()
            _ = try await store.reserveAuraRun(.aura(
                track: .firstRound,
                technique: .jab,
                stance: .orthodox
            ), id: runID)
            try await store.activateAuraRun(id: runID)
            try await store.stageReservedAuraCoachingCycle(
                completed.result,
                fittedReach: completed.reach,
                runID: runID
            )
            #expect(try await repository.trainingRun(id: runID)?.status == .completedAwaitingCommit)
            #expect(try await repository.coachingCycle(id: runID) == nil)
        }

        let reopenedRepository = SwiftDataCompetitionRepository(
            container: try CompetitionModelContainer.make(storeURL: storeURL)
        )
        let reopenedStore = CompetitionStore(repository: reopenedRepository, now: {
            Date(timeIntervalSince1970: 1_200)
        })
        await reopenedStore.bootstrap()

        #expect(try await reopenedRepository.trainingRun(id: runID)?.status == .committed)
        #expect(try await reopenedRepository.coachingCycle(id: runID)?.attempts.count == 6)
        #expect(reopenedStore.coachingCyclePersistenceOutcome == .committed(runID))
        #expect(reopenedStore.latestCoachingCycle?.id == runID)
        let recovered = try #require(reopenedStore.recoveredAuraResult)
        #expect(recovered.runID == runID)
        #expect(recovered.selection == .aura(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        ))
        #expect(recovered.snapshot.attempts.count == 6)
    }

    @Test("Bootstrap aborts stale reservations and active runs without proof")
    func bootstrapAbortsIncompleteRuns() async throws {
        let repository = InMemoryCompetitionRepository()
        let firstStore = CompetitionStore(repository: repository, now: {
            Date(timeIntervalSince1970: 1_300)
        })
        await firstStore.bootstrap()
        let reservedID = UUID(uuidString: "00000000-0000-0000-0000-00000000E503")!
        let activeID = UUID(uuidString: "00000000-0000-0000-0000-00000000E504")!
        let player = CompetitionPlayer(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000E513")!,
            name: "Local Athlete",
            normalizedName: CompetitionStore.standaloneAuraNormalizedName,
            rememberedStance: .orthodox,
            reach: nil,
            calibrationVersion: nil,
            calibratedAt: nil,
            createdAt: Date(timeIntervalSince1970: 1_300),
            lastSeenAt: Date(timeIntervalSince1970: 1_300)
        )
        try await repository.save(player: player)
        let reserved = try #require(PendingTrainingRun(
            id: reservedID,
            athleteID: player.id,
            eventID: nil,
            techniqueID: Technique.jab.id,
            requestedAt: Date(timeIntervalSince1970: 1_300)
        ))
        let active = try #require(PendingTrainingRun(
            id: activeID,
            athleteID: player.id,
            eventID: nil,
            techniqueID: Technique.jab.id,
            requestedAt: Date(timeIntervalSince1970: 1_301)
        ))
        _ = try await repository.reserveTrainingRun(
            reserved,
            descriptor: .aura(
                runID: reservedID, track: .firstRound,
                technique: .jab, stance: .orthodox
            )
        )
        _ = try await repository.reserveTrainingRun(
            active,
            descriptor: .aura(
                runID: activeID, track: .firstRound,
                technique: .jab, stance: .orthodox
            )
        )
        _ = try await repository.activateTrainingRun(
            id: activeID,
            at: Date(timeIntervalSince1970: 1_302)
        )

        let relaunched = CompetitionStore(repository: repository, now: {
            Date(timeIntervalSince1970: 1_400)
        })
        await relaunched.bootstrap()

        #expect(try await repository.trainingRun(id: reservedID)?.status == .aborted)
        #expect(try await repository.trainingRun(id: activeID)?.status == .aborted)
        #expect(try await repository.coachingCycle(id: reservedID) == nil)
        #expect(try await repository.coachingCycle(id: activeID) == nil)
    }

    @Test("A run rejects a result with a different identity")
    func mismatchedResultIdentityIsRejected() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository)
        await store.bootstrap()
        let runID = UUID(uuidString: "00000000-0000-0000-0000-00000000E505")!
        _ = try await store.reserveAuraRun(.aura(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        ), id: runID)
        try await store.activateAuraRun(id: runID)
        let wrongResult = try completedCycle(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000E506")!
        )

        await #expect(throws: AthleteMemoryRepositoryError.runParticipantMismatch) {
            _ = try await store.persistReservedAuraCoachingCycle(
                wrongResult.result,
                fittedReach: wrongResult.reach,
                runID: runID
            )
        }
        #expect(try await repository.trainingRun(id: runID)?.status == .active)
    }

    @Test("Closing immersion aborts an unfinished active coaching run")
    func earlyImmersiveCloseAbortsActiveRun() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository, now: {
            Date(timeIntervalSince1970: 1_500)
        })
        await store.bootstrap()
        let runID = UUID(uuidString: "00000000-0000-0000-0000-00000000E507")!
        _ = try await store.reserveAuraRun(.aura(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        ), id: runID)
        try await store.activateAuraRun(id: runID)

        await store.abortSceneOwnedAuraRunIfNeeded(id: runID)

        #expect(try await repository.trainingRun(id: runID)?.status == .aborted)
        #expect(store.coachingCyclePersistenceOutcome == .aborted(runID))
    }

    @Test("Delayed teardown cannot abort completion-owned or newer Aura runs")
    func teardownRaceIsRunOwned() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository, now: {
            Date(timeIntervalSince1970: 1_000)
        })
        await store.bootstrap()
        let oldID = UUID(uuidString: "00000000-0000-0000-0000-00000000E540")!
        _ = try await store.reserveAuraRun(.aura(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        ), id: oldID)
        try await store.activateAuraRun(id: oldID)
        store.markAuraCompletionStarted(id: oldID)
        let completed = try completedCycle(id: oldID)
        _ = try await store.persistReservedAuraCoachingCycle(
            completed.result,
            fittedReach: completed.reach,
            runID: oldID
        )

        let newID = UUID(uuidString: "00000000-0000-0000-0000-00000000E541")!
        _ = try await store.reserveAuraRun(.aura(
            track: .technicalCamp,
            technique: .uppercut,
            stance: .southpaw
        ), id: newID)
        try await store.activateAuraRun(id: newID)
        await store.abortSceneOwnedAuraRunIfNeeded(id: oldID)

        #expect(try await repository.trainingRun(id: oldID)?.status == .committed)
        #expect(try await repository.trainingRun(id: newID)?.status == .active)
    }

    @Test("Mixed bootstrap reconciles Aura only and leaves ranked and legacy runs untouched")
    func mixedRunBootstrapIsKindScoped() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository)
        await store.bootstrap()
        let player = CompetitionPlayer(
            id: UUID(), name: "Local Athlete",
            normalizedName: CompetitionStore.standaloneAuraNormalizedName,
            rememberedStance: .orthodox, reach: nil, calibrationVersion: nil,
            calibratedAt: nil, createdAt: Date(), lastSeenAt: Date()
        )
        try await repository.save(player: player)
        let rankedID = UUID()
        let legacyID = UUID()
        let requestedAt = Date()
        _ = try await repository.reserveTrainingRun(
            try #require(PendingTrainingRun(
                id: rankedID, athleteID: player.id, eventID: nil,
                techniqueID: Technique.jab.id, requestedAt: requestedAt
            )),
            descriptor: .ranked(runID: rankedID, mode: .reactiveStrike, stance: .orthodox)
        )
        _ = try await repository.reserveTrainingRun(
            try #require(PendingTrainingRun(
                id: legacyID, athleteID: player.id, eventID: nil,
                techniqueID: Technique.jab.id, requestedAt: requestedAt
            )),
            descriptor: .legacy(runID: legacyID)
        )

        let relaunched = CompetitionStore(repository: repository)
        await relaunched.bootstrap()

        #expect(try await repository.trainingRun(id: rankedID)?.status == .reserved)
        #expect(try await repository.trainingRun(id: legacyID)?.status == .reserved)
    }

    @Test("A staged run rejects a second payload with changed evidence")
    func stagedPayloadIsImmutable() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository, now: {
            Date(timeIntervalSince1970: 1_000)
        })
        await store.bootstrap()
        let runID = UUID(uuidString: "00000000-0000-0000-0000-00000000E508")!
        _ = try await store.reserveAuraRun(.aura(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        ), id: runID)
        try await store.activateAuraRun(id: runID)
        let completed = try completedCycle(id: runID)
        try await store.stageReservedAuraCoachingCycle(
            completed.result,
            fittedReach: completed.reach,
            runID: runID
        )
        let changedReach = try #require(BilateralReach(left: 0.70, right: 0.72))

        await #expect(throws: AthleteMemoryRepositoryError.runParticipantMismatch) {
            try await store.stageReservedAuraCoachingCycle(
                completed.result,
                fittedReach: changedReach,
                runID: runID
            )
        }
        #expect(try await repository.trainingRun(id: runID)?.status == .completedAwaitingCommit)
    }

    @Test("Run reservation rejects unknown athletes and cross-event ownership")
    func reservationRejectsAthleteAndEventMismatch() async throws {
        let repository = InMemoryCompetitionRepository()
        let firstEvent = try #require(EventEdition(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000E530")!,
            title: "Event",
            status: .open,
            openedAt: Date(timeIntervalSince1970: 1_700),
            closedAt: nil,
            scoringVersion: CompetitionScorer.scoringVersion,
            calibrationVersion: CompetitionPlayer.calibrationVersion
        ))
        _ = try await repository.create(event: firstEvent)
        let player = try await repository.createParticipant(
            eventID: firstEvent.id,
            displayName: "Jordan",
            experienceLevel: .beginner,
            stance: .orthodox,
            at: Date(timeIntervalSince1970: 1_701)
        )
        let unknown = try #require(PendingTrainingRun(
            id: UUID(),
            athleteID: UUID(),
            eventID: firstEvent.id,
            techniqueID: Technique.jab.id,
            requestedAt: Date(timeIntervalSince1970: 1_702)
        ))
        let wrongEvent = try #require(PendingTrainingRun(
            id: UUID(),
            athleteID: player.id,
            eventID: UUID(),
            techniqueID: Technique.jab.id,
            requestedAt: Date(timeIntervalSince1970: 1_702)
        ))

        await #expect(throws: AthleteMemoryRepositoryError.runParticipantMismatch) {
            _ = try await repository.reserveTrainingRun(unknown)
        }
        await #expect(throws: AthleteMemoryRepositoryError.runParticipantMismatch) {
            _ = try await repository.reserveTrainingRun(wrongEvent)
        }
    }

    @Test("Decoded coaching transactions reject a skill memory missing one of the six attempts")
    func tamperedTransactionDecodeIsRejected() async throws {
        let container = try CompetitionModelContainer.make(inMemory: true)
        let repository = SwiftDataCompetitionRepository(container: container)
        let store = CompetitionStore(repository: repository)
        await store.bootstrap()
        let runID = UUID(uuidString: "00000000-0000-0000-0000-00000000E550")!
        _ = try await store.reserveAuraRun(.aura(
            track: .firstRound, technique: .jab, stance: .orthodox
        ), id: runID)
        try await store.activateAuraRun(id: runID)
        let completed = try completedCycle(id: runID)
        try await store.stageReservedAuraCoachingCycle(
            completed.result, fittedReach: completed.reach, runID: runID
        )

        let context = ModelContext(container)
        let record = try #require(context.fetch(
            FetchDescriptor<CompetitionSchemaV4.CoachingRunCompletionRecord>()
        ).first)
        let originalJSON = try #require(
            JSONSerialization.jsonObject(with: record.transactionData) as? [String: Any]
        )
        var json = originalJSON
        var memory = try #require(json["skillMemory"] as? [String: Any])
        var attempts = try #require(memory["attempts"] as? [[String: Any]])
        attempts.removeLast()
        memory["attempts"] = attempts
        json["skillMemory"] = memory
        let tampered = try JSONSerialization.data(withJSONObject: json)

        do {
            _ = try JSONDecoder().decode(CoachingCycleMemoryTransaction.self, from: tampered)
            Issue.record("Tampered coaching transaction decoded successfully")
        } catch {
            // Expected: decoding re-runs the complete six-attempt transaction invariant.
        }

        for (field, value) in [
            ("name", "Impostor"),
            ("normalizedName", "impostor"),
            ("experienceLevel", "advanced"),
        ] {
            var identityJSON = originalJSON
            var player = try #require(identityJSON["player"] as? [String: Any])
            player[field] = value
            identityJSON["player"] = player
            let data = try JSONSerialization.data(withJSONObject: identityJSON)
            let transaction = try JSONDecoder().decode(
                CoachingCycleMemoryTransaction.self, from: data
            )
            await #expect(throws: AthleteMemoryRepositoryError.runParticipantMismatch) {
                _ = try await repository.stageCoachingCycle(
                    runID: runID, transaction: transaction
                )
            }
        }

        let playerInvariantMutations: [(String, Any)] = [
            ("rememberedStance", Stance.southpaw.rawValue),
            ("calibrationVersion", 99),
        ]
        for (field, value) in playerInvariantMutations {
            var playerJSON = originalJSON
            var player = try #require(playerJSON["player"] as? [String: Any])
            player[field] = value
            playerJSON["player"] = player
            let data = try JSONSerialization.data(withJSONObject: playerJSON)
            do {
                _ = try JSONDecoder().decode(CoachingCycleMemoryTransaction.self, from: data)
                Issue.record("Tampered player \(field) decoded successfully")
            } catch {
                // Expected: player stance/calibration is transaction-bound to all six attempts.
            }
        }
    }

    @Test("A failed stage save rolls back and reopens as an abortable active run")
    func failedStageRollsBackAcrossReopen() async throws {
        let fixture = try DurableStoreFixture()
        defer { fixture.remove() }
        let gate = SaveFailureGate()
        let runID = UUID(uuidString: "00000000-0000-0000-0000-00000000E551")!
        let completed = try completedCycle(id: runID)

        do {
            let repository = SwiftDataCompetitionRepository(
                container: try CompetitionModelContainer.make(storeURL: fixture.storeURL),
                beforeSave: { try gate.check() }
            )
            let store = CompetitionStore(repository: repository)
            await store.bootstrap()
            _ = try await store.reserveAuraRun(.aura(
                track: .firstRound, technique: .jab, stance: .orthodox
            ), id: runID)
            try await store.activateAuraRun(id: runID)
            store.markAuraCompletionStarted(id: runID)
            gate.failCount = 1
            await #expect(throws: CompetitionRepositoryError.self) {
                _ = try await store.persistReservedAuraCoachingCycle(
                    completed.result, fittedReach: completed.reach, runID: runID
                )
            }
            await store.abortSceneOwnedAuraRunIfNeeded(id: runID)
            #expect(try await repository.trainingRun(id: runID)?.status == .aborted)
            _ = try await store.reserveAuraRun(.aura(
                track: .technicalCamp, technique: .uppercut, stance: .southpaw
            ), id: UUID())
        }

        let reopened = SwiftDataCompetitionRepository(
            container: try CompetitionModelContainer.make(storeURL: fixture.storeURL)
        )
        #expect(try await reopened.trainingRun(id: runID)?.status == .aborted)
        let relaunched = CompetitionStore(repository: reopened)
        await relaunched.bootstrap()
        #expect(try await reopened.trainingRun(id: runID)?.status == .aborted)
        #expect(try await reopened.coachingCycle(id: runID) == nil)
    }

    @Test("A transient commit failure retries the staged payload in the same process")
    func transientCommitFailureRetriesToCommitted() async throws {
        let gate = SaveFailureGate()
        let repository = SwiftDataCompetitionRepository(
            container: try CompetitionModelContainer.make(inMemory: true),
            beforeSave: { try gate.check() }
        )
        let store = CompetitionStore(repository: repository)
        await store.bootstrap()
        let runID = UUID(uuidString: "00000000-0000-0000-0000-00000000E553")!
        _ = try await store.reserveAuraRun(.aura(
            track: .firstRound, technique: .jab, stance: .orthodox
        ), id: runID)
        try await store.activateAuraRun(id: runID)
        store.markAuraCompletionStarted(id: runID)
        let completed = try completedCycle(id: runID)
        gate.failCount = 1

        _ = try await store.persistReservedAuraCoachingCycle(
            completed.result, fittedReach: completed.reach, runID: runID
        )

        #expect(try await repository.trainingRun(id: runID)?.status == .committed)
        #expect(store.coachingCyclePersistenceOutcome == .committed(runID))
        #expect(store.latestCoachingCycle?.id == runID)
    }

    @Test("A second activated Aura run replaces completed scene ownership and early close aborts it")
    func consecutiveAuraSceneOwnershipUsesNewestRun() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository)
        await store.bootstrap()
        let firstID = UUID()
        _ = try await store.reserveAuraRun(.aura(
            track: .firstRound, technique: .jab, stance: .orthodox
        ), id: firstID)
        try await store.activateAuraRun(id: firstID)
        let first = try completedCycle(id: firstID)
        _ = try await store.persistReservedAuraCoachingCycle(
            first.result, fittedReach: first.reach, runID: firstID
        )
        let secondID = UUID()
        _ = try await store.reserveAuraRun(.aura(
            track: .technicalCamp, technique: .uppercut, stance: .southpaw
        ), id: secondID)
        try await store.activateAuraRun(id: secondID)

        await store.abortSceneOwnedAuraRunIfNeeded(id: secondID)

        #expect(try await repository.trainingRun(id: firstID)?.status == .committed)
        #expect(try await repository.trainingRun(id: secondID)?.status == .aborted)
    }

    @Test("Ranked and legacy descriptors cannot stage or commit Aura coaching payloads")
    func nonAuraDescriptorRejectsCoachingTransaction() async throws {
        let container = try CompetitionModelContainer.make(inMemory: true)
        let repository = SwiftDataCompetitionRepository(container: container)
        let store = CompetitionStore(repository: repository)
        await store.bootstrap()
        let runID = UUID()
        _ = try await store.reserveAuraRun(.aura(
            track: .firstRound, technique: .jab, stance: .orthodox
        ), id: runID)
        try await store.activateAuraRun(id: runID)
        let completed = try completedCycle(id: runID)
        try await store.stageReservedAuraCoachingCycle(
            completed.result, fittedReach: completed.reach, runID: runID
        )
        let context = ModelContext(container)
        let descriptor = try #require(context.fetch(
            FetchDescriptor<CompetitionSchemaV4.TrainingRunDescriptorRecord>()
        ).first(where: { $0.runID == runID }))
        descriptor.descriptorData = try JSONEncoder().encode(
            DurableTrainingRunDescriptor.ranked(
                runID: runID, mode: .reactiveStrike, stance: .orthodox
            )
        )
        try context.save()

        await #expect(throws: AthleteMemoryRepositoryError.runParticipantMismatch) {
            _ = try await repository.commitCoachingCycle(runID: runID, at: Date())
        }
        descriptor.descriptorData = try JSONEncoder().encode(
            DurableTrainingRunDescriptor.legacy(runID: runID)
        )
        try context.save()
        let transaction = try #require(context.fetch(
            FetchDescriptor<CompetitionSchemaV4.CoachingRunCompletionRecord>()
        ).first?.transaction)
        await #expect(throws: AthleteMemoryRepositoryError.runParticipantMismatch) {
            _ = try await repository.stageCoachingCycle(runID: runID, transaction: transaction)
        }
    }

    @Test("Acknowledged committed Aura results are delivered once across relaunches")
    func resultDeliveryAcknowledgementPreventsSecondReopen() async throws {
        let fixture = try DurableStoreFixture()
        defer { fixture.remove() }
        let runID = UUID()
        let completed = try completedCycle(id: runID)
        do {
            let repository = SwiftDataCompetitionRepository(
                container: try CompetitionModelContainer.make(storeURL: fixture.storeURL)
            )
            let first = CompetitionStore(repository: repository)
            await first.bootstrap()
            _ = try await first.reserveAuraRun(.aura(
                track: .firstRound, technique: .jab, stance: .orthodox
            ), id: runID)
            try await first.activateAuraRun(id: runID)
            _ = try await first.persistReservedAuraCoachingCycle(
                completed.result, fittedReach: completed.reach, runID: runID
            )
            #expect(!(try await repository.isAuraResultDeliveryAcknowledged(runID: runID)))
        }
        do {
            let repository = SwiftDataCompetitionRepository(
                container: try CompetitionModelContainer.make(storeURL: fixture.storeURL)
            )
            let firstRelaunch = CompetitionStore(repository: repository)
            await firstRelaunch.bootstrap()
            #expect(firstRelaunch.recoveredAuraResult?.runID == runID)
            await firstRelaunch.acknowledgeAuraResultDelivery(id: runID)
            #expect(try await repository.isAuraResultDeliveryAcknowledged(runID: runID))
        }
        do {
            let repository = SwiftDataCompetitionRepository(
                container: try CompetitionModelContainer.make(storeURL: fixture.storeURL)
            )
            let secondRelaunch = CompetitionStore(repository: repository)
            await secondRelaunch.bootstrap()
            #expect(secondRelaunch.recoveredAuraResult == nil)
        }
    }

    @Test("A failed atomic commit reopens staged and bootstrap commits every member")
    func failedCommitRollsBackAcrossReopen() async throws {
        let fixture = try DurableStoreFixture()
        defer { fixture.remove() }
        let gate = SaveFailureGate()
        let runID = UUID(uuidString: "00000000-0000-0000-0000-00000000E552")!
        let completed = try completedCycle(id: runID)

        do {
            let repository = SwiftDataCompetitionRepository(
                container: try CompetitionModelContainer.make(storeURL: fixture.storeURL),
                beforeSave: { try gate.check() }
            )
            let store = CompetitionStore(repository: repository)
            await store.bootstrap()
            _ = try await store.reserveAuraRun(.aura(
                track: .firstRound, technique: .jab, stance: .orthodox
            ), id: runID)
            try await store.activateAuraRun(id: runID)
            try await store.stageReservedAuraCoachingCycle(
                completed.result, fittedReach: completed.reach, runID: runID
            )
            gate.fail = true
            await #expect(throws: CompetitionRepositoryError.self) {
                _ = try await repository.commitCoachingCycle(runID: runID, at: Date())
            }
        }

        let reopened = SwiftDataCompetitionRepository(
            container: try CompetitionModelContainer.make(storeURL: fixture.storeURL)
        )
        #expect(try await reopened.trainingRun(id: runID)?.status == .completedAwaitingCommit)
        #expect(try await reopened.coachingCycle(id: runID) == nil)
        let relaunched = CompetitionStore(repository: reopened)
        await relaunched.bootstrap()
        #expect(try await reopened.trainingRun(id: runID)?.status == .committed)
        #expect(try await reopened.coachingCycle(id: runID)?.attempts.count == 6)
    }

    @Test("A genuine V3 file migrates to V4 without changing its player or pending run")
    func v3FileMigratesToV4WithLegacyDescriptor() async throws {
        let fixture = try DurableStoreFixture()
        defer { fixture.remove() }
        let player = CompetitionPlayer(
            id: UUID(), name: "Migration Athlete", normalizedName: "migration athlete",
            rememberedStance: .southpaw, reach: nil, calibrationVersion: nil,
            calibratedAt: nil, createdAt: Date(timeIntervalSince1970: 100),
            lastSeenAt: Date(timeIntervalSince1970: 101), experienceLevel: .advanced
        )
        let run = try #require(PendingTrainingRun(
            id: UUID(), athleteID: player.id, eventID: nil,
            techniqueID: Technique.uppercut.id,
            requestedAt: Date(timeIntervalSince1970: 102)
        ))
        try autoreleasepool {
            let schema = Schema(versionedSchema: CompetitionSchemaV3.self)
            let configuration = ModelConfiguration(
                "V3CoachingFixture", schema: schema, url: fixture.storeURL,
                allowsSave: true, cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(CompetitionSchemaV3.CompetitionPlayerRecord(player))
            context.insert(CompetitionSchemaV3.PendingTrainingRunRecord(run))
            try context.save()
        }

        let repository = SwiftDataCompetitionRepository(
            container: try CompetitionModelContainer.make(storeURL: fixture.storeURL)
        )
        #expect(try await repository.player(id: player.id) == player)
        #expect(try await repository.trainingRun(id: run.id) == TrainingRunSnapshot(run))
        #expect(try await repository.trainingRunDescriptor(id: run.id) == .legacy(runID: run.id))
    }

    private func completedCycle(id: UUID) throws -> (
        result: CoachingCycleResult,
        reach: BilateralReach
    ) {
        var cycle = CoachingCycleSession(
            id: id,
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        try cycle.completeFit(reach: BilateralReach(left: 0.62, right: 0.66)!)
        for _ in 0..<4 { try cycle.completeLearningStep() }
        for _ in 0..<cycle.track.guidedRehearsalCount {
            try cycle.completeGuidedRehearsal()
        }
        for index in 0..<CoachingCycleSession.requiredAttempts {
            try cycle.admit(try makeAttempt(id: 100 + index, path: 60))
        }
        try cycle.beginCorrectiveDrill()
        try cycle.completeCorrectiveDrill()
        for index in 0..<CoachingCycleSession.requiredAttempts {
            try cycle.admit(try makeAttempt(id: 200 + index, path: 72))
        }
        try cycle.continueFromProof()
        try cycle.completeTransfer(at: Date(timeIntervalSince1970: 1_050))
        return (try #require(cycle.result), try #require(cycle.fittedReach))
    }

    private func makeAttempt(id: Int, path: Float) throws -> CoachingAttemptEvidence {
        let attemptID = UUID(
            uuidString: String(format: "00000000-0000-0000-0000-%012d", id)
        )!
        let punch = try ValidatedPunchEvidence(
            technique: .jab,
            stance: .orthodox,
            side: .left,
            generation: 7,
            startedAt: 10,
            landedAt: 10.2,
            returnedAt: 10.5,
            outboundTravel: 0.5,
            landingError: 0.03,
            returnError: 0.04,
            trackedFraction: 0.96,
            quality: .measured
        )
        let score = TechniqueScore(
            techniqueID: Technique.jab.id,
            overall: path,
            metrics: [
                SubMetric(
                    kind: .path,
                    score: path,
                    measured: 0.08,
                    detail: "Path deviation",
                    quality: .measured
                ),
            ],
            trackedFraction: 0.96,
            duration: 0.5
        )
        let evidence = try TechniqueAttemptEvidence(
            punch: punch,
            score: score,
            metricQuality: [.path: .measured],
            attemptID: attemptID
        )
        let samples = [
            MotionSample(
                time: 0,
                fist: .zero,
                elbow: .zero,
                guardHand: .zero,
                isTracked: true
            ),
            MotionSample(
                time: 0.5,
                fist: SIMD3(0, 0, 0.5),
                elbow: SIMD3(0, 0, 0.25),
                guardHand: .zero,
                isTracked: true
            ),
        ]
        return try CoachingAttemptEvidence(
            evidence: evidence,
            actualSamples: samples,
            referenceSamples: samples
        )
    }
}

@MainActor
private final class SaveFailureGate {
    var fail = false
    var failCount = 0

    func check() throws {
        if fail || failCount > 0 {
            failCount = max(0, failCount - 1)
            throw CompetitionRepositoryError.saveFailed("Injected save failure")
        }
    }
}

private struct DurableStoreFixture {
    let directory: URL
    let storeURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DurableCoachingFixture-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("competition.store")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
