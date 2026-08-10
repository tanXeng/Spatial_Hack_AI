import XCTest
@testable import BoxingCoach

final class CoachClipRouterTests: XCTestCase {
    func testKeywordRoutingMatchesCommonPhrases() {
        XCTAssertEqual(
            CoachClipRouter.keywordMatch(for: "What should I fix on that punch?"),
            .qaWhatFix
        )
        XCTAssertEqual(
            CoachClipRouter.keywordMatch(for: "Can you show me the demo again?"),
            .qaRepeatDemo
        )
        XCTAssertEqual(
            CoachClipRouter.keywordMatch(for: "Why do I need to keep my guard up?"),
            .qaWhyGuard
        )
        XCTAssertEqual(
            CoachClipRouter.keywordMatch(for: "Help me understand the commands"),
            .helpCommands
        )
        XCTAssertNil(CoachClipRouter.keywordMatch(for: "asdfghjkl"))
    }
}
