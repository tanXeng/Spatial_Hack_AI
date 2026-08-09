import Testing
@testable import BoxingCoach

@Suite("Offline coach clip routing")
struct CoachClipRouterTests {
    @Test("Common phrases resolve to local clips")
    func commonPhrasesResolveLocally() {
        #expect(
            CoachClipRouter.keywordMatch(for: "What should I fix on that punch?") == .qaWhatFix
        )
        #expect(
            CoachClipRouter.keywordMatch(for: "Can you show me the demo again?") == .qaRepeatDemo
        )
        #expect(
            CoachClipRouter.keywordMatch(for: "Why do I need to keep my guard up?") == .qaWhyGuard
        )
        #expect(
            CoachClipRouter.keywordMatch(for: "Help me understand the commands") == .helpCommands
        )
        #expect(CoachClipRouter.keywordMatch(for: "asdfghjkl") == nil)
    }

    @Test("Router stays deterministic when no local phrase matches")
    func unsupportedSpeechDoesNotNeedNetwork() async {
        let result = await CoachClipRouter().resolve(
            transcript: "asdfghjkl",
            context: .idle
        )

        #expect(result == .didntCatch)
    }
}
