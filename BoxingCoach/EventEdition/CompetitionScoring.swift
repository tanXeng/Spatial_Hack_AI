import Foundation

nonisolated struct ChallengeScore: Codable, Sendable, Equatable {
    let totalPoints: Int
    let contactPoints: Int
    let accuracyPoints: Int
    let guardPoints: Int

    static let zero = ChallengeScore(
        totalPoints: 0,
        contactPoints: 0,
        accuracyPoints: 0,
        guardPoints: 0
    )
}

nonisolated enum ChallengeScorer {
    static func score(_ snapshot: TrainingRunSnapshot) -> ChallengeScore {
        snapshot.challengeRepetitions.reduce(.zero) { running, repetition in
            adding(running, score(repetition.jab), score(repetition.cross))
        }
    }

    static func score(_ punch: ChallengePunchSnapshot) -> ChallengeScore {
        guard punch.state == .validContact || punch.state == .validMiss else { return .zero }

        let contact = punch.state == .validContact ? 30 : 0
        let accuracy: Int
        if punch.state == .validContact,
           let error = punch.centerErrorMeters,
           error.isFinite {
            let normalized = min(max(1 - error / ChallengeRulesV1.targetRadiusMeters, 0), 1)
            accuracy = Int((10 * normalized).rounded())
        } else {
            accuracy = 0
        }
        let guardPoints = punch.returnedToGuard ? 10 : 0

        return ChallengeScore(
            totalPoints: contact + accuracy + guardPoints,
            contactPoints: contact,
            accuracyPoints: accuracy,
            guardPoints: guardPoints
        )
    }

    static func isCompleteOfficialChallenge(_ snapshot: TrainingRunSnapshot) -> Bool {
        guard snapshot.plan == .controlledOneTwoOfficial,
              snapshot.status == .completed,
              snapshot.challengeRepetitions.count == ChallengeRulesV1.repetitionCount,
              snapshot.officialOrdinal.map({ (1...ChallengeRulesV1.maxOfficialAttempts).contains($0) }) == true
        else { return false }

        let punches = snapshot.challengeRepetitions.flatMap { [$0.jab, $0.cross] }
        return punches.count == ChallengeRulesV1.repetitionCount * ChallengeRulesV1.punchesPerRepetition
            && !punches.contains(where: { $0.state == .technicalDiscard })
            && punches.allSatisfy { $0.trackingConfidence.isFinite && $0.trackingConfidence >= 0.6 }
    }

    private static func adding(
        _ base: ChallengeScore,
        _ first: ChallengeScore,
        _ second: ChallengeScore
    ) -> ChallengeScore {
        ChallengeScore(
            totalPoints: base.totalPoints + first.totalPoints + second.totalPoints,
            contactPoints: base.contactPoints + first.contactPoints + second.contactPoints,
            accuracyPoints: base.accuracyPoints + first.accuracyPoints + second.accuracyPoints,
            guardPoints: base.guardPoints + first.guardPoints + second.guardPoints
        )
    }
}

nonisolated struct SelectedCorrection: Sendable, Equatable {
    let id: String
    let evidence: String
    let sentence: String
}

nonisolated enum ChallengeCorrectionSelector {
    /// Chooses one correction from frozen scoring evidence before any narration is requested.
    static func select(score: ChallengeScore) -> SelectedCorrection {
        let deficits: [(Int, SelectedCorrection)] = [
            (300 - score.contactPoints, .init(
                id: "closed-fist-contact",
                evidence: "one or more required-hand contacts were not confidently measured",
                sentence: "Close your fist gently and send the required hand through the centre."
            )),
            (100 - score.guardPoints, .init(
                id: "return-to-guard",
                evidence: "one or more hands finished outside the calibrated guard region",
                sentence: "Bring each hand directly back to guard after it travels out."
            )),
            (100 - score.accuracyPoints, .init(
                id: "target-centre",
                evidence: "valid contacts landed away from the target centre",
                sentence: "Aim each controlled punch through the centre mark."
            ))
        ]
        return deficits.max(by: { $0.0 < $1.0 })?.1 ?? SelectedCorrection(
            id: "repeat-controlled-shape",
            evidence: "all observable components were complete",
            sentence: "Repeat the same controlled jab, cross, and guard return."
        )
    }
}

nonisolated enum ChallengeEligibility {
    static func reason(
        for run: TrainingRunSnapshot,
        event: EventSnapshot,
        expectedRules: ChallengeRulesV1 = .eventEdition
    ) -> EligibilityReason {
        if run.voided || run.status == .voided { return .voided }
        if run.plan == .experimental { return .experimental }
        guard run.plan == .controlledOneTwoOfficial else { return .unofficial }
        guard run.status == .completed else {
            return run.status == .technicalFailure ? .technicalFailure : .partialResult
        }
        guard event.status == .open || (event.closedAt.map { run.endedAt <= $0 } ?? false) else {
            return .competitionClosed
        }
        guard event.challengeID == expectedRules.challengeID else { return .wrongChallenge }
        guard event.scoringVersion == expectedRules.scoringVersion else { return .wrongScoringVersion }
        guard run.rulesDigest == event.rulesDigest else { return .rulesMismatch }
        guard ChallengeScorer.isCompleteOfficialChallenge(run) else { return .trackingInsufficient }
        guard run.optedIntoLeaderboard else { return .privateResult }
        return .eligible
    }
}

nonisolated struct LeaderboardEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let rank: Int
    let participantID: UUID
    let entryID: UUID
    let runID: UUID
    let avatarID: String
    let alias: String
    let competitorNumber: Int
    let officialAttemptsCompleted: Int
    let totalPoints: Int
    let contactPoints: Int
    let accuracyPoints: Int
    let guardPoints: Int
    let improvementPoints: Int?

    var competitorLabel: String { String(format: "#%03d", competitorNumber) }
}

nonisolated struct AwardSnapshot: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let eventID: UUID
    let category: LeaderboardCategory
    let rank: Int
    let participantID: UUID
    let winningRunID: UUID
    let aliasSnapshot: String
    let avatarIDSnapshot: String
    let displayedValue: Int
    let declaredAt: Date
    let rulesDigest: String
    let tieExplanation: String?
}

nonisolated enum LeaderboardCalculator {
    static func standings(
        event: EventSnapshot,
        participants: [ParticipantSnapshot],
        runs: [TrainingRunSnapshot],
        category: LeaderboardCategory
    ) -> [LeaderboardEntry] {
        let participantByID = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })
        let eligible = runs.filter {
            ChallengeEligibility.reason(for: $0, event: event) == .eligible
                && $0.participantID != nil
                && $0.entryID != nil
        }

        if category == .mostImproved {
            return improvedStandings(
                participants: participantByID,
                eligibleRuns: eligible
            )
        }

        let grouped = Dictionary(grouping: eligible, by: { $0.participantID! })
        var candidates: [(participant: ParticipantSnapshot, run: TrainingRunSnapshot, score: ChallengeScore, attempts: Int)] = []

        for (participantID, participantRuns) in grouped {
            guard let participant = participantByID[participantID], !participant.archived else { continue }
            let scored = participantRuns.map { ($0, ChallengeScorer.score($0)) }
            guard let best = scored.sorted(by: { compare($0.1, $1.1, category: .overall) }).first else { continue }
            candidates.append((participant, best.0, best.1, participantRuns.count))
        }

        candidates.sort {
            let lhs = rankingValues(score: $0.score, improvement: nil, category: category)
            let rhs = rankingValues(score: $1.score, improvement: nil, category: category)
            if lhs != rhs { return lexicographicallyGreater(lhs, rhs) }
            return $0.participant.competitorNumber < $1.participant.competitorNumber
        }

        var previousValues: [Int]?
        var previousRank = 0
        return candidates.enumerated().map { index, candidate in
            let values = rankingValues(score: candidate.score, improvement: nil, category: category)
            let rank = values == previousValues ? previousRank : index + 1
            previousValues = values
            previousRank = rank
            return entry(
                candidate.participant,
                run: candidate.run,
                score: candidate.score,
                attempts: candidate.attempts,
                rank: rank,
                improvement: nil
            )
        }
    }

    static func awards(
        event: EventSnapshot,
        participants: [ParticipantSnapshot],
        runs: [TrainingRunSnapshot],
        declaredAt: Date
    ) -> [AwardSnapshot] {
        var result: [AwardSnapshot] = []
        for category in LeaderboardCategory.allCases {
            let board = standings(event: event, participants: participants, runs: runs, category: category)
            guard !board.isEmpty else { continue }
            if category == .mostImproved,
               Set(board.map(\.participantID)).count < 2 {
                continue
            }

            let winningRank = board[0].rank
            let winners = category == .overall
                ? board.filter { $0.rank <= 3 }
                : board.filter { $0.rank == winningRank }
            let tiedWinnerCount = winners.filter { $0.rank == 1 }.count

            result.append(contentsOf: winners.map { winner in
                AwardSnapshot(
                    id: UUID(),
                    eventID: event.id,
                    category: category,
                    rank: winner.rank,
                    participantID: winner.participantID,
                    winningRunID: winner.runID,
                    aliasSnapshot: winner.alias,
                    avatarIDSnapshot: winner.avatarID,
                    displayedValue: displayedValue(winner, category: category),
                    declaredAt: declaredAt,
                    rulesDigest: event.rulesDigest,
                    tieExplanation: tiedWinnerCount > 1 && winner.rank == 1
                        ? "Joint winner after every published tie-break field matched."
                        : nil
                )
            })
        }
        return result
    }

    private static func improvedStandings(
        participants: [UUID: ParticipantSnapshot],
        eligibleRuns: [TrainingRunSnapshot]
    ) -> [LeaderboardEntry] {
        let grouped = Dictionary(grouping: eligibleRuns, by: { $0.participantID! })
        var candidates: [(ParticipantSnapshot, TrainingRunSnapshot, ChallengeScore, Int, Int)] = []

        for (participantID, participantRuns) in grouped {
            guard let participant = participants[participantID], !participant.archived else { continue }
            let byOrdinal = Dictionary(
                participantRuns.compactMap { run in run.officialOrdinal.map { ($0, run) } },
                uniquingKeysWith: { first, _ in first }
            )
            guard let first = byOrdinal[1], let second = byOrdinal[2] else { continue }
            let firstScore = ChallengeScorer.score(first)
            let secondScore = ChallengeScorer.score(second)
            candidates.append((
                participant,
                second,
                secondScore,
                secondScore.totalPoints - firstScore.totalPoints,
                participantRuns.count
            ))
        }

        // The award is intentionally absent until at least two people have comparable two-attempt data.
        guard candidates.count >= 2 else { return [] }
        candidates.sort {
            let lhs = rankingValues(score: $0.2, improvement: $0.3, category: .mostImproved)
            let rhs = rankingValues(score: $1.2, improvement: $1.3, category: .mostImproved)
            if lhs != rhs { return lexicographicallyGreater(lhs, rhs) }
            return $0.0.competitorNumber < $1.0.competitorNumber
        }

        var previousValues: [Int]?
        var previousRank = 0
        return candidates.enumerated().map { index, candidate in
            let values = rankingValues(score: candidate.2, improvement: candidate.3, category: .mostImproved)
            let rank = values == previousValues ? previousRank : index + 1
            previousValues = values
            previousRank = rank
            return entry(
                candidate.0,
                run: candidate.1,
                score: candidate.2,
                attempts: candidate.4,
                rank: rank,
                improvement: candidate.3
            )
        }
    }

    private static func compare(
        _ lhs: ChallengeScore,
        _ rhs: ChallengeScore,
        category: LeaderboardCategory
    ) -> Bool {
        lexicographicallyGreater(
            rankingValues(score: lhs, improvement: nil, category: category),
            rankingValues(score: rhs, improvement: nil, category: category)
        )
    }

    private static func rankingValues(
        score: ChallengeScore,
        improvement: Int?,
        category: LeaderboardCategory
    ) -> [Int] {
        switch category {
        case .overall:
            return [score.totalPoints, score.contactPoints, score.accuracyPoints, score.guardPoints]
        case .cleanSequence:
            return [score.contactPoints + score.guardPoints, score.totalPoints, score.accuracyPoints]
        case .centreAccuracy:
            return [score.accuracyPoints, score.totalPoints, score.guardPoints]
        case .guardDiscipline:
            return [score.guardPoints, score.totalPoints, score.accuracyPoints]
        case .mostImproved:
            return [improvement ?? Int.min, score.totalPoints, score.accuracyPoints]
        }
    }

    private static func lexicographicallyGreater(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right { return left > right }
        return false
    }

    private static func entry(
        _ participant: ParticipantSnapshot,
        run: TrainingRunSnapshot,
        score: ChallengeScore,
        attempts: Int,
        rank: Int,
        improvement: Int?
    ) -> LeaderboardEntry {
        LeaderboardEntry(
            id: run.id,
            rank: rank,
            participantID: participant.id,
            entryID: participant.entryID,
            runID: run.id,
            avatarID: participant.avatarID,
            alias: participant.alias,
            competitorNumber: participant.competitorNumber,
            officialAttemptsCompleted: min(attempts, ChallengeRulesV1.maxOfficialAttempts),
            totalPoints: score.totalPoints,
            contactPoints: score.contactPoints,
            accuracyPoints: score.accuracyPoints,
            guardPoints: score.guardPoints,
            improvementPoints: improvement
        )
    }

    private static func displayedValue(_ entry: LeaderboardEntry, category: LeaderboardCategory) -> Int {
        switch category {
        case .overall: return entry.totalPoints
        case .cleanSequence: return entry.contactPoints + entry.guardPoints
        case .centreAccuracy: return entry.accuracyPoints
        case .guardDiscipline: return entry.guardPoints
        case .mostImproved: return entry.improvementPoints ?? 0
        }
    }
}
