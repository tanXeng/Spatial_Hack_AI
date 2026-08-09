import XCTest
@testable import BoxingCoach

@MainActor
final class EventEditionPersistenceTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testInMemoryRepositoryFinalizesExactlyOnce() async throws {
        let repository = InMemoryTrainingRepository()
        let context = makeRunContext()
        let snapshot = makePartialSnapshot(context: context)

        try await repository.beginRun(context)
        try await repository.beginRun(context)
        try await repository.checkpoint(RunCheckpoint(
            runID: context.runID,
            completedStageID: "jab-watch",
            snapshotData: Data("checkpoint".utf8),
            createdAt: fixedDate
        ))

        let firstOutcome = try await repository.finalize(snapshot)
        let secondOutcome = try await repository.finalize(snapshot)
        let loadedRun = try await repository.run(id: context.runID)
        XCTAssertEqual(firstOutcome, .committed(runID: context.runID))
        XCTAssertEqual(secondOutcome, .alreadyFinalized(runID: context.runID))
        XCTAssertEqual(loadedRun, snapshot)
    }

    func testSwiftDataRepositoryRoundTripsEventParticipantAndRun() async throws {
        let container = try BoxingCoachModelContainer.make(inMemory: true)
        let repository = SwiftDataTrainingRepository(container: container)
        let event = try makeEvent()
        let participant = makeParticipant(eventID: event.id)

        try await repository.createEvent(event)
        try await repository.createParticipant(participant)
        let context = makeRunContext(eventID: event.id, participant: participant)
        let snapshot = makePartialSnapshot(context: context)
        try await repository.beginRun(context)
        let outcome = try await repository.finalize(snapshot)
        let loadedEvent = try await repository.loadActiveEvent()
        let loadedParticipants = try await repository.participants(eventID: event.id)
        let loadedRun = try await repository.run(id: context.runID)
        XCTAssertEqual(outcome, .committed(runID: context.runID))
        XCTAssertEqual(loadedEvent, event)
        XCTAssertEqual(loadedParticipants, [participant])
        XCTAssertEqual(loadedRun, snapshot)
        let matches = try await repository.participantMatches(
            eventID: event.id,
            normalizedAlias: participant.normalizedAlias
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0], participant)
    }

    func testEventStoreEnforcesUniqueNamesAndReopensByName() async throws {
        let repository = InMemoryTrainingRepository()
        let store = EventStore(
            repository: repository,
            now: { self.fixedDate }
        )
        await store.bootstrap()
        let eventID = try await store.createEvent(EventDraft(
            title: "Hacklings Demo Day",
            timeZoneIdentifier: "Asia/Singapore"
        ))
        try await store.activateEvent(id: eventID)
        _ = try await store.createParticipant(ParticipantDraft(
            alias: "Máya",
            avatarID: AvatarChoice.all[0].id,
            stance: .orthodox,
            isLeaderboardPublic: false
        ))
        store.clearActiveParticipant()

        do {
            _ = try await store.createParticipant(ParticipantDraft(
                alias: "maya",
                avatarID: AvatarChoice.all[1].id,
                stance: .southpaw,
                isLeaderboardPublic: true
            ))
            XCTFail("Expected duplicate normalized player-name rejection")
        } catch {
            XCTAssertEqual(error as? EventStoreError, .existingPlayerName)
        }

        let reopenedID = try await store.openParticipant(alias: "MAYA")
        XCTAssertEqual(reopenedID, store.activeParticipant?.id)
    }

    func testRecoverySnapshotDetectsTampering() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BoxingCoachRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "latest.json")
        let recovery = RecoverySnapshotStore(fileURL: fileURL)
        let payload = EventRecoveryPayload(
            schemaVersion: 1,
            generatedAt: fixedDate,
            event: try makeEvent(),
            participants: [],
            runs: [],
            awards: []
        )

        try await recovery.write(payload)
        let loaded = try await recovery.load()
        XCTAssertEqual(loaded, payload)
        try Data("tampered".utf8).write(to: fileURL, options: .atomic)
        do {
            _ = try await recovery.load()
            XCTFail("Tampered recovery data must fail closed")
        } catch {
            XCTAssertNotNil(error)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEvent() throws -> EventSnapshot {
        let rules = ChallengeRulesV1.eventEdition
        return EventSnapshot(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            title: "Hacklings Demo Day",
            timeZoneIdentifier: "Asia/Singapore",
            status: .open,
            createdAt: fixedDate,
            startedAt: fixedDate,
            closedAt: nil,
            challengeID: rules.challengeID,
            scoringVersion: rules.scoringVersion,
            rulesData: try rules.encoded(),
            rulesDigest: try rules.digest(),
            maxOfficialAttempts: rules.maxOfficialAttempts
        )
    }

    private func makeParticipant(eventID: UUID) -> ParticipantSnapshot {
        ParticipantSnapshot(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            eventID: eventID,
            entryID: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            alias: "Maya",
            normalizedAlias: "maya",
            avatarID: AvatarChoice.all[0].id,
            stance: .orthodox,
            competitorNumber: 1,
            isLeaderboardPublic: false,
            lessonCompletedAt: nil,
            coachOverrideAt: nil,
            createdAt: fixedDate,
            lastSeenAt: fixedDate,
            archived: false
        )
    }

    private func makeRunContext(
        eventID: UUID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        participant: ParticipantSnapshot? = nil
    ) -> TrainingRunContext {
        TrainingRunContext(
            runID: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            eventID: eventID,
            participantID: participant?.id,
            entryID: participant?.entryID,
            aliasSnapshot: participant?.alias,
            avatarIDSnapshot: participant?.avatarID,
            plan: .controlledOneTwoPractice,
            stance: participant?.stance ?? .orthodox,
            startedAt: fixedDate,
            officialOrdinal: nil,
            rulesDigest: "rules-v1"
        )
    }

    private func makePartialSnapshot(context: TrainingRunContext) -> TrainingRunSnapshot {
        TrainingRunSnapshot(
            id: context.runID,
            eventID: context.eventID,
            participantID: context.participantID,
            entryID: context.entryID,
            aliasSnapshot: context.aliasSnapshot,
            avatarIDSnapshot: context.avatarIDSnapshot,
            plan: context.plan,
            status: .partial,
            stance: context.stance,
            startedAt: context.startedAt,
            endedAt: fixedDate.addingTimeInterval(30),
            officialOrdinal: context.officialOrdinal,
            rulesDigest: context.rulesDigest,
            trackingSummary: "Ended early",
            optedIntoLeaderboard: false,
            eligibilityReason: .partialResult
        )
    }
}
