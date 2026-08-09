import Testing
@testable import BoxingCoach

@Suite("Typed offline coach clip routing")
struct CoachClipRouterTests {
    @Test("Executed intents route to distinct local clips", arguments: CoachClipRouteCase.supported)
    func executedIntentRoutesLocally(testCase: CoachClipRouteCase) {
        let clip = CoachClipRouter().responseClip(after: testCase.intent)

        #expect(clip == testCase.clip)
    }

    @Test("Intents without an authored response stay distinct", arguments: CoachClipRouteCase.unsupported)
    func intentWithoutAuthoredClipDoesNotBorrowAnotherMeaning(testCase: CoachClipRouteCase) {
        let clip = CoachClipRouter().responseClip(after: testCase.intent)

        #expect(clip == nil)
    }

    @Test("Legacy transcript entry accepts only exact informational grammar")
    func exactLegacyInformationalPhraseRoutes() async {
        let result = await CoachClipRouter().resolve(
            transcript: "what should i fix",
            context: CoachVoiceContext(
                feature: .auraPunch,
                auraPhase: .results,
                drillPhase: nil,
                techniqueName: "Jab"
            )
        )

        #expect(result == .qaWhatFix)
    }

    @Test("Substring and polite wrappers never reach a response clip", arguments: [
        "What should I fix on that punch?",
        "Can you show me the demo again?",
        "Help me understand the commands",
        "unstoppable"
    ])
    func legacyTranscriptEntryDoesNotUseKeywordSubstrings(transcript: String) async {
        let result = await CoachClipRouter().resolve(transcript: transcript, context: .idle)

        #expect(result == .didntCatch)
    }

    @Test("Action acknowledgment is available only through the post-execution typed route")
    func rawActionDoesNotClaimItExecuted() async {
        let router = CoachClipRouter()
        let rawResult = await router.resolve(
            transcript: "stop",
            context: CoachVoiceContext(
                feature: .auraPunch,
                auraPhase: .guiding,
                drillPhase: nil,
                techniqueName: "Jab"
            )
        )

        #expect(rawResult == .didntCatch)
        #expect(router.responseClip(after: .pause) == .pauseAck)
    }

    @Test("Unsupported speech stays deterministic and local")
    func unsupportedSpeechDoesNotNeedNetwork() async {
        let result = await CoachClipRouter().resolve(
            transcript: "asdfghjkl",
            context: .idle
        )

        #expect(result == .didntCatch)
    }
}

nonisolated struct CoachClipRouteCase: Sendable, CustomTestStringConvertible {
    let intent: VoiceIntent
    let clip: CoachClipID?

    var testDescription: String { "\(intent)" }

    static let supported: [Self] = [
        .init(intent: .correction, clip: .qaWhatFix),
        .init(intent: .guardExplanation, clip: .qaWhyGuard),
        .init(intent: .repeatDemo, clip: .qaRepeatDemo),
        .init(intent: .slower, clip: .qaSlower),
        .init(intent: .targetHelp, clip: .qaHitTarget),
        .init(intent: .progress, clip: .qaThreePunches),
        .init(intent: .pause, clip: .pauseAck),
        .init(intent: .resume, clip: .resumeAck),
        .init(intent: .help, clip: .helpCommands)
    ]

    static let unsupported: [Self] = [
        .init(intent: .requestEnd, clip: nil),
        .init(intent: .confirmEnd, clip: nil),
        .init(intent: .cancelEnd, clip: nil),
        .init(intent: .normalPace, clip: nil),
        .init(intent: .faster, clip: nil),
        .init(intent: .next, clip: nil),
        .init(intent: .score, clip: nil),
        .init(intent: .why, clip: nil),
        .init(intent: .leaderboard, clip: nil),
        .init(intent: .participantHandoff, clip: nil)
    ]
}
