import XCTest
@testable import BoxingCoach

@MainActor
final class GuidedBoxingSessionTests: XCTestCase {
    func testCalibrationRequiresHalfSecondOfStableEvidence() {
        let session = GuidedBoxingSession()
        session.start(plan: .guidedCore)

        session.advanceCalibration(withFreshEvidenceAt: 10)
        session.advanceCalibration(withFreshEvidenceAt: 10.49)
        XCTAssertEqual(session.stage, .acquiringTracking)

        session.advanceCalibration(withFreshEvidenceAt: 10.5)
        XCTAssertEqual(session.stage, .calibratingOpenHands)
    }

    func testOfficialRunStopsAfterThreeTechnicalDiscards() {
        let session = GuidedBoxingSession()
        session.start(plan: .controlledOneTwoOfficial)

        session.pause(.requiredSampleStale)
        recoverAndResume(session, startingAt: 1)
        session.pause(.requiredJointsUnavailable)
        recoverAndResume(session, startingAt: 2)
        session.pause(.providerStopped)

        XCTAssertEqual(session.stage, .failed(.technicalDiscardLimit))
        XCTAssertEqual(session.technicalDiscardCount, 3)
    }

    func testRecoveryRequiresFreshGuardEvidenceAndExplicitResume() {
        let session = GuidedBoxingSession()
        session.start(plan: .guidedCore)
        session.pause(.requiredSampleStale)

        session.noteRecoveryEvidence(at: 4, bothHandsInGuard: true)
        session.noteRecoveryEvidence(at: 4.5, bothHandsInGuard: true)
        XCTAssertTrue(session.readyToResume)
        XCTAssertEqual(session.stage, .paused(.requiredSampleStale))

        session.resume()
        XCTAssertEqual(session.stage, .acquiringTracking)
    }

    func testFistClassifierNeedsThreeChainsAndKeepsAmbiguousShapesUncertain() {
        XCTAssertEqual(
            FistStateClassifier.classify(fingertipToKnuckleRatios: [0.8, 0.9]),
            .uncertain
        )
        XCTAssertEqual(
            FistStateClassifier.classify(fingertipToKnuckleRatios: [0.9, 1.0, 1.1, 0.95]),
            .closed
        )
        XCTAssertEqual(
            FistStateClassifier.classify(fingertipToKnuckleRatios: [1.7, 1.8, 1.65]),
            .open
        )
        XCTAssertEqual(
            FistStateClassifier.classify(fingertipToKnuckleRatios: [1.3, 1.4, 1.35]),
            .uncertain
        )
    }

    private func recoverAndResume(_ session: GuidedBoxingSession, startingAt time: TimeInterval) {
        session.noteRecoveryEvidence(at: time, bothHandsInGuard: true)
        session.noteRecoveryEvidence(at: time + 0.5, bothHandsInGuard: true)
        session.resume()
    }
}

