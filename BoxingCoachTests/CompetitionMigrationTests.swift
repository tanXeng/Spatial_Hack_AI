import Foundation
import SwiftData
import Testing
@testable import BoxingCoach

@Suite("Competition V1 to V2 migration")
@MainActor
struct CompetitionMigrationTests {
    @Test("V1 players and submissions migrate losslessly into one closed legacy event")
    func legacyFixtureMigratesLosslessly() throws {
        let fixture = try MigrationFixture.make()
        defer { fixture.remove() }
        try fixture.writeV1Store()

        let before = fixture.expectedStandings
        let container = try CompetitionModelContainer.make(storeURL: fixture.storeURL)
        let context = ModelContext(container)
        let events = try context.fetch(FetchDescriptor<CompetitionSchemaV2.EventEditionRecord>())
        let participants = try context.fetch(
            FetchDescriptor<CompetitionSchemaV2.CompetitionPlayerRecord>()
        ).sorted { $0.id.uuidString < $1.id.uuidString }
        let submissions = try context.fetch(
            FetchDescriptor<CompetitionSchemaV2.CompetitionSubmissionRecord>()
        ).sorted { $0.id.uuidString < $1.id.uuidString }

        let event = try #require(events.only)
        #expect(event.id == CompetitionLegacyMigration.eventID)
        #expect(event.title == "Legacy Event")
        #expect(event.statusRawValue == EventEditionStatus.closed.rawValue)
        #expect(event.openedAt == Date(timeIntervalSince1970: 1))
        #expect(event.closedAt == Date(timeIntervalSince1970: 30))

        #expect(participants.map(\.id) == fixture.players.map(\.id))
        #expect(participants.map(\.name) == fixture.players.map(\.name))
        #expect(participants.map(\.normalizedName) == fixture.players.map(\.normalizedName))
        #expect(participants.map(\.stanceRawValue) == fixture.players.map(\.rememberedStance.rawValue))
        #expect(participants.map(\.leftReach) == fixture.players.map { $0.reach?.left })
        #expect(participants.map(\.rightReach) == fixture.players.map { $0.reach?.right })
        #expect(participants.map(\.calibrationVersion) == fixture.players.map(\.calibrationVersion))
        #expect(participants.map(\.calibratedAt) == fixture.players.map(\.calibratedAt))
        #expect(participants.map(\.createdAt) == fixture.players.map(\.createdAt))
        #expect(participants.map(\.lastSeenAt) == fixture.players.map(\.lastSeenAt))
        #expect(participants.map(\.eventID) == [event.id, event.id])
        #expect(participants.map(\.publicDisplayCode) == ["0000", "0001"])
        #expect(Set(participants.compactMap(\.publicDisplayCode)).count == participants.count)

        #expect(submissions.map(\.id) == fixture.submissions.map(\.id))
        #expect(submissions.map(\.playerID) == fixture.submissions.map(\.playerID))
        #expect(submissions.map(\.playerName) == fixture.submissions.map(\.playerName))
        #expect(submissions.map(\.normalizedPlayerName) == fixture.submissions.map(\.normalizedPlayerName))
        #expect(submissions.map(\.modeRawValue) == fixture.submissions.map(\.mode.rawValue))
        #expect(submissions.map(\.score) == fixture.submissions.map(\.score))
        #expect(submissions.map(\.validSteps) == fixture.submissions.map(\.validSteps))
        #expect(submissions.map(\.totalSteps) == fixture.submissions.map(\.totalSteps))
        #expect(submissions.map(\.completedRepetitions) == fixture.submissions.map(\.completedRepetitions))
        #expect(submissions.map(\.meanCentreErrorMeters) == fixture.submissions.map(\.meanCentreErrorMeters))
        #expect(submissions.map(\.speedTieBreakSeconds) == fixture.submissions.map(\.speedTieBreakSeconds))
        #expect(submissions.map(\.startedAt) == fixture.submissions.map(\.startedAt))
        #expect(submissions.map(\.endedAt) == fixture.submissions.map(\.endedAt))
        #expect(submissions.map(\.trackingStatusRawValue) == fixture.submissions.map(\.trackingStatus.rawValue))
        #expect(submissions.allSatisfy { $0.eventID == event.id })
        #expect(submissions.map(\.publicDisplayName) == fixture.submissions.map(\.playerName))

        let migrated = submissions.compactMap(\.snapshot)
        let after = CompetitionLeaderboard.standings(mode: .reactiveStrike, submissions: migrated)
        #expect(after.map(\.rank) == before.map(\.rank))
        #expect(after.map(\.submission.id) == before.map(\.submission.id))
    }

    @Test("Reopening a V2 store does not rerun migration or duplicate the legacy event")
    func currentSchemaReopensWithoutDuplicateArchive() throws {
        let fixture = try MigrationFixture.make()
        defer { fixture.remove() }
        try fixture.writeV1Store()

        do {
            let first = try CompetitionModelContainer.make(storeURL: fixture.storeURL)
            let context = ModelContext(first)
            #expect(try context.fetchCount(
                FetchDescriptor<CompetitionSchemaV2.EventEditionRecord>()
            ) == 1)
        }

        let reopened = try CompetitionModelContainer.make(storeURL: fixture.storeURL)
        let context = ModelContext(reopened)
        #expect(try context.fetchCount(
            FetchDescriptor<CompetitionSchemaV2.EventEditionRecord>()
        ) == 1)
        #expect(try context.fetchCount(
            FetchDescriptor<CompetitionSchemaV2.CompetitionPlayerRecord>()
        ) == fixture.players.count)
        #expect(try context.fetchCount(
            FetchDescriptor<CompetitionSchemaV2.CompetitionSubmissionRecord>()
        ) == fixture.submissions.count)
    }
}

@MainActor
private struct MigrationFixture {
    let directoryURL: URL
    let storeURL: URL
    let players: [CompetitionPlayer]
    let submissions: [CompetitionSubmission]

    var expectedStandings: [CompetitionStanding] {
        CompetitionLeaderboard.standings(mode: .reactiveStrike, submissions: submissions)
    }

    static func make() throws -> MigrationFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompetitionMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let firstPlayer = CompetitionPlayer(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            name: "Alex Current",
            normalizedName: "alex current",
            rememberedStance: .orthodox,
            reach: BilateralReach(left: 0.66, right: 0.68),
            calibrationVersion: 1,
            calibratedAt: Date(timeIntervalSince1970: 6),
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 7)
        )
        let secondPlayer = CompetitionPlayer(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
            name: "Blair",
            normalizedName: "blair",
            rememberedStance: .southpaw,
            reach: BilateralReach(left: 0.61, right: 0.63),
            calibrationVersion: 1,
            calibratedAt: Date(timeIntervalSince1970: 4),
            createdAt: Date(timeIntervalSince1970: 2),
            lastSeenAt: Date(timeIntervalSince1970: 8)
        )
        let players = [firstPlayer, secondPlayer]
        let submissions = [
            submission(
                id: "00000000-0000-0000-0000-000000000311",
                player: firstPlayer,
                playerName: "Alex Original",
                score: 88,
                startedAt: 10,
                endedAt: 20
            ),
            submission(
                id: "00000000-0000-0000-0000-000000000312",
                player: secondPlayer,
                playerName: "Blair",
                score: 88,
                startedAt: 11,
                endedAt: 21
            ),
            submission(
                id: "00000000-0000-0000-0000-000000000313",
                player: firstPlayer,
                playerName: "Alex Original",
                score: 75,
                startedAt: 22,
                endedAt: 30
            )
        ]
        return MigrationFixture(
            directoryURL: directoryURL,
            storeURL: directoryURL.appendingPathComponent("competition.store"),
            players: players,
            submissions: submissions
        )
    }

    func writeV1Store() throws {
        let schema = Schema(versionedSchema: CompetitionSchemaV1.self)
        let configuration = ModelConfiguration(
            "CompetitionMigrationFixtureV1",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        players.forEach { context.insert(CompetitionPlayerRecord($0)) }
        submissions.forEach { context.insert(CompetitionSubmissionRecord($0)) }
        try context.save()
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private static func submission(
        id: String,
        player: CompetitionPlayer,
        playerName: String,
        score: Int,
        startedAt: TimeInterval,
        endedAt: TimeInterval
    ) -> CompetitionSubmission {
        CompetitionSubmission(
            id: UUID(uuidString: id)!,
            playerID: player.id,
            playerName: playerName,
            normalizedPlayerName: CompetitionName.normalized(playerName),
            mode: .reactiveStrike,
            score: score,
            validSteps: 7,
            totalSteps: 8,
            completedRepetitions: 0,
            meanCentreErrorMeters: 0.02,
            speedTieBreakSeconds: 0.31,
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: Date(timeIntervalSince1970: endedAt),
            trackingStatus: .complete
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
