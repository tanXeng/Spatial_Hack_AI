import CryptoKit
import Foundation

nonisolated enum EventStatus: String, Codable, Sendable, CaseIterable {
    case draft
    case open
    case closed
    case archived
}

nonisolated enum TrainingPlan: String, Codable, Hashable, Sendable, CaseIterable {
    case guidedCore
    case controlledOneTwoPractice
    case controlledOneTwoOfficial
    case observeOnly
    case experimental
}

nonisolated enum TrainingRunStatus: String, Codable, Sendable {
    case inProgress
    case completed
    case partial
    case technicalFailure
    case interrupted
    case savePending
    case voided
}

nonisolated enum LeaderboardCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case overall
    case cleanSequence
    case centreAccuracy
    case guardDiscipline
    case mostImproved

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overall: return "Overall"
        case .cleanSequence: return "Clean Sequence"
        case .centreAccuracy: return "Centre Accuracy"
        case .guardDiscipline: return "Guard Discipline"
        case .mostImproved: return "Most Improved"
        }
    }
}

nonisolated enum EligibilityReason: String, Codable, Sendable {
    case eligible
    case privateResult
    case partialResult
    case technicalFailure
    case competitionClosed
    case wrongChallenge
    case wrongScoringVersion
    case rulesMismatch
    case trackingInsufficient
    case unofficial
    case voided
    case experimental

    var displayText: String {
        switch self {
        case .eligible: return "Eligible"
        case .privateResult: return "Private Result — not published"
        case .partialResult: return "Partial Result — challenge not completed"
        case .technicalFailure: return "Technical Failure — official attempt not consumed"
        case .competitionClosed: return "Competition Closed — saved privately"
        case .wrongChallenge: return "Different challenge"
        case .wrongScoringVersion: return "Different scoring version"
        case .rulesMismatch: return "Rules did not match this event"
        case .trackingInsufficient: return "Tracking evidence was insufficient"
        case .unofficial: return "Practice result"
        case .voided: return "Result voided by host"
        case .experimental: return "Experimental sessions never rank"
        }
    }
}

nonisolated struct ChallengeRulesV1: Codable, Hashable, Sendable {
    static let challengeID = "controlled-one-two"
    static let scoringVersion = 1
    static let repetitionCount = 5
    static let punchesPerRepetition = 2
    static let maxOfficialAttempts = 2
    static let targetRadiusMeters: Float = 0.10
    static let guardRadiusMeters: Float = 0.14
    static let minimumOutboundTravelMeters: Float = 0.10
    static let antiJitterVelocityMetersPerSecond: Float = 0.20

    let challengeID: String
    let scoringVersion: Int
    let repetitionCount: Int
    let maxOfficialAttempts: Int
    let targetRadiusMeters: Float
    let guardRadiusMeters: Float
    let minimumOutboundTravelMeters: Float
    let antiJitterVelocityMetersPerSecond: Float
    let speedAffectsPoints: Bool

    static let eventEdition = ChallengeRulesV1(
        challengeID: challengeID,
        scoringVersion: scoringVersion,
        repetitionCount: repetitionCount,
        maxOfficialAttempts: maxOfficialAttempts,
        targetRadiusMeters: targetRadiusMeters,
        guardRadiusMeters: guardRadiusMeters,
        minimumOutboundTravelMeters: minimumOutboundTravelMeters,
        antiJitterVelocityMetersPerSecond: antiJitterVelocityMetersPerSecond,
        speedAffectsPoints: false
    )

    var maximumPoints: Int { repetitionCount * 100 }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    func digest() throws -> String {
        SHA256.hash(data: try encoded()).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct EventDraft: Sendable, Equatable {
    var title: String
    var timeZoneIdentifier: String

    static let defaultEvent = EventDraft(
        title: "Hacklings Demo Day",
        timeZoneIdentifier: "Asia/Singapore"
    )
}

nonisolated struct EventSnapshot: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var title: String
    var timeZoneIdentifier: String
    var status: EventStatus
    var createdAt: Date
    var startedAt: Date?
    var closedAt: Date?
    var challengeID: String
    var scoringVersion: Int
    var rulesData: Data
    var rulesDigest: String
    var maxOfficialAttempts: Int
}

nonisolated struct AvatarChoice: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let symbolName: String
    let colorName: String

    static let all: [AvatarChoice] = [
        .init(id: "comet-cyan", symbolName: "sparkles", colorName: "cyan"),
        .init(id: "bolt-mint", symbolName: "bolt.fill", colorName: "mint"),
        .init(id: "star-amber", symbolName: "star.fill", colorName: "amber"),
        .init(id: "shield-indigo", symbolName: "shield.fill", colorName: "indigo"),
        .init(id: "flame-coral", symbolName: "flame.fill", colorName: "coral"),
        .init(id: "moon-purple", symbolName: "moon.fill", colorName: "purple"),
        .init(id: "sun-yellow", symbolName: "sun.max.fill", colorName: "yellow"),
        .init(id: "heart-red", symbolName: "heart.fill", colorName: "red"),
        .init(id: "leaf-green", symbolName: "leaf.fill", colorName: "green"),
        .init(id: "wave-blue", symbolName: "water.waves", colorName: "blue"),
        .init(id: "crown-orange", symbolName: "crown.fill", colorName: "orange"),
        .init(id: "circle-teal", symbolName: "circle.hexagongrid.fill", colorName: "teal")
    ]
}

nonisolated struct ParticipantDraft: Sendable, Equatable {
    var alias: String
    var avatarID: String
    var stance: Stance
    var isLeaderboardPublic: Bool
}

nonisolated struct ParticipantSnapshot: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let eventID: UUID
    let entryID: UUID
    var alias: String
    var normalizedAlias: String
    var avatarID: String
    var stance: Stance
    var competitorNumber: Int
    var isLeaderboardPublic: Bool
    var lessonCompletedAt: Date?
    var coachOverrideAt: Date?
    var createdAt: Date
    var lastSeenAt: Date
    var archived: Bool

    var competitorLabel: String {
        String(format: "#%03d", competitorNumber)
    }
}

nonisolated enum EventInputError: LocalizedError, Equatable, Sendable {
    case eventTitleLength
    case eventTitleContainsControl
    case invalidTimeZone
    case aliasLength
    case aliasContainsControl
    case aliasContainsUnsupportedCharacter

    var errorDescription: String? {
        switch self {
        case .eventTitleLength: return "Event name must contain 2 to 40 characters."
        case .eventTitleContainsControl: return "Event name cannot contain line breaks or control characters."
        case .invalidTimeZone: return "Choose a valid time zone."
        case .aliasLength: return "Nickname must contain 2 to 18 characters."
        case .aliasContainsControl: return "Nickname cannot contain line breaks or control characters."
        case .aliasContainsUnsupportedCharacter: return "Use letters, numbers, spaces, hyphens, or underscores."
        }
    }
}

nonisolated enum EventInputValidator {
    static func eventTitle(_ raw: String) throws -> String {
        guard !containsLineBreakOrControl(raw) else { throw EventInputError.eventTitleContainsControl }
        let result = raw.trimmingCharacters(in: .whitespaces)
        guard (2...40).contains(result.count) else { throw EventInputError.eventTitleLength }
        return result
    }

    static func timeZone(_ identifier: String) throws -> String {
        guard TimeZone(identifier: identifier) != nil else { throw EventInputError.invalidTimeZone }
        return identifier
    }

    static func alias(_ raw: String) throws -> String {
        guard !containsLineBreakOrControl(raw) else { throw EventInputError.aliasContainsControl }
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard (2...18).contains(collapsed.count) else { throw EventInputError.aliasLength }

        let allowedPunctuation = CharacterSet(charactersIn: "-_")
        for scalar in collapsed.unicodeScalars {
            guard CharacterSet.alphanumerics.contains(scalar)
                    || CharacterSet.whitespaces.contains(scalar)
                    || allowedPunctuation.contains(scalar)
            else { throw EventInputError.aliasContainsUnsupportedCharacter }
        }
        return collapsed
    }

    static func normalizedAlias(_ alias: String) -> String {
        alias
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    private static func containsLineBreakOrControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }
}

nonisolated struct TrainingRunContext: Codable, Sendable, Equatable {
    let runID: UUID
    let eventID: UUID
    let participantID: UUID?
    let entryID: UUID?
    let aliasSnapshot: String?
    let avatarIDSnapshot: String?
    let plan: TrainingPlan
    let stance: Stance
    let startedAt: Date
    let officialOrdinal: Int?
    let rulesDigest: String
}

nonisolated enum ChallengePunchState: String, Codable, Sendable {
    case validContact
    case validMiss
    case wrongHand
    case openHand
    case noOutbound
    case timeout
    case technicalDiscard
}

nonisolated struct ChallengePunchSnapshot: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let repetition: Int
    let punch: PunchType
    let requiredHand: BodySide
    let state: ChallengePunchState
    let centerErrorMeters: Float?
    let returnedToGuard: Bool
    let trackingConfidence: Float

    init(
        id: UUID = UUID(),
        repetition: Int,
        punch: PunchType,
        requiredHand: BodySide,
        state: ChallengePunchState,
        centerErrorMeters: Float?,
        returnedToGuard: Bool,
        trackingConfidence: Float
    ) {
        self.id = id
        self.repetition = repetition
        self.punch = punch
        self.requiredHand = requiredHand
        self.state = state
        self.centerErrorMeters = centerErrorMeters
        self.returnedToGuard = returnedToGuard
        self.trackingConfidence = trackingConfidence
    }
}

nonisolated struct ChallengeRepSnapshot: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let repetition: Int
    let jab: ChallengePunchSnapshot
    let cross: ChallengePunchSnapshot

    init(id: UUID = UUID(), repetition: Int, jab: ChallengePunchSnapshot, cross: ChallengePunchSnapshot) {
        self.id = id
        self.repetition = repetition
        self.jab = jab
        self.cross = cross
    }
}

nonisolated struct LessonMetricSnapshot: Codable, Sendable, Equatable {
    enum Availability: String, Codable, Sendable { case measured, unavailable }

    let id: String
    let availability: Availability
    let value: Float?
    let confidence: Float
    let evidence: String
}

nonisolated struct LessonStageSnapshot: Codable, Sendable, Equatable {
    let stageID: String
    let completedAt: Date
    let metrics: [LessonMetricSnapshot]
}

nonisolated struct TrainingRunSnapshot: Identifiable, Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    let eventID: UUID
    let participantID: UUID?
    let entryID: UUID?
    let aliasSnapshot: String?
    let avatarIDSnapshot: String?
    let plan: TrainingPlan
    let status: TrainingRunStatus
    let stance: Stance
    let startedAt: Date
    let endedAt: Date
    let officialOrdinal: Int?
    let rulesDigest: String
    let lessonStages: [LessonStageSnapshot]
    let challengeRepetitions: [ChallengeRepSnapshot]
    let technicalDiscardCount: Int
    let trackingSummary: String
    let selectedCorrectionID: String?
    let narrationSource: String
    let optedIntoLeaderboard: Bool
    let eligibilityReason: EligibilityReason
    let voided: Bool

    init(
        id: UUID,
        schemaVersion: Int = TrainingRunSnapshot.schemaVersion,
        eventID: UUID,
        participantID: UUID?,
        entryID: UUID?,
        aliasSnapshot: String?,
        avatarIDSnapshot: String?,
        plan: TrainingPlan,
        status: TrainingRunStatus,
        stance: Stance,
        startedAt: Date,
        endedAt: Date,
        officialOrdinal: Int?,
        rulesDigest: String,
        lessonStages: [LessonStageSnapshot] = [],
        challengeRepetitions: [ChallengeRepSnapshot] = [],
        technicalDiscardCount: Int = 0,
        trackingSummary: String = "",
        selectedCorrectionID: String? = nil,
        narrationSource: String = "deterministic",
        optedIntoLeaderboard: Bool = false,
        eligibilityReason: EligibilityReason,
        voided: Bool = false
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.participantID = participantID
        self.entryID = entryID
        self.aliasSnapshot = aliasSnapshot
        self.avatarIDSnapshot = avatarIDSnapshot
        self.plan = plan
        self.status = status
        self.stance = stance
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.officialOrdinal = officialOrdinal
        self.rulesDigest = rulesDigest
        self.lessonStages = lessonStages
        self.challengeRepetitions = challengeRepetitions
        self.technicalDiscardCount = technicalDiscardCount
        self.trackingSummary = trackingSummary
        self.selectedCorrectionID = selectedCorrectionID
        self.narrationSource = narrationSource
        self.optedIntoLeaderboard = optedIntoLeaderboard
        self.eligibilityReason = eligibilityReason
        self.voided = voided
    }
}

nonisolated struct RunCheckpoint: Codable, Sendable, Equatable {
    let runID: UUID
    let completedStageID: String
    let snapshotData: Data
    let createdAt: Date
}

nonisolated enum CommitOutcome: Sendable, Equatable {
    case committed(runID: UUID)
    case alreadyFinalized(runID: UUID)
}
