import Foundation

/// The ranked challenges. Reactive Strike is currently the only one.
///
/// Combo was removed from the competition layer — Combination Mode still exists as ordinary
/// (unranked) Reactive Strike training via `ReactiveStrikeMode.combination`; it simply is not
/// something you can compete at or appear on a leaderboard for.
///
/// Kept as an enum rather than collapsed away so submissions stay mode-tagged in the store: the
/// persisted schema already writes `modeRawValue`, and a record whose raw value no longer resolves
/// is dropped by `compactMap(\.snapshot)` rather than failing the load. That is what lets old combo
/// results disappear from a device that already has them without a migration.
nonisolated enum CompetitionMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case reactiveStrike

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reactiveStrike: return "Reactive Strike"
        }
    }

    var subtitle: String {
        switch self {
        case .reactiveStrike: return "Eight reaction targets"
        }
    }

    var totalSteps: Int {
        switch self {
        case .reactiveStrike: return 8
        }
    }
}

nonisolated struct BilateralReach: Codable, Hashable, Sendable {
    let left: Float
    let right: Float

    init?(left: Float, right: Float) {
        guard ReachCalibration.plausibleForwardRange.contains(left),
              ReachCalibration.plausibleForwardRange.contains(right)
        else { return nil }
        self.left = left
        self.right = right
    }

    init?(_ values: [BodySide: Float]) {
        guard let left = values[.left], let right = values[.right] else { return nil }
        self.init(left: left, right: right)
    }

    var bySide: [BodySide: Float] { [.left: left, .right: right] }
    var conservative: Float { min(left, right) }
}

nonisolated struct CompetitionPlayer: Identifiable, Codable, Hashable, Sendable {
    static let calibrationVersion = 1

    let id: UUID
    var name: String
    let normalizedName: String
    var rememberedStance: Stance
    var reach: BilateralReach?
    var calibrationVersion: Int?
    var calibratedAt: Date?
    let createdAt: Date
    var lastSeenAt: Date

    var hasCurrentCalibration: Bool {
        reach != nil && calibrationVersion == Self.calibrationVersion
    }
}

nonisolated enum CompetitionTrackingStatus: String, Codable, Hashable, Sendable {
    case complete
    case stale
    case technicalFailure
}

nonisolated struct CompetitionStepEvidence: Codable, Hashable, Sendable {
    let index: Int
    let valid: Bool
    let centreErrorMeters: Float?
    let reactionTime: TimeInterval?
    let requiredHand: BodySide?
    let returnedToGuard: Bool
}

nonisolated struct CompetitionEvidence: Codable, Hashable, Sendable {
    let mode: CompetitionMode
    let steps: [CompetitionStepEvidence]
    let completedRepetitions: Int
    let activeElapsedTime: TimeInterval?
    let trackingStatus: CompetitionTrackingStatus

    var validSteps: Int { steps.filter(isValid).count }
    var meanCentreError: Float? {
        let values = steps.compactMap { isValid($0) ? $0.centreErrorMeters : nil }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }
    var averageReactionTime: TimeInterval? {
        let values = steps.compactMap { isValid($0) ? $0.reactionTime : nil }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    func isValid(_ step: CompetitionStepEvidence) -> Bool {
        step.valid && (mode == .reactiveStrike || (step.requiredHand != nil && step.returnedToGuard))
    }
}

nonisolated struct CompetitionSubmission: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let playerID: UUID
    let playerName: String
    let normalizedPlayerName: String
    let mode: CompetitionMode
    let score: Int
    let validSteps: Int
    let totalSteps: Int
    let completedRepetitions: Int
    let meanCentreErrorMeters: Float?
    let speedTieBreakSeconds: TimeInterval?
    let startedAt: Date
    let endedAt: Date
    let trackingStatus: CompetitionTrackingStatus
}

nonisolated struct CompetitionStanding: Identifiable, Hashable, Sendable {
    let rank: Int
    let submission: CompetitionSubmission

    var id: UUID { submission.id }
}

nonisolated enum CompetitionInputError: LocalizedError, Equatable, Sendable {
    case nameLength
    case nameContainsControl
    case nameContainsUnsupportedCharacter

    var errorDescription: String? {
        switch self {
        case .nameLength: return "Player name must contain 2 to 24 characters."
        case .nameContainsControl: return "Player name cannot contain line breaks or control characters."
        case .nameContainsUnsupportedCharacter: return "Use letters, numbers, spaces, hyphens, or underscores."
        }
    }
}

nonisolated enum CompetitionName {
    static func display(_ raw: String) throws -> String {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CompetitionInputError.nameContainsControl
        }
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard (2...24).contains(collapsed.count) else { throw CompetitionInputError.nameLength }

        let punctuation = CharacterSet(charactersIn: "-_")
        guard collapsed.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0)
                || CharacterSet.whitespaces.contains($0)
                || punctuation.contains($0)
        }) else { throw CompetitionInputError.nameContainsUnsupportedCharacter }
        return collapsed
    }

    static func normalized(_ displayName: String) -> String {
        displayName.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }
}

nonisolated enum CompetitionScorer {
    static let targetRadius: Float = 0.12

    static func submission(
        id: UUID,
        player: CompetitionPlayer,
        evidence: CompetitionEvidence,
        startedAt: Date,
        endedAt: Date
    ) -> CompetitionSubmission? {
        guard evidence.trackingStatus == .complete,
              evidence.steps.count == evidence.mode.totalSteps,
              evidence.steps.map(\.index) == Array(0..<evidence.mode.totalSteps),
              endedAt >= startedAt
        else { return nil }

        let correctness = 80 * Double(evidence.validSteps) / Double(evidence.mode.totalSteps)
        let accuracyTotal = evidence.steps.reduce(0.0) { total, step in
            guard evidence.isValid(step),
                  let error = step.centreErrorMeters,
                  error.isFinite,
                  error >= 0
            else { return total }
            let normalized = min(max(1 - Double(error / targetRadius), 0), 1)
            return total + normalized
        }
        let accuracy = 20 * accuracyTotal / Double(evidence.mode.totalSteps)
        let score = min(max(Int((correctness + accuracy).rounded()), 0), 100)
        let speed = evidence.mode == .reactiveStrike
            ? evidence.averageReactionTime
            : evidence.activeElapsedTime

        return CompetitionSubmission(
            id: id,
            playerID: player.id,
            playerName: player.name,
            normalizedPlayerName: player.normalizedName,
            mode: evidence.mode,
            score: score,
            validSteps: evidence.validSteps,
            totalSteps: evidence.mode.totalSteps,
            completedRepetitions: evidence.completedRepetitions,
            meanCentreErrorMeters: evidence.meanCentreError,
            speedTieBreakSeconds: speed,
            startedAt: startedAt,
            endedAt: endedAt,
            trackingStatus: evidence.trackingStatus
        )
    }
}

nonisolated enum CompetitionLeaderboard {
    static func standings(
        mode: CompetitionMode,
        submissions: [CompetitionSubmission]
    ) -> [CompetitionStanding] {
        let eligible = submissions.filter {
            $0.mode == mode
                && $0.trackingStatus == .complete
                && $0.totalSteps == mode.totalSteps
        }
        let grouped = Dictionary(grouping: eligible, by: \.playerID)
        let best = grouped.values.compactMap { attempts in
            attempts.sorted(by: ranksBefore).first
        }.sorted {
            if rankingKey($0) != rankingKey($1) { return ranksBefore($0, $1) }
            if $0.normalizedPlayerName != $1.normalizedPlayerName {
                return $0.normalizedPlayerName < $1.normalizedPlayerName
            }
            return $0.id.uuidString < $1.id.uuidString
        }

        var previousKey: RankKey?
        var previousRank = 0
        return best.enumerated().map { offset, submission in
            let key = rankingKey(submission)
            let rank = key == previousKey ? previousRank : offset + 1
            previousKey = key
            previousRank = rank
            return CompetitionStanding(rank: rank, submission: submission)
        }
    }

    // `completedRepetitions` was the Combo board's first tie-break. Reactive Strike has no
    // repetitions, so with Combo gone from the competition layer that term is dead and both the
    // key field and the comparison branch come out rather than sitting here always comparing zero.
    private struct RankKey: Equatable {
        let score: Int
        let validSteps: Int
        let centreError: Float?
        let speed: TimeInterval?
    }

    private static func rankingKey(_ value: CompetitionSubmission) -> RankKey {
        RankKey(
            score: value.score,
            validSteps: value.validSteps,
            centreError: value.meanCentreErrorMeters,
            speed: value.speedTieBreakSeconds
        )
    }

    private static func ranksBefore(_ lhs: CompetitionSubmission, _ rhs: CompetitionSubmission) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.validSteps != rhs.validSteps { return lhs.validSteps > rhs.validSteps }
        if lhs.meanCentreErrorMeters != rhs.meanCentreErrorMeters {
            return optionalLower(lhs.meanCentreErrorMeters, rhs.meanCentreErrorMeters)
        }
        if lhs.speedTieBreakSeconds != rhs.speedTieBreakSeconds {
            return optionalLower(lhs.speedTieBreakSeconds, rhs.speedTieBreakSeconds)
        }
        if lhs.endedAt != rhs.endedAt { return lhs.endedAt < rhs.endedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func optionalLower<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?): return left < right
        case (_?, nil): return true
        default: return false
        }
    }
}
