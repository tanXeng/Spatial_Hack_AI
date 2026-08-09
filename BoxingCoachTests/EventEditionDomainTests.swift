import XCTest
@testable import BoxingCoach

final class EventEditionDomainTests: XCTestCase {
    private let eventID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testIdentityValidationNormalizesWithoutPublishingAProfileDirectory() throws {
        XCTAssertEqual(try EventInputValidator.alias("  Máya  _14  "), "Máya _14")
        XCTAssertEqual(EventInputValidator.normalizedAlias("Máya"), "maya")
        XCTAssertThrowsError(try EventInputValidator.alias("Maya\nGuest")) {
            XCTAssertEqual($0 as? EventInputError, .aliasContainsControl)
        }
        XCTAssertThrowsError(try EventInputValidator.alias("Maya🥊")) {
            XCTAssertEqual($0 as? EventInputError, .aliasContainsUnsupportedCharacter)
        }
    }

    func testChallengePointsHaveExactFiveHundredPointCeiling() throws {
        let event = try makeEvent()
        let run = makeRun(
            participant: makeParticipant(number: 1),
            ordinal: 1,
            centerError: 0,
            guardReturned: true,
            optedIn: true,
            rulesDigest: event.rulesDigest
        )

        let score = ChallengeScorer.score(run)
        XCTAssertEqual(score.totalPoints, 500)
        XCTAssertEqual(score.contactPoints, 300)
        XCTAssertEqual(score.accuracyPoints, 100)
        XCTAssertEqual(score.guardPoints, 100)
        XCTAssertEqual(ChallengeEligibility.reason(for: run, event: event), .eligible)
        XCTAssertFalse(ChallengeRulesV1.eventEdition.speedAffectsPoints)
    }

    func testValidMissCanEarnGuardPointsButNeverContactOrAccuracy() {
        let punch = ChallengePunchSnapshot(
            repetition: 1,
            punch: .jab,
            requiredHand: .left,
            state: .validMiss,
            centerErrorMeters: nil,
            returnedToGuard: true,
            trackingConfidence: 1
        )

        XCTAssertEqual(
            ChallengeScorer.score(punch),
            ChallengeScore(totalPoints: 10, contactPoints: 0, accuracyPoints: 0, guardPoints: 10)
        )
    }

    func testPrecisionUsesLockedRadiusAndIntegerRounding() {
        func points(error: Float) -> Int {
            ChallengeScorer.score(ChallengePunchSnapshot(
                repetition: 1, punch: .jab, requiredHand: .left,
                state: .validContact, centerErrorMeters: error,
                returnedToGuard: false, trackingConfidence: 1
            )).accuracyPoints
        }
        XCTAssertEqual(points(error: 0), 10)
        XCTAssertEqual(points(error: 0.049), 5)
        XCTAssertEqual(points(error: 0.051), 5)
        XCTAssertEqual(points(error: 0.10), 0)
        XCTAssertEqual(points(error: 0.20), 0)
    }

    func testLeaderboardUsesBestOfTwoAndCompetitionRanks() throws {
        let event = try makeEvent()
        let participants = (1...4).map(makeParticipant)
        let runs = [
            makeRun(participant: participants[0], ordinal: 1, centerError: 0.10, guardReturned: true, optedIn: true, rulesDigest: event.rulesDigest),
            makeRun(participant: participants[0], ordinal: 2, centerError: 0, guardReturned: true, optedIn: true, rulesDigest: event.rulesDigest),
            makeRun(participant: participants[1], ordinal: 1, centerError: 0.05, guardReturned: true, optedIn: true, rulesDigest: event.rulesDigest),
            makeRun(participant: participants[2], ordinal: 1, centerError: 0.05, guardReturned: true, optedIn: true, rulesDigest: event.rulesDigest),
            makeRun(participant: participants[3], ordinal: 1, centerError: 0.10, guardReturned: true, optedIn: true, rulesDigest: event.rulesDigest)
        ]

        let board = LeaderboardCalculator.standings(
            event: event,
            participants: participants,
            runs: runs,
            category: .overall
        )

        XCTAssertEqual(board.map(\.rank), [1, 2, 2, 4])
        XCTAssertEqual(board.map(\.totalPoints), [500, 450, 450, 400])
        XCTAssertEqual(board.first?.officialAttemptsCompleted, 2)
        XCTAssertEqual(board.first?.runID, runs[1].id)
    }

    func testPrivateAndIncompleteRunsCannotRank() throws {
        let event = try makeEvent()
        let privatePlayer = makeParticipant(number: 1)
        let publicPlayer = makeParticipant(number: 2)
        let privateRun = makeRun(
            participant: privatePlayer,
            ordinal: 1,
            centerError: 0,
            guardReturned: true,
            optedIn: false,
            rulesDigest: event.rulesDigest
        )
        var incomplete = makeRun(
            participant: publicPlayer,
            ordinal: 1,
            centerError: 0,
            guardReturned: true,
            optedIn: true,
            rulesDigest: event.rulesDigest
        )
        incomplete = TrainingRunSnapshot(
            id: incomplete.id,
            eventID: incomplete.eventID,
            participantID: incomplete.participantID,
            entryID: incomplete.entryID,
            aliasSnapshot: incomplete.aliasSnapshot,
            avatarIDSnapshot: incomplete.avatarIDSnapshot,
            plan: incomplete.plan,
            status: .partial,
            stance: incomplete.stance,
            startedAt: incomplete.startedAt,
            endedAt: incomplete.endedAt,
            officialOrdinal: incomplete.officialOrdinal,
            rulesDigest: incomplete.rulesDigest,
            challengeRepetitions: Array(incomplete.challengeRepetitions.prefix(4)),
            optedIntoLeaderboard: true,
            eligibilityReason: .partialResult
        )

        XCTAssertEqual(ChallengeEligibility.reason(for: privateRun, event: event), .privateResult)
        XCTAssertEqual(ChallengeEligibility.reason(for: incomplete, event: event), .partialResult)
        XCTAssertTrue(
            LeaderboardCalculator.standings(
                event: event,
                participants: [privatePlayer, publicPlayer],
                runs: [privateRun, incomplete],
                category: .overall
            ).isEmpty
        )
    }

    func testMostImprovedRequiresTwoComparableParticipants() throws {
        let event = try makeEvent()
        let first = makeParticipant(number: 1)
        let second = makeParticipant(number: 2)
        let firstRuns = [
            makeRun(participant: first, ordinal: 1, centerError: 0.10, guardReturned: true, optedIn: true, rulesDigest: event.rulesDigest),
            makeRun(participant: first, ordinal: 2, centerError: 0, guardReturned: true, optedIn: true, rulesDigest: event.rulesDigest)
        ]

        XCTAssertTrue(
            LeaderboardCalculator.standings(
                event: event,
                participants: [first],
                runs: firstRuns,
                category: .mostImproved
            ).isEmpty
        )

        let allRuns = firstRuns + [
            makeRun(participant: second, ordinal: 1, centerError: 0.10, guardReturned: true, optedIn: true, rulesDigest: event.rulesDigest),
            makeRun(participant: second, ordinal: 2, centerError: 0.05, guardReturned: true, optedIn: true, rulesDigest: event.rulesDigest)
        ]
        let board = LeaderboardCalculator.standings(
            event: event,
            participants: [first, second],
            runs: allRuns,
            category: .mostImproved
        )

        XCTAssertEqual(board.map(\.improvementPoints), [100, 50])
        XCTAssertEqual(board.map(\.rank), [1, 2])
    }

    func testEveryNoncompetitiveRunReasonIsExcluded() throws {
        let event = try makeEvent()
        let participant = makeParticipant(number: 1)
        let base = makeRun(
            participant: participant, ordinal: 1, centerError: 0,
            guardReturned: true, optedIn: true, rulesDigest: event.rulesDigest
        )
        let cases: [(TrainingRunSnapshot, EligibilityReason)] = [
            (copy(base, plan: .controlledOneTwoPractice), .unofficial),
            (copy(base, status: .technicalFailure), .technicalFailure),
            (copy(base, rulesDigest: "different"), .rulesMismatch),
            (copy(base, voided: true), .voided),
            (copy(base, officialOrdinal: 3), .trackingInsufficient),
            (copy(base, plan: .experimental), .experimental)
        ]
        for (run, reason) in cases {
            XCTAssertEqual(ChallengeEligibility.reason(for: run, event: event), reason)
        }
    }

    func testExportsContainOnlyPublicIdentityAndImmutableSnapshots() throws {
        let event = try makeEvent()
        let participant = makeParticipant(number: 1)
        let run = makeRun(
            participant: participant, ordinal: 1, centerError: 0,
            guardReturned: true, optedIn: true, rulesDigest: event.rulesDigest
        )
        let board = LeaderboardCalculator.standings(
            event: event, participants: [participant], runs: [run], category: .overall
        )
        let csv = EventExportBuilder.publicCSV(event: event, entries: board, runs: [run])
        XCTAssertTrue(csv.contains("Player 1"))
        XCTAssertTrue(csv.contains("500"))

        let json = try EventExportBuilder.fullEventJSON(
            event: event, participants: [participant], runs: [run], awards: []
        )
        let text = String(decoding: json, as: UTF8.self).lowercased()
        XCTAssertFalse(text.contains("rawhand"))
    }

    private func makeEvent() throws -> EventSnapshot {
        let rules = ChallengeRulesV1.eventEdition
        return EventSnapshot(
            id: eventID,
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

    private func makeParticipant(number: Int) -> ParticipantSnapshot {
        let participantID = UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", number))!
        let entryID = UUID(uuidString: String(format: "00000000-0000-0000-0002-%012d", number))!
        return ParticipantSnapshot(
            id: participantID,
            eventID: eventID,
            entryID: entryID,
            alias: "Player \(number)",
            normalizedAlias: "player \(number)",
            avatarID: AvatarChoice.all[(number - 1) % AvatarChoice.all.count].id,
            stance: .orthodox,
            competitorNumber: number,
            isLeaderboardPublic: true,
            lessonCompletedAt: fixedDate,
            coachOverrideAt: nil,
            createdAt: fixedDate,
            lastSeenAt: fixedDate,
            archived: false
        )
    }

    private func makeRun(
        participant: ParticipantSnapshot,
        ordinal: Int,
        centerError: Float,
        guardReturned: Bool,
        optedIn: Bool,
        rulesDigest: String
    ) -> TrainingRunSnapshot {
        let reps = (1...ChallengeRulesV1.repetitionCount).map { repetition in
            ChallengeRepSnapshot(
                repetition: repetition,
                jab: makePunch(
                    repetition: repetition,
                    punch: .jab,
                    side: participant.stance.leadSide,
                    centerError: centerError,
                    guardReturned: guardReturned
                ),
                cross: makePunch(
                    repetition: repetition,
                    punch: .cross,
                    side: participant.stance.rearSide,
                    centerError: centerError,
                    guardReturned: guardReturned
                )
            )
        }
        let runID = UUID(uuidString: String(
            format: "00000000-0000-0003-%04d-%012d",
            ordinal,
            participant.competitorNumber
        ))!
        return TrainingRunSnapshot(
            id: runID,
            eventID: eventID,
            participantID: participant.id,
            entryID: participant.entryID,
            aliasSnapshot: participant.alias,
            avatarIDSnapshot: participant.avatarID,
            plan: .controlledOneTwoOfficial,
            status: .completed,
            stance: participant.stance,
            startedAt: fixedDate,
            endedAt: fixedDate.addingTimeInterval(60),
            officialOrdinal: ordinal,
            rulesDigest: rulesDigest,
            challengeRepetitions: reps,
            optedIntoLeaderboard: optedIn,
            eligibilityReason: optedIn ? .eligible : .privateResult
        )
    }

    private func makePunch(
        repetition: Int,
        punch: PunchType,
        side: BodySide,
        centerError: Float,
        guardReturned: Bool
    ) -> ChallengePunchSnapshot {
        ChallengePunchSnapshot(
            repetition: repetition,
            punch: punch,
            requiredHand: side,
            state: .validContact,
            centerErrorMeters: centerError,
            returnedToGuard: guardReturned,
            trackingConfidence: 1
        )
    }

    private func copy(
        _ run: TrainingRunSnapshot,
        plan: TrainingPlan? = nil,
        status: TrainingRunStatus? = nil,
        rulesDigest: String? = nil,
        officialOrdinal: Int? = nil,
        voided: Bool? = nil
    ) -> TrainingRunSnapshot {
        TrainingRunSnapshot(
            id: run.id, eventID: run.eventID, participantID: run.participantID,
            entryID: run.entryID, aliasSnapshot: run.aliasSnapshot,
            avatarIDSnapshot: run.avatarIDSnapshot, plan: plan ?? run.plan,
            status: status ?? run.status, stance: run.stance,
            startedAt: run.startedAt, endedAt: run.endedAt,
            officialOrdinal: officialOrdinal ?? run.officialOrdinal,
            rulesDigest: rulesDigest ?? run.rulesDigest,
            lessonStages: run.lessonStages,
            challengeRepetitions: run.challengeRepetitions,
            technicalDiscardCount: run.technicalDiscardCount,
            trackingSummary: run.trackingSummary,
            selectedCorrectionID: run.selectedCorrectionID,
            narrationSource: run.narrationSource,
            optedIntoLeaderboard: run.optedIntoLeaderboard,
            eligibilityReason: run.eligibilityReason,
            voided: voided ?? run.voided
        )
    }
}
