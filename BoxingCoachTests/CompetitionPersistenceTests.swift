import XCTest
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

    func testSwiftDataCompetitionSchemaRoundTripsWithoutEventEditionModels() async throws {
        let container = try CompetitionModelContainer.make(inMemory: true)
        let repository = SwiftDataCompetitionRepository(container: container)
        let player = makePlayer()
        try await repository.save(player: player)
        _ = try await repository.submit(makeSubmission(player: player))

        let restored = try await repository.player(id: player.id)
        let submissions = try await repository.submissions()
        XCTAssertEqual(restored, player)
        XCTAssertEqual(submissions.count, 1)
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
