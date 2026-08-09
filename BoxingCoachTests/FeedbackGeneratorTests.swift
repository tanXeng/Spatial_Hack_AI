import Foundation
import Testing
@testable import BoxingCoach

@Suite("Nonblocking coaching feedback")
@MainActor
struct FeedbackGeneratorTests {
    @Test("Local result renders before suspended AI phrasing completes")
    func localResultRendersBeforeSuspendedPhrasing() async throws {
        let gate = PhrasingGate()
        let session = makeSession(gate: gate)
        let score = makeScore(overall: 64, extension: 52)

        let phrasingTask = session.finishAggregated(score)

        #expect(session.phase == .results)
        #expect(session.score?.overall == 64)
        let local = try #require(session.feedback)
        #expect(local.source == .offlineCoach)
        #expect(local.correctionCode == .extensionReach)
        #expect(local.drill == .fullExtension)

        await gate.resolve(
            score: 64,
            with: CoachPhrasing(
                explanation: "AI explanation",
                encouragement: "AI encouragement"
            )
        )
        await phrasingTask.value

        let enhanced = try #require(session.feedback)
        #expect(enhanced.source == .aiPhrasing)
        #expect(enhanced.headline == local.headline)
        #expect(enhanced.primaryFix == local.primaryFix)
        #expect(enhanced.encouragement == local.encouragement)
        #expect(enhanced.supplementalExplanation == "AI explanation")
        #expect(enhanced.supplementalEncouragement == "AI encouragement")
        #expect(session.score?.overall == 64)
        #expect(enhanced.correctionCode == local.correctionCode)
        #expect(enhanced.drill == local.drill)
    }

    @Test("Phrasing from a replaced attempt cannot mutate the active result")
    func changedAttemptRejectsStalePhrasing() async throws {
        let gate = PhrasingGate()
        let session = makeSession(gate: gate)

        let staleTask = session.finishAggregated(makeScore(overall: 64, extension: 52))
        let activeTask = session.finishAggregated(
            makeScore(overall: 91, extension: 93, path: 93)
        )

        #expect(staleTask.isCancelled)
        let activeLocal = try #require(session.feedback)
        #expect(activeLocal.source == .offlineCoach)
        #expect(activeLocal.correctionCode == .repeatShape)
        #expect(activeLocal.drill == .repeatShape)

        await gate.resolve(
            score: 64,
            with: CoachPhrasing(
                explanation: "Stale explanation",
                encouragement: "Stale encouragement"
            )
        )
        await staleTask.value

        #expect(session.score?.overall == 91)
        #expect(session.feedback == activeLocal)

        await gate.resolve(score: 91, with: nil)
        await activeTask.value
    }

    @Test("Reset cancels phrasing and clears the completed result")
    func resetCancelsPhrasing() async {
        let gate = PhrasingGate()
        let session = makeSession(gate: gate)
        let task = session.finishAggregated(makeScore(overall: 64, extension: 52))

        session.reset()

        #expect(task.isCancelled)
        #expect(session.phase == .idle)
        #expect(session.score == nil)
        #expect(session.feedback == nil)

        await gate.resolve(score: 64, with: .late)
        await task.value
        #expect(session.feedback == nil)
    }

    @Test("Route stop cancels phrasing even after result phase appears")
    func stopCancelsResultPhrasing() async throws {
        let gate = PhrasingGate()
        let session = makeSession(gate: gate)
        let task = session.finishAggregated(makeScore(overall: 64, extension: 52))
        let local = try #require(session.feedback)

        session.stop()

        #expect(task.isCancelled)
        await gate.resolve(score: 64, with: .late)
        await task.value
        #expect(session.feedback == local)
    }

    @Test("Scene teardown cancels phrasing and rejects a late completion")
    func detachCancelsResultPhrasing() async throws {
        let gate = PhrasingGate()
        let session = makeSession(gate: gate)
        let task = session.finishAggregated(makeScore(overall: 64, extension: 52))
        let local = try #require(session.feedback)

        session.detach()

        #expect(task.isCancelled)
        await gate.resolve(score: 64, with: .late)
        await task.value
        #expect(session.feedback == local)
    }

    @Test("Validated relay prose supplements trusted local guidance")
    func validatedRelayProseSupplementsLocalGuidance() async {
        let transport = ScriptedRelayTransport(scenario: .success)
        let clock = ManualRelayClock()
        let generator = makeRelayGenerator(transport: transport, clock: clock)

        let score = makeScore(overall: 64, extension: 52)
        let local = generator.localFeedback(for: score, technique: .jab)
        let feedback = await generator.feedback(for: score, technique: .jab)

        #expect(feedback.source == .aiPhrasing)
        #expect(feedback.headline == local.headline)
        #expect(feedback.primaryFix == local.primaryFix)
        #expect(feedback.encouragement == local.encouragement)
        #expect(
            feedback.supplementalExplanation
                == "Full extension improves reach while a quick return protects your chin."
        )
        #expect(feedback.supplementalEncouragement == "Your punch stayed on a clean line.")
        #expect(feedback.correctionCode == .extensionReach)
        #expect(feedback.drill == .fullExtension)
    }

    @Test("Matching-code contradictory prose remains supplemental to trusted guidance")
    func contradictoryRelayProseCannotReplaceTrustedGuidance() async {
        let generator = makeRelayGenerator(
            transport: ScriptedRelayTransport(scenario: .contradictoryProse),
            clock: ManualRelayClock()
        )
        let score = makeScore(overall: 64, extension: 52)
        let local = generator.localFeedback(for: score, technique: .jab)

        let feedback = await generator.feedback(for: score, technique: .jab)

        #expect(feedback.source == .aiPhrasing)
        #expect(feedback.headline == local.headline)
        #expect(feedback.primaryFix == local.primaryFix)
        #expect(feedback.encouragement == local.encouragement)
        #expect(feedback.correctionCode == local.correctionCode)
        #expect(feedback.drill == local.drill)
        #expect(
            feedback.supplementalExplanation
                == "Short reach is safer, so the low extension score is wrong."
        )
        #expect(
            feedback.supplementalEncouragement
                == "Skip full extension and practice a shorter punch."
        )
    }

    @Test("Missing endpoint remains offline without starting transport or deadline")
    func missingEndpointDoesNotStartRelayWork() async {
        let transport = ScriptedRelayTransport(scenario: .success)
        let clock = ManualRelayClock()
        let requestID = "req_0123456789abcdef0123456789abcdef"
        let client = CoachRelayClient(
            endpoint: nil,
            transport: transport,
            deadlineClock: clock,
            requestDate: { Date(timeIntervalSince1970: 1_786_291_200) },
            requestID: { requestID }
        )
        let generator = RelayFeedbackGenerator(
            client: client,
            context: CoachRelayFeedbackContext(locale: "en-SG")
        )

        let feedback = await generator.feedback(
            for: makeScore(overall: 64, extension: 52),
            technique: .jab
        )

        #expect(feedback.source == .offlineCoach)
        #expect(await transport.requestCount() == 0)
        #expect(await clock.scheduledDelays().isEmpty)
    }

    @Test("Relay timeout is exactly 1.5 seconds and preserves local feedback")
    func relayDeadlinePreservesLocalFeedback() async {
        let transport = SuspendedRelayTransport()
        let clock = ManualRelayClock()
        let generator = makeRelayGenerator(transport: transport, clock: clock)
        let feedbackTask = Task {
            await generator.feedback(
                for: makeScore(overall: 64, extension: 52),
                technique: .jab
            )
        }

        let scheduledDelay = await clock.nextScheduledDelay()
        #expect(scheduledDelay == .milliseconds(1_500))

        await clock.advance(by: .milliseconds(1_499))
        #expect(await transport.wasCancelled() == false)

        await clock.advance(by: .milliseconds(1))
        let feedback = await feedbackTask.value

        #expect(feedback.source == .offlineCoach)
        #expect(feedback.correctionCode == .extensionReach)
        #expect(feedback.drill == .fullExtension)
        #expect(await transport.wasCancelled())
    }

    @Test(
        "HTTP authentication, rate limit, and server failures preserve local feedback",
        arguments: [401, 429, 500]
    )
    func httpFailuresPreserveLocalFeedback(statusCode: Int) async {
        let transport = ScriptedRelayTransport(scenario: .httpStatus(statusCode))
        let feedback = await makeRelayGenerator(
            transport: transport,
            clock: ManualRelayClock()
        ).feedback(for: makeScore(overall: 64, extension: 52), technique: .jab)

        #expect(feedback.source == .offlineCoach)
        #expect(feedback.correctionCode == .extensionReach)
        #expect(feedback.drill == .fullExtension)
    }

    @Test(
        "Refusal and invalid relay responses preserve local feedback",
        arguments: [
            ScriptedRelayScenario.refusal,
            .malformedJSON,
            .extraField,
            .wrongRequestID,
            .wrongCorrectionCode
        ]
    )
    func invalidRelayResponsesPreserveLocalFeedback(
        scenario: ScriptedRelayScenario
    ) async {
        let transport = ScriptedRelayTransport(scenario: scenario)
        let feedback = await makeRelayGenerator(
            transport: transport,
            clock: ManualRelayClock()
        ).feedback(for: makeScore(overall: 64, extension: 52), technique: .jab)

        #expect(feedback.source == .offlineCoach)
        #expect(feedback.correctionCode == .extensionReach)
        #expect(feedback.drill == .fullExtension)
    }

    @Test("Caller cancellation cancels suspended transport and deadline work")
    func callerCancellationCancelsRelayWork() async {
        let transport = SuspendedRelayTransport()
        let clock = ManualRelayClock()
        let client = makeClient(transport: transport, clock: clock)
        let task = Task {
            try await client.response(for: makeRequestFacts())
        }

        await transport.waitUntilRequested()
        _ = await clock.nextScheduledDelay()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected relay cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }

        #expect(await transport.wasCancelled())
        #expect(await clock.wasCancelled())
    }

    private func makeSession(gate: PhrasingGate) -> AuraPunchSession {
        AuraPunchSession(
            hands: HandTrackingService(),
            feedbackGenerator: GatedFeedbackGenerator(gate: gate),
            coachAudio: SilentCoachAudioPlayer()
        )
    }

    private func makeRelayGenerator(
        transport: any CoachRelayTransport,
        clock: any CoachRelayClock
    ) -> RelayFeedbackGenerator {
        RelayFeedbackGenerator(
            client: makeClient(transport: transport, clock: clock),
            context: CoachRelayFeedbackContext(locale: "en-SG")
        )
    }

    private func makeClient(
        transport: any CoachRelayTransport,
        clock: any CoachRelayClock
    ) -> CoachRelayClient {
        let requestID = "req_0123456789abcdef0123456789abcdef"
        return CoachRelayClient(
            endpoint: URL(string: "https://coach-relay.example/phrase")!,
            transport: transport,
            deadlineClock: clock,
            requestDate: { Date(timeIntervalSince1970: 1_786_291_200) },
            requestID: { requestID }
        )
    }
}

nonisolated enum ScriptedRelayScenario: Sendable, Equatable, CustomTestStringConvertible {
    case success
    case contradictoryProse
    case refusal
    case httpStatus(Int)
    case malformedJSON
    case extraField
    case wrongRequestID
    case wrongCorrectionCode

    var testDescription: String {
        switch self {
        case .success: "success"
        case .contradictoryProse: "matching_code_contradictory_prose"
        case .refusal: "refusal"
        case .httpStatus(let value): "http_\(value)"
        case .malformedJSON: "malformed_json"
        case .extraField: "extra_field"
        case .wrongRequestID: "wrong_request_id"
        case .wrongCorrectionCode: "wrong_correction_code"
        }
    }
}

private actor ScriptedRelayTransport: CoachRelayTransport {
    private let scenario: ScriptedRelayScenario
    private var requests = 0

    init(scenario: ScriptedRelayScenario) {
        self.scenario = scenario
    }

    func response(for request: URLRequest) async throws -> CoachRelayTransportResponse {
        requests += 1
        let statusCode: Int
        switch scenario {
        case .refusal:
            statusCode = 403
        case .httpStatus(let value):
            statusCode = value
        default:
            statusCode = 200
        }

        guard scenario != .malformedJSON else {
            return CoachRelayTransportResponse(data: Data("{".utf8), statusCode: statusCode)
        }

        guard let requestBody = request.httpBody,
              let root = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              let requestID = root["requestID"] as? String,
              let facts = root["facts"] as? [String: Any],
              let correctionCode = facts["correctionCode"] as? String
        else {
            throw RelayTestFixtureError.malformedRequest
        }

        var response: [String: Any] = [
            "schemaVersion": 1,
            "requestID": requestID,
            "correctionCode": correctionCode,
            "spokenCue": "Drive through the target and return to guard.",
            "whyItMatters": "Full extension improves reach while a quick return protects your chin.",
            "encouragement": "Your punch stayed on a clean line."
        ]

        switch scenario {
        case .contradictoryProse:
            response["spokenCue"] = "Keep your arm bent and ignore the extension drill."
            response["whyItMatters"] = "Short reach is safer, so the low extension score is wrong."
            response["encouragement"] = "Skip full extension and practice a shorter punch."
        case .extraField:
            response["provider"] = "must be rejected"
        case .wrongRequestID:
            response["requestID"] = "req_fedcba9876543210fedcba9876543210"
        case .wrongCorrectionCode:
            response["correctionCode"] = "path"
        default:
            break
        }

        return CoachRelayTransportResponse(
            data: try JSONSerialization.data(withJSONObject: response),
            statusCode: statusCode
        )
    }

    func requestCount() -> Int { requests }
}

private actor SuspendedRelayTransport: CoachRelayTransport {
    private var continuation: AsyncStream<CoachRelayTransportResponse>.Continuation?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var requested = false
    private var cancelled = false

    func response(for request: URLRequest) async throws -> CoachRelayTransportResponse {
        requested = true
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        try Task.checkCancellation()
        let pair = AsyncStream<CoachRelayTransportResponse>.makeStream()
        continuation = pair.continuation
        for await response in pair.stream {
            continuation = nil
            return response
        }
        continuation = nil
        cancelled = Task.isCancelled
        try Task.checkCancellation()
        throw RelayTestFixtureError.endedWithoutResponse
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func wasCancelled() -> Bool { cancelled }

}

private actor ManualRelayClock: CoachRelayClock {
    private struct Waiter {
        let deadline: Duration
        let continuation: AsyncStream<Void>.Continuation
    }

    private var now: Duration = .zero
    private var waiter: Waiter?
    private var scheduleWaiters: [CheckedContinuation<Duration, Never>] = []
    private var delays: [Duration] = []
    private var cancelled = false

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        delays.append(duration)
        let observers = scheduleWaiters
        scheduleWaiters.removeAll()
        for observer in observers { observer.resume(returning: duration) }

        let pair = AsyncStream<Void>.makeStream()
        waiter = Waiter(deadline: now + duration, continuation: pair.continuation)
        for await _ in pair.stream {
            break
        }
        waiter = nil
        cancelled = Task.isCancelled
        try Task.checkCancellation()
    }

    func advance(by duration: Duration) {
        now += duration
        guard let waiter, waiter.deadline <= now else { return }
        self.waiter = nil
        waiter.continuation.yield()
        waiter.continuation.finish()
    }

    func nextScheduledDelay() async -> Duration {
        if let delay = delays.first { return delay }
        return await withCheckedContinuation { continuation in
            scheduleWaiters.append(continuation)
        }
    }

    func scheduledDelays() -> [Duration] { delays }
    func wasCancelled() -> Bool { cancelled }

}

private nonisolated enum RelayTestFixtureError: Error {
    case malformedRequest
    case endedWithoutResponse
}

@MainActor
private final class SilentCoachAudioPlayer: CoachAudioPlaying {
    func prepare() {}
    func play(id: CoachClipID) {}
    func stop() {}
}

private nonisolated struct GatedFeedbackGenerator: FeedbackGenerating {
    let gate: PhrasingGate
    private let local = MockFeedbackGenerator()

    func localFeedback(
        for score: TechniqueScore,
        technique: Technique
    ) -> CoachingFeedback {
        local.localFeedback(for: score, technique: technique)
    }

    func phrasing(
        for score: TechniqueScore,
        technique: Technique
    ) async -> CoachPhrasing? {
        await gate.phrasing(for: Int(score.overall.rounded()))
    }
}

private actor PhrasingGate {
    private enum Resolution {
        case phrasing(CoachPhrasing)
        case unavailable

        var value: CoachPhrasing? {
            switch self {
            case .phrasing(let phrasing): phrasing
            case .unavailable: nil
            }
        }
    }

    private var pending: [Int: CheckedContinuation<CoachPhrasing?, Never>] = [:]
    private var earlyResolutions: [Int: Resolution] = [:]

    func phrasing(for score: Int) async -> CoachPhrasing? {
        if let resolution = earlyResolutions.removeValue(forKey: score) {
            return resolution.value
        }
        return await withCheckedContinuation { continuation in
            pending[score] = continuation
        }
    }

    func resolve(score: Int, with phrasing: CoachPhrasing?) {
        let resolution = phrasing.map(Resolution.phrasing) ?? .unavailable
        if let continuation = pending.removeValue(forKey: score) {
            continuation.resume(returning: resolution.value)
        } else {
            earlyResolutions[score] = resolution
        }
    }
}

private extension CoachPhrasing {
    static let late = CoachPhrasing(
        explanation: "Late explanation",
        encouragement: "Late encouragement"
    )
}

private nonisolated func makeScore(
    overall: Float,
    extension extensionScore: Float,
    path pathScore: Float = 76
) -> TechniqueScore {
    TechniqueScore(
        techniqueID: "jab",
        overall: overall,
        metrics: [
            SubMetric(
                kind: .extensionReach,
                score: extensionScore,
                measured: 0.18,
                detail: "fixture"
            ),
            SubMetric(kind: .path, score: pathScore, measured: 0.06, detail: "fixture")
        ],
        trackedFraction: 0.82,
        duration: 0.7,
        requiredHandName: "left hand"
    )
}

private nonisolated func makeRequestFacts() -> CoachRelayRequestFacts {
    CoachRelayRequestFacts(
        locale: "en-SG",
        learnerLevel: .beginner,
        technique: "jab",
        scoreBand: .developing,
        trackedFraction: 0.82,
        metrics: [
            CoachRelayMetric(name: "extension", value: 52),
            CoachRelayMetric(name: "path", value: 76)
        ],
        correctionCode: .extensionReach,
        localCue: "Reach all the way through the target.",
        personalBest: false,
        validAttemptCount: 1,
        sameFocusCount: 1
    )
}
