import Foundation

nonisolated enum CoachLearnerLevel: String, Codable, Sendable {
    case beginner
}

nonisolated enum CoachScoreBand: String, Codable, Sendable {
    case needsWork = "needs_work"
    case developing
    case solid
    case excellent
}

nonisolated enum CoachCorrectionCode: String, Codable, Sendable {
    case wrongHand = "wrong_hand"
    case extensionReach = "extension_reach"
    case path
    case elbow
    case guardHand = "guard_hand"
    case retraction
    case repeatShape = "repeat_shape"

    var drill: CoachRelayDrill {
        switch self {
        case .wrongHand: .correctHand
        case .extensionReach: .fullExtension
        case .path: .straightLine
        case .elbow: .elbowTuck
        case .guardHand: .guardAnchor
        case .retraction: .snapBack
        case .repeatShape: .repeatShape
        }
    }
}

nonisolated enum CoachRelayDrill: String, Codable, Sendable {
    case correctHand = "correct_hand"
    case fullExtension = "full_extension"
    case straightLine = "straight_line"
    case elbowTuck = "elbow_tuck"
    case guardAnchor = "guard_anchor"
    case snapBack = "snap_back"
    case repeatShape = "repeat_shape"
}

nonisolated struct CoachRelayMetric: Codable, Equatable, Sendable {
    let name: String
    let value: Double
}

/// Privacy-minimized facts. No transcript, pose samples, body measurements, identifiers,
/// free-form history, or credentials cross the relay boundary.
nonisolated struct CoachRelayRequestFacts: Codable, Equatable, Sendable {
    let locale: String
    let learnerLevel: CoachLearnerLevel
    let technique: String
    let scoreBand: CoachScoreBand
    let trackedFraction: Double
    let metrics: [CoachRelayMetric]
    let correctionCode: CoachCorrectionCode
    let localCue: String
    let personalBest: Bool
    let validAttemptCount: Int
    let sameFocusCount: Int
}

nonisolated struct CoachRelayResponse: Equatable, Sendable {
    let schemaVersion: Int
    let requestID: String
    let correctionCode: CoachCorrectionCode
    let drill: CoachRelayDrill
    let spokenCue: String
    let why: String
    let encouragement: String
}

nonisolated enum CoachRelayError: Error, Equatable, Sendable {
    case offline
    case badResponse
    case malformedResponse
    case unknownResponseFields
    case unsupportedSchemaVersion
    case mismatchedRequestID
    case mismatchedCorrectionCode
    case unknownDrill
    case contradictoryResponse
    case emptyResponseField(field: String)
    case wordLimitExceeded(field: String, maximum: Int)
}

/// A provider-neutral client for the team's relay. The endpoint, transport, and time source are
/// injected so production contains no provider route and tests never need live network access.
nonisolated struct CoachRelayClient: Sendable {
    static let schemaVersion = 1

    private let endpoint: URL?
    private let session: URLSession
    private let clock: @Sendable () -> Date
    private let requestID: @Sendable () -> String

    static func liveSession(timeout: TimeInterval = 5) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    init(
        endpoint: URL?,
        session: URLSession = CoachRelayClient.liveSession(),
        clock: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.endpoint = endpoint
        self.session = session
        self.clock = clock
        self.requestID = requestID
    }

    func response(for facts: CoachRelayRequestFacts) async throws -> CoachRelayResponse {
        guard let endpoint else { throw CoachRelayError.offline }

        let envelope = RequestEnvelope(
            schemaVersion: Self.schemaVersion,
            requestID: requestID(),
            requestedAt: clock(),
            facts: facts
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(envelope)

        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            throw CoachRelayError.badResponse
        }

        return try Self.decode(
            data,
            expectedRequestID: envelope.requestID,
            expectedCorrectionCode: facts.correctionCode
        )
    }

    private static func decode(
        _ data: Data,
        expectedRequestID: String,
        expectedCorrectionCode: CoachCorrectionCode
    ) throws -> CoachRelayResponse {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CoachRelayError.malformedResponse
            }
            object = decoded
        } catch let error as CoachRelayError {
            throw error
        } catch {
            throw CoachRelayError.malformedResponse
        }

        let allowedKeys: Set<String> = [
            "schemaVersion",
            "requestID",
            "correctionCode",
            "drill",
            "spokenCue",
            "why",
            "encouragement"
        ]
        guard Set(object.keys) == allowedKeys else {
            throw CoachRelayError.unknownResponseFields
        }
        guard
            let schemaVersion = object["schemaVersion"] as? Int,
            let responseRequestID = object["requestID"] as? String,
            let correctionRawValue = object["correctionCode"] as? String,
            let drillRawValue = object["drill"] as? String,
            let spokenCue = object["spokenCue"] as? String,
            let why = object["why"] as? String,
            let encouragement = object["encouragement"] as? String
        else {
            throw CoachRelayError.malformedResponse
        }

        guard schemaVersion == Self.schemaVersion else {
            throw CoachRelayError.unsupportedSchemaVersion
        }
        guard responseRequestID == expectedRequestID else {
            throw CoachRelayError.mismatchedRequestID
        }
        guard let correctionCode = CoachCorrectionCode(rawValue: correctionRawValue) else {
            throw CoachRelayError.malformedResponse
        }
        guard correctionCode == expectedCorrectionCode else {
            throw CoachRelayError.mismatchedCorrectionCode
        }
        guard let drill = CoachRelayDrill(rawValue: drillRawValue) else {
            throw CoachRelayError.unknownDrill
        }
        guard drill == correctionCode.drill else {
            throw CoachRelayError.contradictoryResponse
        }

        try validate(spokenCue, field: "spokenCue", maximumWords: 18)
        try validate(why, field: "why", maximumWords: 24)
        try validate(encouragement, field: "encouragement", maximumWords: 18)

        return CoachRelayResponse(
            schemaVersion: schemaVersion,
            requestID: responseRequestID,
            correctionCode: correctionCode,
            drill: drill,
            spokenCue: spokenCue,
            why: why,
            encouragement: encouragement
        )
    }

    private static func validate(
        _ text: String,
        field: String,
        maximumWords: Int
    ) throws {
        let words = text.split(whereSeparator: \Character.isWhitespace)
        guard !words.isEmpty else {
            throw CoachRelayError.emptyResponseField(field: field)
        }
        guard words.count <= maximumWords else {
            throw CoachRelayError.wordLimitExceeded(field: field, maximum: maximumWords)
        }
    }

    private struct RequestEnvelope: Encodable {
        let schemaVersion: Int
        let requestID: String
        let requestedAt: Date
        let facts: CoachRelayRequestFacts
    }
}
