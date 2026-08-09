import Foundation

nonisolated enum CoachLearnerLevel: String, Codable, Sendable, Equatable {
    case beginner
    case athlete
}

nonisolated enum CoachScoreBand: String, Codable, Sendable {
    case needsWork = "needs_work"
    case developing
    case solid
    case excellent
}

nonisolated enum CoachCorrectionCode: String, Codable, Sendable {
    case trackingRecovery = "tracking_recovery"
    case wrongHand = "wrong_hand"
    case extensionReach = "extension_reach"
    case path
    case elbow
    case guardHand = "guard_hand"
    case retraction
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
    let spokenCue: String
    let whyItMatters: String
    let encouragement: String
}

nonisolated enum CoachRelayError: Error, Equatable, Sendable {
    case offline
    case refused
    case timedOut
    case badResponse
    case malformedResponse
    case unknownResponseFields
    case unsupportedSchemaVersion
    case invalidRequestID
    case mismatchedRequestID
    case mismatchedCorrectionCode
    case emptyResponseField(field: String)
    case wordLimitExceeded(field: String, maximum: Int)
}

nonisolated struct CoachRelayTransportResponse: Sendable {
    let data: Data
    let statusCode: Int?
}

/// Narrow, cancellable request boundary used by production URL loading and deterministic tests.
nonisolated protocol CoachRelayTransport: Sendable {
    func response(for request: URLRequest) async throws -> CoachRelayTransportResponse
}

nonisolated struct URLSessionCoachRelayTransport: CoachRelayTransport {
    let session: URLSession

    func response(for request: URLRequest) async throws -> CoachRelayTransportResponse {
        let (data, response) = try await session.data(for: request)
        return CoachRelayTransportResponse(
            data: data,
            statusCode: (response as? HTTPURLResponse)?.statusCode
        )
    }
}

/// The deadline clock is injected so timeout tests advance virtual time instead of sleeping.
nonisolated protocol CoachRelayClock: Sendable {
    func sleep(for duration: Duration) async throws
}

nonisolated struct ContinuousCoachRelayClock: CoachRelayClock {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

/// A provider-neutral client for the team's relay. The endpoint, transport, and time source are
/// injected so production contains no provider route and tests never need live network access.
nonisolated struct CoachRelayClient: Sendable {
    static let schemaVersion = 1
    private static let phrasingDeadline: Duration = .milliseconds(1_500)

    private let endpoint: URL?
    private let transport: any CoachRelayTransport
    private let deadlineClock: any CoachRelayClock
    private let deadline: Duration
    private let requestDate: @Sendable () -> Date
    private let requestID: @Sendable () -> String

    static func liveSession(timeout: TimeInterval = 1.5) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// A request-scoped correlation token with no timestamp, device data, or participant data.
    static func makeRequestID() -> String {
        var generator = SystemRandomNumberGenerator()
        let randomBytes = (0..<16).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }
        return "req_" + randomBytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isValidRequestID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36, bytes.starts(with: Array("req_".utf8)) else { return false }
        return bytes.dropFirst(4).allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    init(
        endpoint: URL?,
        session: URLSession = CoachRelayClient.liveSession(),
        clock: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> String = { CoachRelayClient.makeRequestID() }
    ) {
        self.init(
            endpoint: endpoint,
            transport: URLSessionCoachRelayTransport(session: session),
            deadlineClock: ContinuousCoachRelayClock(),
            deadline: Self.phrasingDeadline,
            requestDate: clock,
            requestID: requestID
        )
    }

    init(
        endpoint: URL?,
        transport: any CoachRelayTransport,
        deadlineClock: any CoachRelayClock,
        deadline: Duration = .milliseconds(1_500),
        requestDate: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> String = { CoachRelayClient.makeRequestID() }
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.deadlineClock = deadlineClock
        self.deadline = deadline
        self.requestDate = requestDate
        self.requestID = requestID
    }

    func response(for facts: CoachRelayRequestFacts) async throws -> CoachRelayResponse {
        guard let endpoint else { throw CoachRelayError.offline }

        let outboundRequestID = requestID()
        guard Self.isValidRequestID(outboundRequestID) else {
            throw CoachRelayError.invalidRequestID
        }

        let envelope = RequestEnvelope(
            schemaVersion: Self.schemaVersion,
            requestID: outboundRequestID,
            requestedAt: requestDate(),
            facts: facts
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(envelope)

        let transportResponse = try await responseBeforeDeadline(for: request)
        if transportResponse.statusCode == 403 {
            throw CoachRelayError.refused
        }
        guard let statusCode = transportResponse.statusCode,
              (200..<300).contains(statusCode) else {
            throw CoachRelayError.badResponse
        }

        return try Self.decode(
            transportResponse.data,
            expectedRequestID: envelope.requestID,
            expectedCorrectionCode: facts.correctionCode
        )
    }

    private func responseBeforeDeadline(
        for request: URLRequest
    ) async throws -> CoachRelayTransportResponse {
        let transport = transport
        let deadlineClock = deadlineClock
        let deadline = deadline

        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: DeadlineRaceResult.self) { group in
            group.addTask {
                .response(try await transport.response(for: request))
            }
            group.addTask {
                try await deadlineClock.sleep(for: deadline)
                return .timedOut
            }
            defer { group.cancelAll() }

            guard let first = try await group.next() else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            switch first {
            case .response(let response):
                return response
            case .timedOut:
                throw CoachRelayError.timedOut
            }
        }
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
            "spokenCue",
            "whyItMatters",
            "encouragement"
        ]
        guard Set(object.keys) == allowedKeys else {
            throw CoachRelayError.unknownResponseFields
        }
        guard
            let schemaVersion = object["schemaVersion"] as? Int,
            let responseRequestID = object["requestID"] as? String,
            let correctionRawValue = object["correctionCode"] as? String,
            let spokenCue = object["spokenCue"] as? String,
            let whyItMatters = object["whyItMatters"] as? String,
            let encouragement = object["encouragement"] as? String
        else {
            throw CoachRelayError.malformedResponse
        }

        guard schemaVersion == Self.schemaVersion else {
            throw CoachRelayError.unsupportedSchemaVersion
        }
        guard Self.isValidRequestID(responseRequestID) else {
            throw CoachRelayError.invalidRequestID
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

        try validate(spokenCue, field: "spokenCue", maximumWords: 18)
        try validate(whyItMatters, field: "whyItMatters", maximumWords: 24)
        try validate(encouragement, field: "encouragement", maximumWords: 18)

        return CoachRelayResponse(
            schemaVersion: schemaVersion,
            requestID: responseRequestID,
            correctionCode: correctionCode,
            spokenCue: spokenCue,
            whyItMatters: whyItMatters,
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

    private enum DeadlineRaceResult: Sendable {
        case response(CoachRelayTransportResponse)
        case timedOut
    }
}
