import Testing
@testable import BoxingCoach

@Suite("Typed offline coach clip routing")
struct CoachClipRouterTests {
    @Test("Informational intents route to distinct local clips", arguments: CoachClipRouteCase.supported)
    func informationalIntentRoutesLocally(testCase: CoachClipRouteCase) {
        let clip = CoachClipRouter().informationalResponseClip(for: testCase.intent)

        #expect(clip == testCase.clip)
    }

    @Test("Intents without an authored response stay distinct", arguments: CoachClipRouteCase.unsupported)
    func intentWithoutAuthoredClipDoesNotBorrowAnotherMeaning(testCase: CoachClipRouteCase) {
        let clip = CoachClipRouter().informationalResponseClip(for: testCase.intent)

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

    @Test(
        "Action clips remain unavailable until an executor-success token exists",
        arguments: [VoiceIntent.pause, .resume, .repeatDemo, .slower]
    )
    func actionIntentCannotClaimExecution(intent: VoiceIntent) {
        #expect(CoachClipRouter().informationalResponseClip(for: intent) == nil)
    }

    @Test("Raw action speech cannot claim execution")
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
        .init(intent: .targetHelp, clip: .qaHitTarget),
        .init(intent: .progress, clip: .qaThreePunches),
        .init(intent: .help, clip: .helpCommands)
    ]

    static let unsupported: [Self] = [
        .init(intent: .pause, clip: nil),
        .init(intent: .resume, clip: nil),
        .init(intent: .requestEnd, clip: nil),
        .init(intent: .confirmEnd, clip: nil),
        .init(intent: .cancelEnd, clip: nil),
        .init(intent: .repeatDemo, clip: nil),
        .init(intent: .slower, clip: nil),
        .init(intent: .normalPace, clip: nil),
        .init(intent: .faster, clip: nil),
        .init(intent: .next, clip: nil),
        .init(intent: .score, clip: nil),
        .init(intent: .why, clip: nil),
        .init(intent: .leaderboard, clip: nil),
        .init(intent: .requestParticipantHandoff, clip: nil)
    ]
}
