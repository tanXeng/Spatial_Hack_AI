import XCTest
@testable import BoxingCoach

final class CoachMilestoneScriptsTests: XCTestCase {
    func testMilestoneScriptsExistForDrillEvents() {
        XCTAssertNotNil(CoachMilestoneScripts.text(for: .welcome))
        XCTAssertNotNil(CoachMilestoneScripts.text(for: .guardUp))
        XCTAssertNotNil(CoachMilestoneScripts.text(for: .countdown))
        XCTAssertNotNil(CoachMilestoneScripts.text(for: .hitTarget))
        XCTAssertNotNil(CoachMilestoneScripts.text(for: .didntCatch))
    }

    func testPTTClipIDsHaveNoFixedScript() {
        XCTAssertNil(CoachMilestoneScripts.text(for: .helpCommands))
        XCTAssertNil(CoachMilestoneScripts.text(for: .qaWhatFix))
    }
}

final class CoachTTSCacheTests: XCTestCase {
    func testCacheRoundTrip() {
        let cache = CoachTTSCache()
        let sample = Data("fake-audio".utf8)
        let text = "Welcome to Aura Punch. \(UUID().uuidString)"
        let voice = OpenAITTSClient.defaultVoice

        cache.store(sample, for: text, voice: voice)
        XCTAssertEqual(cache.cachedAudio(for: text, voice: voice), sample)
        XCTAssertFalse(cache.cacheKey(for: text, voice: voice).isEmpty)
    }
}

final class OpenAICoachChatClientTests: XCTestCase {
    func testParsesChatAnswer() async throws {
        let json = """
        {
          "choices": [
            { "message": { "content": "Keep your elbow in and snap back to guard." } }
          ]
        }
        """.data(using: .utf8)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.responseData = json
        MockURLProtocol.statusCode = 200
        MockURLProtocol.capturedBody = nil

        let client = OpenAICoachChatClient(apiKey: "sk-test", session: URLSession(configuration: configuration))
        let answer = try await client.answer(transcript: "what should I fix?", context: .idle)
        XCTAssertEqual(answer, "Keep your elbow in and snap back to guard.")

        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertEqual(messages.last?["content"] as? String, "what should I fix?")
    }

    func testPassesMathQuestionDirectlyToModel() async throws {
        let json = """
        {
          "choices": [
            { "message": { "content": "One plus one equals two." } }
          ]
        }
        """.data(using: .utf8)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.responseData = json
        MockURLProtocol.statusCode = 200
        MockURLProtocol.capturedBody = nil

        let client = OpenAICoachChatClient(apiKey: "sk-test", session: URLSession(configuration: configuration))
        let answer = try await client.answer(transcript: "1 + 1", context: .idle)
        XCTAssertEqual(answer, "One plus one equals two.")

        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["content"] as? String, "1 + 1")
    }

    func testSystemPromptIncludesAppGuide() async throws {
        let json = """
        {
          "choices": [
            { "message": { "content": "Go to Aura Punch and select Jab." } }
          ]
        }
        """.data(using: .utf8)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.responseData = json
        MockURLProtocol.statusCode = 200
        MockURLProtocol.capturedBody = nil

        let context = CoachVoiceContext(
            feature: .auraPunch,
            auraPhase: .idle,
            drillPhase: nil,
            techniqueName: nil,
            stance: .orthodox,
            reactiveMode: nil,
            combinationName: nil
        )
        _ = try await OpenAICoachChatClient(apiKey: "sk-test", session: URLSession(configuration: configuration))
            .answer(transcript: "how do I practice my jab?", context: context)

        let body = try XCTUnwrap(MockURLProtocol.capturedBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(system.contains("Aura Punch"))
        XCTAssertEqual(payload["model"] as? String, OpenAICoachChatClient.defaultModel)
    }
}

final class CoachAppGuideTests: XCTestCase {
    func testJabGuidanceIncludesTechniqueCues() {
        let guidance = CoachAppGuide.techniqueGuidance(named: "Jab")
        XCTAssertNotNil(guidance)
        XCTAssertTrue(guidance?.contains("straight") == true)
    }

    func testSessionContextIncludesReactiveMode() {
        let context = CoachVoiceContext(
            feature: .reactiveStrike,
            auraPhase: nil,
            drillPhase: .running,
            techniqueName: nil,
            stance: .southpaw,
            reactiveMode: .combination,
            combinationName: "Jab-Cross"
        )
        let summary = CoachAppGuide.sessionContext(for: context)
        XCTAssertTrue(summary.contains("Reactive Strike"))
        XCTAssertTrue(summary.contains("Combination Mode"))
        XCTAssertTrue(summary.contains("Jab-Cross"))
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedBody = request.httpBody
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
