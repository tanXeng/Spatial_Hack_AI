import Foundation
import SwiftData
import Testing
@testable import BoxingCoach

@Suite("Event participant selection and private handoff")
@MainActor
struct ParticipantHandoffTests {
    @Test("Duplicate names receive distinct codes and rejoin only by event code")
    func duplicateNamesRemainDistinct() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(
            repository: repository,
            now: { Date(timeIntervalSince1970: 100) }
        )
        await store.bootstrap()

        await store.createParticipant(
            name: "Alex",
            experienceLevel: .beginner,
            stance: .orthodox
        )
        var first = try #require(store.currentPlayer)
        first.reach = BilateralReach(left: 0.62, right: 0.64)
        first.calibrationVersion = CompetitionPlayer.calibrationVersion
        first.calibratedAt = .init(timeIntervalSince1970: 101)
        first = try await repository.saveParticipant(first)
        let firstAttempt = try #require(TechniqueAttemptSnapshot(
            id: UUID(), athleteID: first.id, eventID: first.eventID,
            techniqueID: "jab", score: 81,
            scoringVersion: CompetitionScorer.scoringVersion,
            calibrationVersion: CompetitionPlayer.calibrationVersion,
            startedAt: .init(timeIntervalSince1970: 102),
            completedAt: .init(timeIntervalSince1970: 103),
            publicHandleSnapshot: first.publicHandle
        ))
        try await repository.save(techniqueAttempts: [firstAttempt])
        await store.handoffToWelcome()

        await store.createParticipant(
            name: "Alex",
            experienceLevel: .advanced,
            stance: .southpaw
        )
        let second = try #require(store.currentPlayer)

        #expect(first.id != second.id)
        #expect(first.publicHandle?.displayCode == "0000")
        #expect(second.publicHandle?.displayCode == "0001")
        #expect(second.experienceLevel == .advanced)
        #expect(second.rememberedStance == .southpaw)

        await store.rejoin(code: "0000")
        #expect(store.currentPlayer?.id == first.id)
        #expect(store.currentPlayer?.experienceLevel == .beginner)
        #expect(store.currentPlayer?.rememberedStance == .orthodox)
        #expect(store.currentPlayer?.reach == first.reach)
        #expect(try await repository.techniqueAttempts(
            athleteID: first.id,
            techniqueID: "jab"
        ) == [firstAttempt])
        #expect(try await repository.techniqueAttempts(
            athleteID: second.id,
            techniqueID: "jab"
        ).isEmpty)
    }

    @Test("Boards include only submissions owned by the active event")
    func boardsAreEventScoped() async throws {
        let repository = InMemoryCompetitionRepository()
        let active = try #require(EventEdition(
            id: UUID(), title: "Active", status: .open,
            openedAt: .init(timeIntervalSince1970: 1), closedAt: nil,
            scoringVersion: CompetitionScorer.scoringVersion,
            calibrationVersion: CompetitionPlayer.calibrationVersion
        ))
        _ = try await repository.create(event: active)
        let activePlayer = try await repository.createParticipant(
            eventID: active.id, displayName: "Active Alex", experienceLevel: .beginner,
            stance: .orthodox, at: .init(timeIntervalSince1970: 2)
        )
        let activeSubmission = submission(player: activePlayer, eventID: active.id, score: 91)
        _ = try await repository.submit(activeSubmission)
        let legacyPlayer = CompetitionPlayer(
            id: UUID(), name: "Legacy Alex", normalizedName: "legacy alex",
            rememberedStance: .orthodox, reach: nil, calibrationVersion: nil,
            calibratedAt: nil, createdAt: .init(timeIntervalSince1970: 1),
            lastSeenAt: .init(timeIntervalSince1970: 1)
        )
        try await repository.save(player: legacyPlayer)
        _ = try await repository.submit(submission(player: legacyPlayer, eventID: nil, score: 99))

        #expect(try await repository.submissions(eventID: active.id) == [activeSubmission])
    }

    @Test("Repository allocates participant codes atomically across duplicate names")
    func repositoryOwnsCodeAllocation() async throws {
        let repository = InMemoryCompetitionRepository()
        let event = try #require(EventEdition(
            id: UUID(), title: "Active", status: .open,
            openedAt: .init(timeIntervalSince1970: 1), closedAt: nil,
            scoringVersion: CompetitionScorer.scoringVersion,
            calibrationVersion: CompetitionPlayer.calibrationVersion
        ))
        _ = try await repository.create(event: event)

        let first = try await repository.createParticipant(
            eventID: event.id, displayName: "Alex", experienceLevel: .beginner,
            stance: .orthodox, at: .init(timeIntervalSince1970: 2)
        )
        let second = try await repository.createParticipant(
            eventID: event.id, displayName: "Alex", experienceLevel: .advanced,
            stance: .southpaw, at: .init(timeIntervalSince1970: 3)
        )

        #expect(first.publicHandle?.displayCode == "0000")
        #expect(second.publicHandle?.displayCode == "0001")

        _ = try await repository.closeEvent(
            id: event.id,
            at: .init(timeIntervalSince1970: 4)
        )
        await #expect(throws: AthleteMemoryRepositoryError.eventClosed) {
            try await repository.saveParticipant(first)
        }
    }

    @Test("A post-commit refresh failure never invites duplicate profile creation")
    func committedProfileSurvivesRefreshFailure() async throws {
        struct RefreshFailure: Error {}
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(
            repository: repository,
            postParticipantCommitRefresh: { throw RefreshFailure() }
        )
        await store.bootstrap()

        await store.createParticipant(
            name: "Alex", experienceLevel: .beginner, stance: .orthodox
        )

        #expect(store.currentPlayer?.name == "Alex")
        #expect(store.sheetRoute == .calibrationRequired)
        #expect(store.errorMessage == "Profile saved. Some event details could not be refreshed.")
        #expect(try await repository.participants(
            eventID: try #require(store.currentEvent?.id)
        ).count == 1)
    }

    @Test("Private handoff clears participant and session state but preserves profiles")
    func privateHandoffClearsEphemeralState() async throws {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository)
        let flow = TrainingFlowCoordinator()
        let session = ReactiveStrikeSession()
        await store.bootstrap()
        await store.createParticipant(
            name: "Alex",
            experienceLevel: .intermediate,
            stance: .southpaw
        )
        let participant = try #require(store.currentPlayer)
        _ = store.prepareCalibration()
        #expect(store.activeRun != nil)
        session.reportError("Private result")

        let presentation = await ParticipantHandoffCoordinator.perform(
            store: store,
            flow: flow,
            session: session
        )

        #expect(presentation.announcement == "Ready for the next boxer.")
        #expect(presentation.focus == .startTraining)
        #expect(store.currentPlayer == nil)
        #expect(store.latestSubmission == nil)
        #expect(store.activeRun == nil)
        #expect(store.nameDraft.isEmpty)
        #expect(store.codeDraft.isEmpty)
        #expect(store.sheetRoute == .welcome)
        #expect(session.errorMessage == nil)
        #expect(session.phase == .idle)
        #expect(session.latestCalibratedReaches.isEmpty)
        #expect(session.voiceCoach.controlPresentation.visibleTranscript == nil)

        await store.rejoin(code: participant.publicHandle?.displayCode ?? "")
        #expect(store.currentPlayer?.id == participant.id)
    }

    @Test("Handoff removes the previous participant result before welcome")
    func handoffClearsPresentedResult() async throws {
        let player = CompetitionPlayer(
            id: UUID(), name: "Alex", normalizedName: "alex",
            rememberedStance: .orthodox, reach: nil, calibrationVersion: nil,
            calibratedAt: nil, createdAt: .init(timeIntervalSince1970: 1),
            lastSeenAt: .init(timeIntervalSince1970: 1)
        )
        let result = submission(player: player, eventID: nil, score: 88)
        let store = CompetitionStore.preview(
            route: .result(result.id), player: player, latestSubmission: result
        )

        _ = await ParticipantHandoffCoordinator.perform(
            store: store, flow: TrainingFlowCoordinator(), session: ReactiveStrikeSession()
        )

        #expect(store.latestSubmission == nil)
        #expect(store.currentPlayer == nil)
        #expect(store.sheetRoute == .welcome)
    }

    @Test("SwiftData event participants reopen and closed events reject writes")
    func fileBackedReopenAndClosedEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "ParticipantHandoff-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appending(path: "event.store")
        let eventID = UUID()
        var code = ""

        do {
            let container = try CompetitionModelContainer.make(storeURL: storeURL)
            let repository = SwiftDataCompetitionRepository(container: container)
            let event = try #require(EventEdition(
                id: eventID, title: "Device Event", status: .open,
                openedAt: .init(timeIntervalSince1970: 1), closedAt: nil,
                scoringVersion: CompetitionScorer.scoringVersion,
                calibrationVersion: CompetitionPlayer.calibrationVersion
            ))
            _ = try await repository.create(event: event)
            let participant = try await repository.createParticipant(
                eventID: eventID, displayName: "Alex", experienceLevel: .beginner,
                stance: .orthodox, at: .init(timeIntervalSince1970: 2)
            )
            code = try #require(participant.publicHandle?.displayCode)
        }

        do {
            let container = try CompetitionModelContainer.make(storeURL: storeURL)
            let repository = SwiftDataCompetitionRepository(container: container)
            #expect(try await repository.participant(eventID: eventID, displayCode: code)?.name == "Alex")
            let participant = try #require(
                try await repository.participant(eventID: eventID, displayCode: code)
            )
            _ = try await repository.closeEvent(id: eventID, at: .init(timeIntervalSince1970: 3))
            await #expect(throws: AthleteMemoryRepositoryError.eventClosed) {
                try await repository.createParticipant(
                    eventID: eventID, displayName: "Sam", experienceLevel: .advanced,
                    stance: .southpaw, at: .init(timeIntervalSince1970: 4)
                )
            }
            await #expect(throws: AthleteMemoryRepositoryError.eventClosed) {
                try await repository.saveParticipant(participant)
            }
        }
    }

    @Test("A failed file-backed participant save rolls back cleanly")
    func fileBackedRollback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "ParticipantRollback-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appending(path: "event.store")
        let event = try #require(EventEdition(
            id: UUID(), title: "Read Only", status: .open,
            openedAt: .init(timeIntervalSince1970: 1), closedAt: nil,
            scoringVersion: CompetitionScorer.scoringVersion,
            calibrationVersion: CompetitionPlayer.calibrationVersion
        ))
        do {
            let writable = try CompetitionModelContainer.make(storeURL: storeURL)
            _ = try await SwiftDataCompetitionRepository(container: writable).create(event: event)
        }

        let readOnly = try CompetitionModelContainer.make(storeURL: storeURL, allowsSave: false)
        let repository = SwiftDataCompetitionRepository(container: readOnly)
        await #expect(throws: CompetitionRepositoryError.self) {
            try await repository.createParticipant(
                eventID: event.id, displayName: "Alex", experienceLevel: .beginner,
                stance: .orthodox, at: .init(timeIntervalSince1970: 2)
            )
        }
        #expect(try await repository.participants(eventID: event.id).isEmpty)
    }

    private func submission(
        player: CompetitionPlayer,
        eventID: UUID?,
        score: Int
    ) -> CompetitionSubmission {
        CompetitionSubmission(
            id: UUID(), playerID: player.id, playerName: player.name,
            normalizedPlayerName: player.normalizedName, mode: .reactiveStrike,
            score: score, validSteps: 8, totalSteps: 8,
            completedRepetitions: 0, meanCentreErrorMeters: 0.01,
            speedTieBreakSeconds: 0.3,
            startedAt: .init(timeIntervalSince1970: 5),
            endedAt: .init(timeIntervalSince1970: 6), trackingStatus: .complete,
            eventID: eventID, scoringVersion: CompetitionScorer.scoringVersion,
            calibrationVersion: player.calibrationVersion,
            publicHandleSnapshot: player.publicHandle
        )
    }

    @Test("Profile experience maps to the two authored learning tracks")
    func experienceTrackMapping() async {
        let repository = InMemoryCompetitionRepository()
        let store = CompetitionStore(repository: repository)
        await store.bootstrap()

        await store.createParticipant(
            name: "Beginner",
            experienceLevel: .beginner,
            stance: .orthodox
        )
        #expect(store.currentTrainingTrack == .firstRound)

        await store.handoffToWelcome()
        await store.createParticipant(
            name: "Athlete",
            experienceLevel: .advanced,
            stance: .southpaw
        )
        #expect(store.currentTrainingTrack == .technicalCamp)
    }
}
