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

        let client = OpenAICoachChatClient(apiKey: "sk-test", session: URLSession(configuration: configuration))
        let answer = try await client.answer(transcript: "what should I fix?", context: .idle)
        XCTAssertEqual(answer, "Keep your elbow in and snap back to guard.")
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
