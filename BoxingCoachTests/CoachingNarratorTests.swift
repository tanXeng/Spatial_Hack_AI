import XCTest
@testable import BoxingCoach

final class CoachingNarratorTests: XCTestCase {
    private let facts = CoachingFactSet(
        correctionID: "return-to-guard",
        evidence: "required fist finished outside the calibrated guard region",
        confidence: 0.94,
        approvedVocabulary: ["bring", "hand", "back", "guard"],
        deterministicFallback: "Bring your hand directly back to guard."
    )

    func testValidOnDeviceWordingCannotChangeCorrectionID() async {
        let narrator = ConstrainedCoachingNarrator { _ in
            "return-to-guard|Bring the hand straight back to guard."
        }
        let result = await narrator.narrate(facts)
        XCTAssertEqual(result.source, .onDevice)
        XCTAssertEqual(result.correctionID, facts.correctionID)
    }

    func testChangedCorrectionOrUnsupportedClaimFallsBack() async {
        for output in [
            "straight-path|Bring the hand straight back.",
            "return-to-guard|Add more power and rotate your hips.",
            "return-to-guard|Bring it back in 2 seconds."
        ] {
            let narrator = ConstrainedCoachingNarrator { _ in output }
            let result = await narrator.narrate(facts)
            XCTAssertEqual(result.source, .deterministic)
            XCTAssertEqual(result.sentence, facts.deterministicFallback)
        }
    }

    func testTimeoutFallsBack() async {
        let narrator = ConstrainedCoachingNarrator(timeout: .milliseconds(1)) { _ in
            try await Task.sleep(for: .seconds(1))
            return "return-to-guard|Bring the hand back to guard."
        }
        let result = await narrator.narrate(facts)
        XCTAssertEqual(result.source, .deterministic)
    }
}
