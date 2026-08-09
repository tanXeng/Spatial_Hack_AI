import XCTest
@testable import BoxingCoach

final class CoachSecretsTests: XCTestCase {
    private let suiteName = "CoachSecretsTests"

    override func setUp() {
        super.setUp()
        CoachSecrets.testingDefaultsSuiteName = suiteName
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        CoachSecrets.testingDefaultsSuiteName = nil
        super.tearDown()
    }

    func testSaveAndClearRoundTrip() {
        XCTAssertFalse(CoachSecrets.hasOpenAIKey)
        XCTAssertEqual(CoachSecrets.openAIKeySource, .none)

        CoachSecrets.setOpenAIAPIKey("  sk-test-key-123  ")
        XCTAssertEqual(CoachSecrets.openAIAPIKey, "sk-test-key-123")
        XCTAssertTrue(CoachSecrets.hasOpenAIKey)
        XCTAssertEqual(CoachSecrets.openAIKeySource, .inApp)

        CoachSecrets.setOpenAIAPIKey(nil)
        XCTAssertNil(CoachSecrets.openAIAPIKey)
        XCTAssertFalse(CoachSecrets.hasOpenAIKey)
        XCTAssertEqual(CoachSecrets.openAIKeySource, .none)
    }

    func testValidationRejectsInvalidValues() {
        XCTAssertNil(CoachSecrets.validatedKey(from: nil))
        XCTAssertNil(CoachSecrets.validatedKey(from: ""))
        XCTAssertNil(CoachSecrets.validatedKey(from: "   "))
        XCTAssertNil(CoachSecrets.validatedKey(from: "$(OPENAI_API_KEY)"))
        XCTAssertNil(CoachSecrets.validatedKey(from: "sk-your-key-here"))

        CoachSecrets.setOpenAIAPIKey("")
        XCTAssertNil(CoachSecrets.openAIAPIKey)

        CoachSecrets.setOpenAIAPIKey("sk-your-key-here")
        XCTAssertNil(CoachSecrets.openAIAPIKey)
    }

    func testInAppKeyTakesPriorityOverBuildConfig() {
        CoachSecrets.setOpenAIAPIKey("sk-in-app-priority")
        XCTAssertEqual(CoachSecrets.openAIAPIKey, "sk-in-app-priority")
        XCTAssertEqual(CoachSecrets.openAIKeySource, .inApp)
    }
}
