//
//  RoundEngineTests.swift
//  TestTests
//

import Foundation
import Testing
import simd
@testable import Test

@MainActor
struct RoundEngineTests {
    @Test
    func leavingImmersionInvalidatesWorldCalibration() {
        let engine = calibratedEngine()
        #expect(engine.isCalibrated)
        #expect(engine.phase == .ready)

        engine.leaveImmersiveSpace()

        #expect(!engine.isCalibrated)
        #expect(engine.phase == .setup)
        #expect(engine.summary == nil)
    }

    @Test
    func systemInterruptionCancelsPartialCalibration() {
        let engine = makeEngine()
        let guardSample = sample(timestamp: 10)

        engine.setTrackingState(.tracking(handCount: 2))
        engine.startGuardCalibration()
        engine.ingest(guardSample)
        #expect(engine.phase != .setup)

        engine.pauseForSystemInterruption()

        #expect(engine.phase == .setup)
        #expect(engine.validationMessage?.contains("cancelled") == true)
    }

    @Test
    func systemInterruptionInvalidatesGuardWaitingForReach() {
        let engine = makeEngine()
        let start: TimeInterval = 20

        engine.setTrackingState(.tracking(handCount: 2))
        engine.startGuardCalibration()
        engine.ingest(sample(timestamp: start))
        engine.ingest(sample(timestamp: start + 0.11))
        #expect(engine.phase == .awaitingReach)

        engine.pauseForSystemInterruption()

        #expect(engine.phase == .setup)
        #expect(!engine.isCalibrated)
        #expect(engine.validationMessage?.contains("cancelled") == true)
    }

    @Test
    func systemInterruptionClearsBothPartialHandReports() {
        let engine = engineReadyForReach(start: 25)
        engine.startReachCalibration()
        engine.ingest(sample(timestamp: 25.20))
        engine.ingest(sample(
            timestamp: 25.25,
            right: rightGuard + SIMD3<Float>(0, 0, -0.20)
        ))
        engine.ingest(sample(timestamp: 25.30))
        #expect(engine.completedReachRepetitionCount(for: .right) == 1)

        engine.pauseForSystemInterruption()

        #expect(engine.phase == .awaitingReach)
        #expect(engine.functionalCalibrationReport(for: .left) == nil)
        #expect(engine.functionalCalibrationReport(for: .right) == nil)
        #expect(engine.validationMessage?.contains("cancelled") == true)
    }

    @Test
    func terminalTrackingFailureAbortsActiveDrill() {
        let engine = calibratedEngine()
        engine.startRound()
        #expect(engine.isRoundActive)

        engine.setTrackingState(.failed(message: "Provider stopped"))

        #expect(engine.phase == .failed(message: "Provider stopped"))
        #expect(!engine.isRoundActive)
        #expect(engine.validationMessage == "Provider stopped")
    }

    @Test
    func repeatedSystemPauseCountsOnceAndBlocksAdaptiveAdvice() async throws {
        var configuration = testConfiguration()
        configuration.countdownDuration = 0.05
        configuration.roundDuration = 0.06
        configuration.cueDuration = 0.20
        let engine = calibratedEngine(configuration: configuration)
        engine.startRound(difficulty: .sharp)

        engine.pauseForSystemInterruption()
        engine.pauseForSystemInterruption()
        #expect(engine.phase == .pausedForTracking)

        engine.setTrackingState(.tracking(handCount: 2))
        engine.resumeFromSystemInterruption()
        let now = ProcessInfo.processInfo.systemUptime
        engine.ingest(sample(timestamp: now))
        engine.ingest(sample(timestamp: now + 0.06))

        try await Task.sleep(for: .milliseconds(500))
        let summary = try #require(engine.summary)
        #expect(summary.trackingInterruptions == 1)

        let recommendation = TrainingIntensityAdvisor.recommendation(
            from: TrainingSetEvidence(
                kind: .reactiveBoard,
                difficulty: summary.difficulty,
                completedOpportunities: 8,
                minimumOpportunities: 6,
                primaryScore: 1,
                controlScore: 1,
                responseTimeRatio: 0.2,
                trackingInterruptions: summary.trackingInterruptions
            )
        )
        #expect(recommendation.suggested == .sharp)
        #expect(recommendation.reason == .trackingInterrupted)
    }

    @Test
    func reachCalibrationRestartsAfterSampleGap() {
        var configuration = testConfiguration()
        configuration.maximumSampleInterval = 0.15
        let engine = RoundEngine(configuration: configuration)

        engine.setTrackingState(.tracking(handCount: 2))
        engine.startGuardCalibration()
        engine.ingest(sample(timestamp: 10))
        engine.ingest(sample(timestamp: 10.11))
        #expect(engine.phase == .awaitingReach)

        engine.startReachCalibration()
        engine.ingest(sample(timestamp: 10.20))
        engine.ingest(sample(
            timestamp: 10.25,
            left: leftGuard + SIMD3<Float>(0, 0, -0.20)
        ))
        engine.ingest(sample(timestamp: 10.30))
        #expect(engine.completedReachRepetitionCount(for: .left) == 1)

        engine.ingest(sample(timestamp: 10.60))

        #expect(engine.phase == .calibratingReach(progress: 0))
        #expect(!engine.isCalibrated)
        #expect(engine.completedReachRepetitionCount == 0)
        #expect(engine.completedReachRepetitionCount(for: .right) == 0)
        #expect(engine.instruction.contains("tracking gap"))
    }

    @Test
    func oneCompleteRepetitionCannotFinishFunctionalCalibration() {
        let engine = engineReadyForReach(start: 40)

        engine.startReachCalibration()
        engine.ingest(sample(timestamp: 40.20))
        engine.ingest(sample(
            timestamp: 40.25,
            left: leftGuard + SIMD3<Float>(0, 0, -0.21)
        ))
        engine.ingest(sample(timestamp: 40.30))

        #expect(!engine.isCalibrated)
        #expect(engine.completedReachRepetitionCount(for: .left) == 1)
        #expect(engine.completedReachRepetitionCount(for: .right) == 0)
        #expect(engine.functionalCalibrationReport(for: .left)?.grade == .collecting)
        if case .calibratingReach(let progress) = engine.phase {
            #expect(progress == 0.25)
        } else {
            Issue.record("Expected the second reach repetition to remain active")
        }
    }

    @Test
    func acceptedCalibrationUsesIndependentShorterRepetitionForEachHand() {
        let engine = engineReadyForReach(start: 50)

        engine.startReachCalibration()
        engine.ingest(sample(timestamp: 50.20))
        engine.ingest(sample(
            timestamp: 50.25,
            left: leftGuard + SIMD3<Float>(0, 0, -0.22)
        ))
        engine.ingest(sample(timestamp: 50.30))
        engine.ingest(sample(
            timestamp: 50.35,
            left: leftGuard + SIMD3<Float>(0, 0, -0.19)
        ))
        engine.ingest(sample(timestamp: 50.40))

        #expect(!engine.isCalibrated)
        #expect(engine.functionalCalibrationReport(for: .left)?.grade == .consistent)

        engine.ingest(sample(
            timestamp: 50.45,
            right: rightGuard + SIMD3<Float>(0.02, 0, -0.25)
        ))
        engine.ingest(sample(timestamp: 50.50))
        engine.ingest(sample(
            timestamp: 50.55,
            right: rightGuard + SIMD3<Float>(0.015, 0, -0.23)
        ))
        engine.ingest(sample(timestamp: 50.60))

        #expect(engine.phase == .ready)
        #expect(engine.functionalCalibrationReport(for: .right)?.grade == .consistent)
        #expect(abs((engine.calibration?.acceptedFunctionalReach(for: .left) ?? 0) - 0.19) < 0.0001)
        #expect(abs((engine.calibration?.acceptedFunctionalReach(for: .right) ?? 0) - 0.2305) < 0.001)
        #expect(abs((engine.functionalCalibrationReport(for: .left)?.absoluteSpreadMeters ?? 0) - 0.03) < 0.0001)
        #expect(engine.calibration?.straightPunchDirection(for: .left) != engine.calibration?.straightPunchDirection(for: .right))
        #expect(abs((engine.conservativeBilateralProfileReachMeters ?? 0) - 0.19) < 0.0001)
    }

    @Test
    func acceptedMeasurementRemainsUncappedWhileTrainingReachUsesSafetyCap() {
        var configuration = testConfiguration()
        configuration.maximumComfortableReach = 0.20
        let engine = engineReadyForReach(
            start: 55,
            configuration: configuration
        )

        engine.startReachCalibration()
        engine.ingest(sample(timestamp: 55.20))
        engine.ingest(sample(
            timestamp: 55.25,
            left: leftGuard + SIMD3<Float>(0, 0, -0.23)
        ))
        engine.ingest(sample(timestamp: 55.30))
        engine.ingest(sample(
            timestamp: 55.35,
            left: leftGuard + SIMD3<Float>(0, 0, -0.22)
        ))
        engine.ingest(sample(timestamp: 55.40))
        engine.ingest(sample(
            timestamp: 55.45,
            right: rightGuard + SIMD3<Float>(0, 0, -0.25)
        ))
        engine.ingest(sample(timestamp: 55.50))
        engine.ingest(sample(
            timestamp: 55.55,
            right: rightGuard + SIMD3<Float>(0, 0, -0.24)
        ))
        engine.ingest(sample(timestamp: 55.60))

        #expect(engine.phase == .ready)
        #expect(abs((engine.functionalCalibrationReport(for: .left)?.conservativeReachMeters ?? 0) - 0.22) < 0.0001)
        #expect(abs((engine.functionalCalibrationReport(for: .right)?.conservativeReachMeters ?? 0) - 0.24) < 0.0001)
        #expect(abs((engine.conservativeBilateralProfileReachMeters ?? 0) - 0.22) < 0.0001)
        #expect(abs((engine.calibration?.targetPlacementReach(for: .left) ?? 0) - 0.20) < 0.0001)
        #expect(abs((engine.calibration?.targetPlacementReach(for: .right) ?? 0) - 0.20) < 0.0001)
    }

    @Test
    func inconsistentRepetitionsRequireAnExplicitFreshCapture() {
        let engine = engineReadyForReach(start: 60)

        engine.startReachCalibration()
        engine.ingest(sample(timestamp: 60.20))
        engine.ingest(sample(
            timestamp: 60.25,
            left: leftGuard + SIMD3<Float>(0, 0, -0.20)
        ))
        engine.ingest(sample(timestamp: 60.30))
        engine.ingest(sample(
            timestamp: 60.35,
            left: leftGuard + SIMD3<Float>(0, 0, -0.30)
        ))
        engine.ingest(sample(timestamp: 60.40))

        #expect(engine.phase == .awaitingReach)
        #expect(!engine.isCalibrated)
        #expect(engine.functionalCalibrationReport(for: .left)?.grade == .freshCaptureNeeded)
        #expect(engine.functionalCalibrationReport(for: .left)?.captureCount == 2)
        #expect(engine.functionalCalibrationReport(for: .right)?.grade == .collecting)
        #expect(engine.validationMessage?.contains("not repeatable") == true)

        engine.startReachCalibration()

        #expect(engine.phase == .calibratingReach(progress: 0))
        #expect(engine.functionalCalibrationReport(for: .left)?.grade == .collecting)
        #expect(engine.functionalCalibrationReport(for: .left)?.captureCount == 0)
    }

    @Test
    func switchingHandsMidPairPreservesTheCompletedRepetitionAndRequestsOrder() {
        let engine = engineReadyForReach(start: 70)

        engine.startReachCalibration()
        engine.ingest(sample(timestamp: 70.20))
        engine.ingest(sample(
            timestamp: 70.25,
            left: leftGuard + SIMD3<Float>(0, 0, -0.20)
        ))
        engine.ingest(sample(timestamp: 70.30))
        #expect(engine.completedReachRepetitionCount(for: .left) == 1)

        engine.ingest(sample(
            timestamp: 70.35,
            right: rightGuard + SIMD3<Float>(0, 0, -0.20)
        ))

        #expect(!engine.isCalibrated)
        #expect(engine.completedReachRepetitionCount(for: .left) == 1)
        #expect(engine.completedReachRepetitionCount(for: .right) == 0)
        #expect(engine.validationMessage?.contains("Finish the two left-hand") == true)
    }

    @Test
    func eitherHandMayCompleteItsPairFirst() {
        let engine = engineReadyForReach(start: 72)

        engine.startReachCalibration()
        engine.ingest(sample(timestamp: 72.20))
        engine.ingest(sample(
            timestamp: 72.25,
            right: rightGuard + SIMD3<Float>(0, 0, -0.21)
        ))
        engine.ingest(sample(timestamp: 72.30))
        engine.ingest(sample(
            timestamp: 72.35,
            right: rightGuard + SIMD3<Float>(0, 0, -0.20)
        ))
        engine.ingest(sample(timestamp: 72.40))
        #expect(engine.functionalCalibrationReport(for: .right)?.grade == .consistent)
        #expect(!engine.isCalibrated)

        engine.ingest(sample(
            timestamp: 72.45,
            left: leftGuard + SIMD3<Float>(0, 0, -0.24)
        ))
        engine.ingest(sample(timestamp: 72.50))
        engine.ingest(sample(
            timestamp: 72.55,
            left: leftGuard + SIMD3<Float>(0, 0, -0.23)
        ))
        engine.ingest(sample(timestamp: 72.60))

        #expect(engine.phase == .ready)
        #expect(engine.functionalCalibrationReport(for: .left)?.grade == .consistent)
        #expect(abs((engine.conservativeBilateralProfileReachMeters ?? 0) - 0.20) < 0.0001)
    }

    @Test
    func movingTheOtherHandOutOfGuardRestartsCapture() {
        let engine = engineReadyForReach(start: 75)

        engine.startReachCalibration()
        engine.ingest(sample(timestamp: 75.20))
        engine.ingest(sample(
            timestamp: 75.25,
            left: leftGuard + SIMD3<Float>(0, 0, -0.18)
        ))
        engine.ingest(sample(
            timestamp: 75.30,
            left: leftGuard + SIMD3<Float>(0, 0, -0.20),
            right: rightGuard + SIMD3<Float>(0.12, 0, 0)
        ))

        #expect(!engine.isCalibrated)
        #expect(engine.completedReachRepetitionCount == 0)
        #expect(engine.validationMessage?.contains("other fist at guard") == true)
    }

    @Test
    func staleHandPoseRestartsReachCapture() {
        var configuration = testConfiguration()
        configuration.maximumSampleInterval = 0.15
        let engine = engineReadyForReach(
            start: 80,
            configuration: configuration
        )

        engine.startReachCalibration()
        engine.ingest(sample(timestamp: 80.20))
        engine.ingest(sample(
            timestamp: 80.34,
            left: leftGuard + SIMD3<Float>(0, 0, -0.20),
            leftCapturedAt: 80.18,
            rightCapturedAt: 80.34
        ))

        #expect(engine.phase == .calibratingReach(progress: 0))
        #expect(engine.completedReachRepetitionCount == 0)
        #expect(engine.validationMessage?.contains("not current") == true)
    }

    @Test
    func functionalReportIsSessionOnlyAndClearsOnImmersiveExit() {
        let engine = calibratedEngine()
        #expect(engine.functionalCalibrationReport(for: .left)?.grade == .consistent)
        #expect(engine.functionalCalibrationReport(for: .right)?.grade == .consistent)

        engine.leaveImmersiveSpace()

        #expect(engine.functionalCalibrationReport(for: .left) == nil)
        #expect(engine.functionalCalibrationReport(for: .right) == nil)
        #expect(engine.calibration == nil)
    }

    @Test
    func invalidAndReversedSamplesCannotAdvanceCalibration() {
        let engine = makeEngine()
        engine.setTrackingState(.tracking(handCount: 2))
        engine.startGuardCalibration()
        engine.ingest(sample(timestamp: 30))
        engine.ingest(sample(timestamp: .nan))
        #expect(engine.phase == .calibratingGuard(progress: 0))

        engine.ingest(sample(timestamp: 31))
        engine.ingest(sample(timestamp: 30.5))
        #expect(engine.phase == .calibratingGuard(progress: 0))
        #expect(!engine.isCalibrated)
    }

    @Test
    func finishedResultsSurviveExitWhileCalibrationDoesNot() async throws {
        var configuration = testConfiguration()
        configuration.countdownDuration = 0
        configuration.roundDuration = 0.06
        configuration.cueDuration = 0.20
        let engine = calibratedEngine(configuration: configuration)

        engine.startRound()
        try await Task.sleep(for: .milliseconds(300))

        #expect(engine.phase == .finished)
        #expect(engine.summary != nil)
        #expect(engine.summary?.completedAttempts == 0)

        engine.setStance(.southpaw)
        engine.resetCalibration()
        #expect(engine.phase == .finished)
        #expect(engine.summary != nil)

        // Even a late stop action must not erase an already completed summary
        // while the immersive dismissal is settling.
        engine.stop()
        engine.leaveImmersiveSpace()

        #expect(engine.phase == .finished)
        #expect(engine.summary != nil)
        #expect(!engine.isCalibrated)

        engine.prepareAnotherRound()
        #expect(engine.phase == .setup)
    }

    @Test
    func finishedSummaryCapturesTheLevelChosenAtRoundStart() async throws {
        var configuration = testConfiguration()
        configuration.countdownDuration = 0
        configuration.roundDuration = 0.06
        configuration.cueDuration = 0.20
        let engine = calibratedEngine(configuration: configuration)

        engine.startRound(difficulty: .peak)
        try await Task.sleep(for: .milliseconds(300))

        #expect(engine.summary?.difficulty == .peak)
        #expect(engine.activeDifficulty == .peak)
        #expect(engine.configuration.targetRadius == configuration.targetRadius)
        #expect(engine.configuration.minimumPunchTravel == configuration.minimumPunchTravel)
    }

    private func calibratedEngine(
        configuration: DrillConfiguration? = nil
    ) -> RoundEngine {
        let engine = engineReadyForReach(
            start: 100,
            configuration: configuration
        )
        let start: TimeInterval = 100

        engine.startReachCalibration()
        engine.ingest(sample(timestamp: start + 0.20))
        engine.ingest(sample(
            timestamp: start + 0.25,
            left: leftGuard + SIMD3<Float>(0, 0, -0.20)
        ))
        engine.ingest(sample(timestamp: start + 0.30))
        engine.ingest(sample(
            timestamp: start + 0.35,
            left: leftGuard + SIMD3<Float>(0, 0, -0.19)
        ))
        engine.ingest(sample(timestamp: start + 0.40))
        engine.ingest(sample(
            timestamp: start + 0.45,
            right: rightGuard + SIMD3<Float>(0, 0, -0.21)
        ))
        engine.ingest(sample(timestamp: start + 0.50))
        engine.ingest(sample(
            timestamp: start + 0.55,
            right: rightGuard + SIMD3<Float>(0, 0, -0.20)
        ))
        engine.ingest(sample(timestamp: start + 0.60))
        #expect(engine.phase == .ready)
        return engine
    }

    private func engineReadyForReach(
        start: TimeInterval,
        configuration: DrillConfiguration? = nil
    ) -> RoundEngine {
        let engine = RoundEngine(configuration: configuration ?? testConfiguration())
        engine.setTrackingState(.tracking(handCount: 2))
        engine.startGuardCalibration()
        engine.ingest(sample(timestamp: start))
        engine.ingest(sample(timestamp: start + 0.11))
        #expect(engine.phase == .awaitingReach)
        return engine
    }

    private func makeEngine() -> RoundEngine {
        RoundEngine(configuration: testConfiguration())
    }

    private func testConfiguration() -> DrillConfiguration {
        var configuration = DrillConfiguration.provisional
        configuration.guardHoldDuration = 0.10
        configuration.reachCaptureDuration = 0.30
        configuration.minimumComfortableReach = 0.12
        configuration.maximumGuardSpeed = 0.50
        configuration.resumeGuardHoldDuration = 0.05
        return configuration
    }

    private var leftGuard: SIMD3<Float> {
        SIMD3<Float>(-0.10, 1.30, -0.35)
    }

    private var rightGuard: SIMD3<Float> {
        SIMD3<Float>(0.10, 1.30, -0.35)
    }

    private func sample(
        timestamp: TimeInterval,
        left: SIMD3<Float>? = nil,
        right: SIMD3<Float>? = nil,
        leftCapturedAt: TimeInterval? = nil,
        rightCapturedAt: TimeInterval? = nil
    ) -> HandSample {
        let leftPosition = left ?? leftGuard
        let rightPosition = right ?? rightGuard
        return HandSample(
            timestamp: timestamp,
            left: HandPose(
                fistCenter: leftPosition,
                wrist: nil,
                trackedKnuckleCount: 4,
                capturedAt: leftCapturedAt ?? timestamp
            ),
            right: HandPose(
                fistCenter: rightPosition,
                wrist: nil,
                trackedKnuckleCount: 4,
                capturedAt: rightCapturedAt ?? timestamp
            )
        )
    }
}
