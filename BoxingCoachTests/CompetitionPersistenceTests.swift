import XCTest
@testable import BoxingCoach

@MainActor
final class CompetitionPersistenceTests: XCTestCase {
    func testSheetLifecycleAndRankedStanceAreStateDriven() async throws {
        let repository = InMemoryCompetitionRepository()
        try await repository.save(player: makePlayer())
        let store = CompetitionStore(repository: repository)

        store.open()
        XCTAssertEqual(store.sheetRoute, .nameEntry)
        await store.join(name: "Alex")
        XCTAssertEqual(store.sheetRoute, .enterSetup)

        // The stance is not passed in: Reactive Strike is the only ranked mode and it takes the
        // stance off the player record, which `makePlayer` sets to southpaw.
        let selection = await store.startReactiveStrike()
        guard case .competition(_, .reactiveStrike, .southpaw, _)? = selection else {
            return XCTFail("Expected a Reactive Strike selection using the player's stance")
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
        XCTAssertEqual(store.sheetRoute, .enterSetup)
        let selection = await store.startReactiveStrike()
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

    func testDiscardingPreparedRunAllowsAReplacementSelection() async throws {
        let repository = InMemoryCompetitionRepository()
        try await repository.save(player: makePlayer())
        let store = CompetitionStore(repository: repository)
        await store.join(name: "Alex")

        let firstSelection = await store.startReactiveStrike()
        XCTAssertNotNil(firstSelection)
        store.discardPreparedRun()

        XCTAssertNil(store.activeRun)
        let replacementSelection = await store.startReactiveStrike()
        XCTAssertNotNil(replacementSelection)
    }

    func testClosingSheetForNavigationPreservesAnActionableError() async throws {
        let repository = InMemoryCompetitionRepository()
        try await repository.save(player: makePlayer())
        let store = CompetitionStore(repository: repository)
        await store.join(name: "Alex")
        _ = await store.startReactiveStrike()
        _ = await store.startReactiveStrike()
        store.discardPreparedRun()

        store.closeSheetForNavigation()

        XCTAssertNil(store.sheetRoute)
        XCTAssertEqual(store.errorMessage, CompetitionStoreError.runAlreadyActive.errorDescription)
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

        let first = Task { await store.startReactiveStrike() }
        try? await Task.sleep(for: .milliseconds(10))
        let second = await store.startReactiveStrike()
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
