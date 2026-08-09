import XCTest
import SwiftData
import Testing
@testable import BoxingCoach

@MainActor
final class CompetitionPersistenceTests: XCTestCase {
    func testSheetLifecycleAndComboStanceAreStateDriven() async throws {
        let repository = InMemoryCompetitionRepository()
        try await repository.save(player: makePlayer())
        let store = CompetitionStore(repository: repository)

        store.open()
        XCTAssertEqual(store.sheetRoute, .nameEntry)
        await store.join(name: "Alex")
        XCTAssertEqual(store.sheetRoute, .modes)

        let deferredSelection = await store.chooseMode(.combination)
        XCTAssertNil(deferredSelection)
        XCTAssertEqual(store.sheetRoute, .stance)
        let selection = await store.startCombination(stance: .orthodox)
        guard case .competition(_, .combination, .orthodox, _)? = selection else {
            return XCTFail("Expected a fixed Combo competition selection")
        }

        store.cancelActiveRun(message: "Cancelled for test")
        store.dismiss()
        XCTAssertNil(store.sheetRoute)
    }

    func testStoreCreatesAndAutomaticallyReopensNormalizedName() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository, now: { Date(timeIntervalSince1970: 100) })
        await store.join(name: "José Lee")
        let originalID = try XCTUnwrap(store.currentPlayer?.id)

        await store.join(name: "JOSE   LEE")
        XCTAssertEqual(store.currentPlayer?.id, originalID)
        XCTAssertEqual(store.currentPlayer?.name, "JOSE LEE")
    }

    func testBilateralCalibrationAndStancePersistAndCanBeReused() async throws {
        let repository = InMemoryCompetitionRepository()
        let player = makePlayer()
        try await repository.save(player: player)

        let restoredValue = try await repository.player(normalizedName: "alex")
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(restored.reach, player.reach)
        XCTAssertEqual(restored.rememberedStance, .southpaw)

        let store = CompetitionStore(repository: repository)
        await store.join(name: "Alex")
        XCTAssertEqual(store.sheetRoute, .modes)
        let selection = await store.chooseMode(.reactiveStrike)
        XCTAssertNotNil(selection)
    }

    func testManualRecalibrationCreatesCalibrationRun() async throws {
        let repository = InMemoryCompetitionRepository()
        try await repository.save(player: makePlayer())
        let store = CompetitionStore(repository: repository)
        await store.join(name: "Alex")

        let selection = try XCTUnwrap(store.prepareCalibration())
        guard case .competitionCalibration(let playerID) = selection else {
            return XCTFail("Expected calibration selection")
        }
        XCTAssertEqual(playerID, store.currentPlayer?.id)
        XCTAssertEqual(store.activeRun?.kind, .calibration)
    }

    func testRepositorySubmissionIsExactOnceAndResetClearsEverything() async throws {
        let repository = InMemoryCompetitionRepository()
        let player = makePlayer()
        try await repository.save(player: player)
        let submission = makeSubmission(player: player)

        _ = try await repository.submit(submission)
        _ = try await repository.submit(submission)
        let saved = try await repository.submissions()
        XCTAssertEqual(saved.count, 1)

        try await repository.reset()
        let removedPlayer = try await repository.player(id: player.id)
        let removedSubmissions = try await repository.submissions()
        XCTAssertNil(removedPlayer)
        XCTAssertTrue(removedSubmissions.isEmpty)
    }

    func testResetIsRejectedWhileRunIsActive() async throws {
        let repository = InMemoryCompetitionRepository()
        try await repository.save(player: makePlayer())
        let store = CompetitionStore(repository: repository)
        await store.join(name: "Alex")
        _ = store.prepareCalibration()

        await store.resetConfirmed()
        XCTAssertNotNil(store.activeRun)
        XCTAssertEqual(store.errorMessage, CompetitionStoreError.resetBlocked.errorDescription)
        let retained = try await repository.player(normalizedName: "alex")
        XCTAssertNotNil(retained)
    }

    func testConcurrentJoinIsSerializedToOneLookupAndSave() async throws {
        let repository = DelayedCompetitionRepository(delay: .milliseconds(80))
        let store = CompetitionStore(repository: repository)

        let first = Task { await store.join(name: "Alex") }
        try? await Task.sleep(for: .milliseconds(10))
        await store.join(name: "Alex")
        await first.value

        XCTAssertEqual(repository.normalizedLookupCount, 1)
        XCTAssertEqual(repository.saveCount, 1)
        XCTAssertNotNil(store.currentPlayer)
    }

    func testConcurrentRankedStartReservesExactlyOneRunBeforeSaveSuspends() async throws {
        let repository = DelayedCompetitionRepository()
        try await repository.save(player: makePlayer())
        let store = CompetitionStore(repository: repository)
        await store.join(name: "Alex")
        repository.delay = .milliseconds(80)
        repository.saveCount = 0

        let first = Task { await store.chooseMode(.reactiveStrike) }
        try? await Task.sleep(for: .milliseconds(10))
        let second = await store.chooseMode(.reactiveStrike)
        let firstSelection = await first.value

        XCTAssertNotNil(firstSelection)
        XCTAssertNil(second)
        XCTAssertEqual(repository.saveCount, 1)
        XCTAssertEqual(store.activeRun?.kind, .ranked(.reactiveStrike))
    }

    func testBootstrapRetriesAfterTransientLeaderboardLoadFailure() async {
        let repository = DelayedCompetitionRepository()
        repository.submissionFailuresRemaining = 1
        let store = CompetitionStore(repository: repository)

        await store.bootstrap()
        XCTAssertNotNil(store.errorMessage)
        await store.bootstrap()

        XCTAssertEqual(repository.submissionsCount, 2)
        XCTAssertNil(store.errorMessage)
    }

    private func makePlayer() -> CompetitionPlayer {
        CompetitionPlayer(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            name: "Alex",
            normalizedName: "alex",
            rememberedStance: .southpaw,
            reach: BilateralReach(left: 0.64, right: 0.69),
            calibrationVersion: CompetitionPlayer.calibrationVersion,
            calibratedAt: Date(timeIntervalSince1970: 5),
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 5)
        )
    }

    private func makeSubmission(player: CompetitionPlayer) -> CompetitionSubmission {
        CompetitionSubmission(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            playerID: player.id,
            playerName: player.name,
            normalizedPlayerName: player.normalizedName,
            mode: .reactiveStrike,
            score: 88,
            validSteps: 7,
            totalSteps: 8,
            completedRepetitions: 0,
            meanCentreErrorMeters: 0.02,
            speedTieBreakSeconds: 0.31,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            trackingStatus: .complete
        )
    }
}

@Suite("Competition current SwiftData persistence")
@MainActor
struct CompetitionSwiftDataV2PersistenceTests {
    @Test("Production disk configuration retains the shipped V1 store URL")
    func productionDiskConfigurationUsesShippedStoreURL() {
        let configuration = CompetitionModelContainer.configuration(inMemory: false)
        let shippedV1Configuration = ModelConfiguration(
            "BoxingCoachCompetitionV1",
            schema: Schema(versionedSchema: CompetitionSchemaV1.self),
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .automatic,
            cloudKitDatabase: .none
        )

        #expect(configuration.name == CompetitionModelContainer.configurationName)
        #expect(configuration.url == shippedV1Configuration.url)
        #expect(configuration.url.lastPathComponent == "BoxingCoachCompetitionV1.store")
    }

    @Test("Current V3 schema round-trips participant and submission snapshots")
    func currentSchemaRoundTripsCompetitionValues() async throws {
        let container = try CompetitionModelContainer.make(inMemory: true)
        let repository = SwiftDataCompetitionRepository(container: container)
        let player = makePersistentPlayer()
        let submission = makePersistentSubmission(player: player)

        try await repository.save(player: player)
        _ = try await repository.submit(submission)

        #expect(try await repository.player(id: player.id) == player)
        #expect(try await repository.submissions() == [submission])
        #expect(try ModelContext(container).fetch(
            FetchDescriptor<CompetitionSchemaV3.CompetitionPlayerRecord>()
        ).count == 1)
    }

    @Test("Current V3 schema round-trips event, attempt, memory, pending run, and award records")
    func currentSchemaRoundTripsAthleteMemoryValues() throws {
        let container = try CompetitionModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let player = makePersistentPlayer()
        let eventID = try #require(player.eventID)
        let publicHandle = try #require(player.publicHandle)
        let event = try #require(EventEdition(
            id: eventID,
            title: "Summer Finals",
            status: .open,
            openedAt: Date(timeIntervalSince1970: 1),
            closedAt: nil,
            scoringVersion: CompetitionScorer.scoringVersion,
            calibrationVersion: CompetitionPlayer.calibrationVersion
        ))
        let attempt = try #require(TechniqueAttemptSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000213")!,
            athleteID: player.id,
            eventID: event.id,
            techniqueID: "jab",
            score: 92,
            scoringVersion: event.scoringVersion,
            calibrationVersion: player.calibrationVersion,
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 12),
            publicHandleSnapshot: player.publicHandle
        ))
        let memory = try #require(AthleteSkillMemory(
            athleteID: player.id,
            techniqueID: attempt.techniqueID,
            experienceLevel: player.experienceLevel,
            attempts: [attempt],
            pastSelfTrace: nil,
            updatedAt: attempt.completedAt
        ))
        let pending = try #require(PendingTrainingRun(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000214")!,
            athleteID: player.id,
            eventID: event.id,
            techniqueID: "cross",
            requestedAt: Date(timeIntervalSince1970: 20)
        ))
        let award = try #require(EventAward(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000215")!,
            eventID: event.id,
            athleteID: player.id,
            publicHandleSnapshot: publicHandle,
            kind: .personalBest,
            attemptID: attempt.id,
            awardedAt: Date(timeIntervalSince1970: 13)
        ))

        context.insert(CompetitionSchemaV3.EventEditionRecord(event))
        context.insert(CompetitionSchemaV3.TechniqueAttemptRecord(attempt))
        context.insert(try CompetitionSchemaV3.AthleteSkillMemoryRecord(memory))
        context.insert(CompetitionSchemaV3.PendingTrainingRunRecord(pending))
        context.insert(CompetitionSchemaV3.EventAwardRecord(award))
        try context.save()

        let restoredContext = ModelContext(container)
        #expect(try restoredContext.fetch(
            FetchDescriptor<CompetitionSchemaV3.EventEditionRecord>()
        ).only?.snapshot == event)
        #expect(try restoredContext.fetch(
            FetchDescriptor<CompetitionSchemaV3.TechniqueAttemptRecord>()
        ).only?.snapshot == attempt)
        #expect(try restoredContext.fetch(
            FetchDescriptor<CompetitionSchemaV3.AthleteSkillMemoryRecord>()
        ).only?.snapshot(attempts: [attempt]) == memory)
        #expect(try restoredContext.fetch(
            FetchDescriptor<CompetitionSchemaV3.PendingTrainingRunRecord>()
        ).only?.snapshot == pending)
        #expect(try restoredContext.fetch(
            FetchDescriptor<CompetitionSchemaV3.EventAwardRecord>()
        ).only?.snapshot == award)
    }

    @Test("A failed save rolls back the inserted participant")
    func saveFailureRollsBackContext() async throws {
        try await FileBackedCompetitionFixture.use { storeURL in
            try createWritableCurrentStore(at: storeURL)

            let container = try CompetitionModelContainer.make(storeURL: storeURL, allowsSave: false)
            let repository = SwiftDataCompetitionRepository(container: container)
            let player = makePersistentPlayer()

            await #expect(throws: CompetitionRepositoryError.self) {
                try await repository.save(player: player)
            }

            #expect(try await repository.player(id: player.id) == nil)
            #expect(try ModelContext(container).fetch(
                FetchDescriptor<CompetitionSchemaV3.CompetitionPlayerRecord>()
            ).isEmpty)
        }
    }
}

@MainActor
private enum FileBackedCompetitionFixture {
    static func use(_ body: (URL) async throws -> Void) async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CompetitionRollbackTests-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try await body(directoryURL.appendingPathComponent("competition.store"))
    }
}

@MainActor
private func createWritableCurrentStore(at storeURL: URL) throws {
    try autoreleasepool {
        _ = try CompetitionModelContainer.make(storeURL: storeURL)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

@MainActor
private func makePersistentPlayer() -> CompetitionPlayer {
    let eventID = UUID(uuidString: "00000000-0000-0000-0000-000000000210")!
    let handle = ParticipantPublicHandle.reserving(
        eventID: eventID,
        displayName: "Alex",
        displayCode: "0042",
        against: []
    )!
    return CompetitionPlayer(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000211")!,
        name: "Alex",
        normalizedName: "alex",
        rememberedStance: .southpaw,
        reach: BilateralReach(left: 0.64, right: 0.69),
        calibrationVersion: CompetitionPlayer.calibrationVersion,
        calibratedAt: Date(timeIntervalSince1970: 5),
        createdAt: Date(timeIntervalSince1970: 1),
        lastSeenAt: Date(timeIntervalSince1970: 5),
        experienceLevel: .intermediate,
        publicHandle: handle
    )
}

@MainActor
private func makePersistentSubmission(player: CompetitionPlayer) -> CompetitionSubmission {
    CompetitionSubmission(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000212")!,
        playerID: player.id,
        playerName: player.name,
        normalizedPlayerName: player.normalizedName,
        mode: .reactiveStrike,
        score: 88,
        validSteps: 7,
        totalSteps: 8,
        completedRepetitions: 0,
        meanCentreErrorMeters: 0.02,
        speedTieBreakSeconds: 0.31,
        startedAt: Date(timeIntervalSince1970: 10),
        endedAt: Date(timeIntervalSince1970: 20),
        trackingStatus: .complete,
        eventID: player.eventID,
        scoringVersion: CompetitionScorer.scoringVersion,
        calibrationVersion: player.calibrationVersion,
        publicHandleSnapshot: player.publicHandle
    )
}

@MainActor
private final class DelayedCompetitionRepository: CompetitionRepository {
    var delay: Duration
    var normalizedLookupCount = 0
    var saveCount = 0
    var submissionsCount = 0
    var submissionFailuresRemaining = 0
    private let base = InMemoryCompetitionRepository()

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    func player(normalizedName: String) async throws -> CompetitionPlayer? {
        normalizedLookupCount += 1
        try? await Task.sleep(for: delay)
        return try await base.player(normalizedName: normalizedName)
    }

    func player(id: UUID) async throws -> CompetitionPlayer? {
        try await base.player(id: id)
    }

    func save(player: CompetitionPlayer) async throws {
        saveCount += 1
        try? await Task.sleep(for: delay)
        try await base.save(player: player)
    }

    func submit(_ submission: CompetitionSubmission) async throws -> CompetitionSubmission {
        try await base.submit(submission)
    }

    func submissions() async throws -> [CompetitionSubmission] {
        submissionsCount += 1
        if submissionFailuresRemaining > 0 {
            submissionFailuresRemaining -= 1
            throw CompetitionRepositoryError.saveFailed("Temporary leaderboard load failure")
        }
        return try await base.submissions()
    }

    func reset() async throws {
        try await base.reset()
    }
}
