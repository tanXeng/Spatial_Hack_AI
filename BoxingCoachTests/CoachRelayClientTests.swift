import Foundation
import Testing
@testable import BoxingCoach

@Suite("Coach relay privacy and validation")
struct CoachRelayClientTests {
    @Test("Production feedback is deterministic and offline without a relay URL")
    func productionFeedbackDefaultsOffline() async {
        let generator = FeedbackGenerator.production(
            endpoint: nil,
            session: makeSession(),
            clock: { Date(timeIntervalSince1970: 1_786_291_200) },
            requestID: { "req_0123456789abcdef0123456789abcdef" }
        )
        let score = TechniqueScore(
            techniqueID: "jab",
            overall: 64,
            metrics: [
                SubMetric(kind: .extensionReach, score: 52, measured: 0.18, detail: "52%"),
                SubMetric(kind: .path, score: 76, measured: 0.06, detail: "6 cm"),
                SubMetric(kind: .elbow, score: nil, measured: 0, detail: "not tracked")
            ],
            trackedFraction: 0.82,
            duration: 0.7,
            requiredHandName: "left hand"
        )

        let first = await generator.feedback(for: score, technique: .jab)
        let second = await generator.feedback(for: score, technique: .jab)

        #expect(first.isOffline)
        #expect(first == second)
        #expect(first.primaryFix.contains("stopped short"))
    }

    @Test("Production feedback sends only available deterministic score facts")
    func productionFeedbackUsesAllowListedScoreFacts() async {
        let generator = FeedbackGenerator.production(
            endpoint: URL(string: "https://coach-relay.example/generated-facts")!,
            session: makeSession(),
            clock: { Date(timeIntervalSince1970: 1_786_291_200) },
            requestID: { "req_0123456789abcdef0123456789abcdef" },
            context: CoachRelayFeedbackContext(
                locale: "en-SG",
                personalBest: true,
                validAttemptCount: 3,
                sameFocusCount: 2
            )
        )
        let score = TechniqueScore(
            techniqueID: "jab",
            overall: 64,
            metrics: [
                SubMetric(kind: .extensionReach, score: 52, measured: 0.18, detail: "private detail"),
                SubMetric(kind: .path, score: 76, measured: 0.06, detail: "private detail"),
                SubMetric(kind: .elbow, score: nil, measured: 0, detail: "private detail")
            ],
            trackedFraction: 0.82,
            duration: 0.7,
            requiredHandName: "left hand"
        )

        let feedback = await generator.feedback(for: score, technique: .jab)

        #expect(feedback.isOffline == false)
        #expect(feedback.headline.hasPrefix("Drive your jab"))
    }

    @Test("Outbound facts use the literal privacy allow-list")
    func outboundFactsUsePrivacyAllowList() async throws {
        let response = try await makeClient(path: "/valid").response(for: requestFacts)

        #expect(response.requestID == "req_0123456789abcdef0123456789abcdef")
        #expect(response.correctionCode == .extensionReach)
        #expect(response.whyItMatters.hasPrefix("Full extension"))
    }

    @Test("Production request IDs are random opaque non-UUID tokens")
    func productionRequestIDsAreOpaque() {
        let first = CoachRelayClient.makeRequestID()
        let second = CoachRelayClient.makeRequestID()

        #expect(CoachRelayClient.isValidRequestID(first))
        #expect(CoachRelayClient.isValidRequestID(second))
        #expect(UUID(uuidString: first) == nil)
        #expect(UUID(uuidString: second) == nil)
        #expect(first != second)
    }

    @Test("Default request IDs are fresh per request and stay outside facts")
    func defaultRequestIDsAreRequestOnly() async throws {
        let client = CoachRelayClient(
            endpoint: URL(string: "https://coach-relay.example/generated-request-id")!,
            session: makeSession(),
            clock: { Date(timeIntervalSince1970: 1_786_291_200) }
        )

        let first = try await client.response(for: requestFacts)
        let second = try await client.response(for: requestFacts)

        #expect(CoachRelayClient.isValidRequestID(first.requestID))
        #expect(CoachRelayClient.isValidRequestID(second.requestID))
        #expect(UUID(uuidString: first.requestID) == nil)
        #expect(first.requestID != second.requestID)
    }

    @Test("Invalid injected request IDs are rejected before transport")
    func invalidRequestIDIsRejected() async {
        let client = CoachRelayClient(
            endpoint: URL(string: "https://coach-relay.example/invalid-request-id")!,
            session: makeSession(),
            clock: { Date(timeIntervalSince1970: 1_786_291_200) },
            requestID: { UUID().uuidString }
        )

        do {
            _ = try await client.response(for: requestFacts)
            Issue.record("Expected request ID validation to fail")
        } catch let error as CoachRelayError {
            #expect(error == .invalidRequestID)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(
        "Responses reject unknown fields, mismatches, and word-limit violations",
        arguments: [
            ValidationCase(path: "/unknown-field", expected: .unknownResponseFields),
            ValidationCase(path: "/relay-drill", expected: .unknownResponseFields),
            ValidationCase(path: "/legacy-why", expected: .unknownResponseFields),
            ValidationCase(path: "/unsupported-version", expected: .unsupportedSchemaVersion),
            ValidationCase(path: "/mismatched-request", expected: .mismatchedRequestID),
            ValidationCase(path: "/mismatched-correction", expected: .mismatchedCorrectionCode),
            ValidationCase(
                path: "/too-many-spoken-words",
                expected: .wordLimitExceeded(field: "spokenCue", maximum: 18)
            ),
            ValidationCase(
                path: "/too-many-why-words",
                expected: .wordLimitExceeded(field: "whyItMatters", maximum: 24)
            ),
            ValidationCase(
                path: "/too-many-encouragement-words",
                expected: .wordLimitExceeded(field: "encouragement", maximum: 18)
            )
        ]
    )
    func rejectsInvalidResponses(testCase: ValidationCase) async {
        do {
            _ = try await makeClient(path: testCase.path).response(for: requestFacts)
            Issue.record("Expected relay response validation to fail")
        } catch let error as CoachRelayError {
            #expect(error == testCase.expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A missing relay endpoint stays offline")
    func missingEndpointStaysOffline() async {
        let client = CoachRelayClient(
            endpoint: nil,
            session: makeSession(),
            clock: { Date(timeIntervalSince1970: 1_786_291_200) },
            requestID: { "req_0123456789abcdef0123456789abcdef" }
        )

        do {
            _ = try await client.response(for: requestFacts)
            Issue.record("Expected an offline result")
        } catch let error as CoachRelayError {
            #expect(error == .offline)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private var requestFacts: CoachRelayRequestFacts {
        CoachRelayRequestFacts(
            locale: "en-SG",
            learnerLevel: .beginner,
            technique: "jab",
            scoreBand: .developing,
            trackedFraction: 0.875,
            metrics: [
                CoachRelayMetric(name: "extension", value: 62),
                CoachRelayMetric(name: "path", value: 71)
            ],
            correctionCode: .extensionReach,
            localCue: "Reach all the way through the target.",
            personalBest: false,
            validAttemptCount: 3,
            sameFocusCount: 2
        )
    }

    private func makeClient(path: String) -> CoachRelayClient {
        CoachRelayClient(
            endpoint: URL(string: "https://coach-relay.example\(path)")!,
            session: makeSession(),
            clock: { Date(timeIntervalSince1970: 1_786_291_200) },
            requestID: { "req_0123456789abcdef0123456789abcdef" }
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayContractURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

struct ValidationCase: Sendable, CustomTestStringConvertible {
    let path: String
    let expected: CoachRelayError

    var testDescription: String { path }
}

private final class RelayContractURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if request.url?.path == "/invalid-request-id" {
            finish(statusCode: 418, body: [:])
            return
        }

        do {
            let body = try requestBody()
            guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let facts = root["facts"] as? [String: Any]
            else {
                throw ContractFixtureError.malformedRequest
            }

            let envelopeKeys: Set<String> = ["schemaVersion", "requestID", "requestedAt", "facts"]
            let factKeys: Set<String> = [
                "locale",
                "learnerLevel",
                "technique",
                "scoreBand",
                "trackedFraction",
                "metrics",
                "correctionCode",
                "localCue",
                "personalBest",
                "validAttemptCount",
                "sameFocusCount"
            ]
            let metricKeys: Set<String> = ["name", "value"]
            guard let metrics = facts["metrics"] as? [[String: Any]] else {
                throw ContractFixtureError.malformedRequest
            }

            guard
                Set(root.keys) == envelopeKeys,
                Set(facts.keys) == factKeys,
                metrics.allSatisfy({ Set($0.keys) == metricKeys }),
                facts["requestID"] == nil,
                root["schemaVersion"] as? Int == 1,
                root["requestedAt"] is String
            else {
                return finish(statusCode: 422, body: [:])
            }

            if request.url?.path == "/generated-facts" {
                let metricNames = metrics.compactMap { $0["name"] as? String }
                let trackedFraction = facts["trackedFraction"] as? Double
                guard
                    facts["locale"] as? String == "en-SG",
                    facts["learnerLevel"] as? String == "beginner",
                    facts["technique"] as? String == "jab",
                    facts["scoreBand"] as? String == "developing",
                    trackedFraction.map({ abs($0 - 0.82) < 0.001 }) == true,
                    metricNames == ["extension", "path"],
                    facts["correctionCode"] as? String == "extension_reach",
                    (facts["localCue"] as? String)?.contains("stopped short") == true,
                    facts["personalBest"] as? Bool == true,
                    facts["validAttemptCount"] as? Int == 3,
                    facts["sameFocusCount"] as? Int == 2
                else {
                    return finish(statusCode: 422, body: [:])
                }
            }

            guard let requestID = root["requestID"] as? String,
                  let correctionCode = facts["correctionCode"] as? String
            else {
                throw ContractFixtureError.malformedRequest
            }
            var payload: [String: Any] = [
                "schemaVersion": 1,
                "requestID": requestID,
                "correctionCode": correctionCode,
                "spokenCue": "Drive your jab through the target, then bring your hand directly back to guard.",
                "whyItMatters": "Full extension gives your jab useful reach while the quick return protects your chin for the next exchange.",
                "encouragement": "Your punch stayed on a clean line; keep that shape as you add reach."
            ]

            switch request.url?.path {
            case "/unknown-field":
                payload["provider"] = "must-not-be-accepted"
            case "/relay-drill":
                payload["drill"] = "full_extension"
            case "/legacy-why":
                payload["why"] = payload.removeValue(forKey: "whyItMatters")
            case "/unsupported-version":
                payload["schemaVersion"] = 2
            case "/mismatched-request":
                payload["requestID"] = "req_fedcba9876543210fedcba9876543210"
            case "/mismatched-correction":
                payload["correctionCode"] = "path"
            case "/too-many-spoken-words":
                payload["spokenCue"] = Self.words(count: 19)
            case "/too-many-why-words":
                payload["whyItMatters"] = Self.words(count: 25)
            case "/too-many-encouragement-words":
                payload["encouragement"] = Self.words(count: 19)
            default:
                break
            }

            finish(statusCode: 200, body: payload)
        } catch {
            finish(statusCode: 500, body: [:])
        }
    }

    private func requestBody() throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else {
            throw ContractFixtureError.malformedRequest
        }

        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw ContractFixtureError.malformedRequest }
            if count == 0 { break }
            body.append(buffer, count: count)
        }
        guard !body.isEmpty else { throw ContractFixtureError.malformedRequest }
        return body
    }

    private static func words(count: Int) -> String {
        (1...count).map { "word\($0)" }.joined(separator: " ")
    }

    private func finish(statusCode: Int, body: [String: Any]) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private enum ContractFixtureError: Error {
    case malformedRequest
}
