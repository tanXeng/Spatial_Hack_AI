import Foundation
import Testing
@testable import BoxingCoach

@Suite("Hand tracking lifecycle")
struct HandTrackingLifecycleTests {
    @Test("The runtime follows the explicit start, recovery, pause, and stop states")
    func lifecycleStateTable() {
        let steps: [LifecycleStep] = [
            LifecycleStep(
                name: "request authorization",
                event: .startRequested,
                expected: snapshot(state: .requestingAuthorization, generation: 1),
                effects: [.clearTrackingData, .cancelListeners, .stopSession, .prepareProviders]
            ),
            LifecycleStep(
                name: "authorization allowed",
                event: .authorizationCompleted(generation: 1, status: .allowed),
                expected: snapshot(state: .starting, generation: 1)
            ),
            LifecycleStep(
                name: "providers started",
                event: .sessionStarted(generation: 1, worldTrackingAvailable: true),
                expected: snapshot(state: .running, generation: 1)
            ),
            LifecycleStep(
                name: "required wrist lost",
                event: .sampleRejected(
                    generation: 1,
                    reason: .missingRequiredJoint(side: .left, joint: "wrist")
                ),
                expected: snapshot(
                    state: .degraded,
                    generation: 1,
                    reason: .missingRequiredJoint(side: .left, joint: "wrist"),
                    recovery: .keepHandsVisible
                ),
                effects: [.clearTrackingData]
            ),
            LifecycleStep(
                name: "first reacquisition sample",
                event: .sampleAccepted(
                    generation: 1,
                    side: .left,
                    acquisitionTimestamp: 10,
                    receiptTimestamp: 10.01
                ),
                expected: snapshot(
                    state: .degraded,
                    generation: 1,
                    reason: .missingRequiredJoint(side: .left, joint: "wrist"),
                    streak: 1,
                    recovery: .keepHandsVisible,
                    timestamps: [.left: 10]
                ),
                effects: [.bufferSample]
            ),
            LifecycleStep(
                name: "second reacquisition sample",
                event: .sampleAccepted(
                    generation: 1,
                    side: .right,
                    acquisitionTimestamp: 10.01,
                    receiptTimestamp: 10.02
                ),
                expected: snapshot(
                    state: .degraded,
                    generation: 1,
                    reason: .missingRequiredJoint(side: .left, joint: "wrist"),
                    streak: 2,
                    recovery: .keepHandsVisible,
                    timestamps: [.left: 10, .right: 10.01]
                ),
                effects: [.bufferSample]
            ),
            LifecycleStep(
                name: "third reacquisition sample",
                event: .sampleAccepted(
                    generation: 1,
                    side: .left,
                    acquisitionTimestamp: 10.02,
                    receiptTimestamp: 10.03
                ),
                expected: snapshot(
                    state: .running,
                    generation: 1,
                    streak: 3,
                    timestamps: [.left: 10.02, .right: 10.01]
                ),
                effects: [.admitSample]
            ),
            LifecycleStep(
                name: "provider paused",
                event: .providerStateChanged(
                    generation: 1,
                    state: .paused,
                    errorDescription: nil
                ),
                expected: snapshot(
                    state: .paused,
                    generation: 1,
                    reason: .providerPaused,
                    recovery: .waitForProvider
                ),
                effects: [.clearTrackingData]
            ),
            LifecycleStep(
                name: "provider resumed into reacquisition",
                event: .providerStateChanged(
                    generation: 1,
                    state: .running,
                    errorDescription: nil
                ),
                expected: snapshot(
                    state: .degraded,
                    generation: 1,
                    reason: .reacquiring,
                    recovery: .keepHandsVisible
                )
            ),
            LifecycleStep(
                name: "explicit stop",
                event: .stopRequested,
                expected: snapshot(state: .stopped, generation: 2),
                effects: [.clearTrackingData, .cancelListeners, .stopSession]
            )
        ]

        var current = TrackingRuntimeSnapshot.initial
        for step in steps {
            let transition = TrackingRuntimeReducer.reduce(current, event: step.event)
            #expect(transition.snapshot == step.expected, "Unexpected state after \(step.name)")
            #expect(transition.effects == step.effects, "Unexpected effects after \(step.name)")
            current = transition.snapshot
        }
    }

    @Test("Revocation, provider stop, and start errors fail closed")
    func terminalFailureTable() {
        let running = snapshot(state: .running, generation: 5, streak: 3)
        let starting = snapshot(state: .starting, generation: 5)
        let cases: [FailureCase] = [
            FailureCase(
                name: "authorization revoked",
                initial: running,
                event: .authorizationChanged(generation: 5, status: .denied),
                expectedReason: .authorizationRevoked,
                expectedRecovery: .reviewAuthorization
            ),
            FailureCase(
                name: "provider stopped",
                initial: running,
                event: .providerStateChanged(
                    generation: 5,
                    state: .stopped,
                    errorDescription: nil
                ),
                expectedReason: .providerStopped,
                expectedRecovery: .retryTracking
            ),
            FailureCase(
                name: "provider failed",
                initial: running,
                event: .providerStateChanged(
                    generation: 5,
                    state: .stopped,
                    errorDescription: "camera unavailable"
                ),
                expectedReason: .providerFailed(message: "camera unavailable"),
                expectedRecovery: .retryTracking
            ),
            FailureCase(
                name: "session start failed",
                initial: starting,
                event: .startFailed(generation: 5, message: "provider could not run"),
                expectedReason: .sessionFailed(message: "provider could not run"),
                expectedRecovery: .retryTracking
            )
        ]

        for testCase in cases {
            let transition = TrackingRuntimeReducer.reduce(testCase.initial, event: testCase.event)
            #expect(transition.snapshot.state == .failed, "\(testCase.name) must fail")
            #expect(transition.snapshot.providerGeneration == 6)
            #expect(transition.snapshot.rejectionReason == testCase.expectedReason)
            #expect(transition.snapshot.acceptedSampleStreak == 0)
            #expect(transition.snapshot.recoveryInstruction == testCase.expectedRecovery)
            #expect(transition.snapshot.lastAcceptedAcquisitionTimestamps.isEmpty)
            #expect(
                transition.effects == [.clearTrackingData, .cancelListeners, .stopSession]
            )
        }
    }

    @Test("Stopped generations reject late events and retry creates a fresh provider generation")
    func providerGenerationGatesLateWorkAndRetry() {
        let running = snapshot(state: .running, generation: 4, streak: 3)
        let stopped = TrackingRuntimeReducer.reduce(running, event: .stopRequested)
        #expect(stopped.snapshot.providerGeneration == 5)

        let lateAnchor = TrackingRuntimeReducer.reduce(
            stopped.snapshot,
            event: .sampleAccepted(
                generation: 4,
                side: .left,
                acquisitionTimestamp: 20,
                receiptTimestamp: 20.01
            )
        )
        #expect(lateAnchor.snapshot == stopped.snapshot)
        #expect(lateAnchor.effects.isEmpty)

        let lateProviderEvent = TrackingRuntimeReducer.reduce(
            stopped.snapshot,
            event: .providerStateChanged(
                generation: 4,
                state: .running,
                errorDescription: nil
            )
        )
        #expect(lateProviderEvent.snapshot == stopped.snapshot)
        #expect(lateProviderEvent.effects.isEmpty)

        let retry = TrackingRuntimeReducer.reduce(stopped.snapshot, event: .retryRequested)
        #expect(retry.snapshot == snapshot(state: .requestingAuthorization, generation: 6))
        #expect(
            retry.effects == [.clearTrackingData, .cancelListeners, .stopSession, .prepareProviders]
        )
    }

    @Test("Unavailable required world tracking fails closed and remains retryable")
    func unavailableWorldTrackingIsTerminalAndRetryable() {
        let starting = snapshot(state: .starting, generation: 8)
        let unavailable = TrackingRuntimeReducer.reduce(
            starting,
            event: .sessionStarted(generation: 8, worldTrackingAvailable: false)
        )

        #expect(unavailable.snapshot.state == .failed)
        #expect(unavailable.snapshot.providerGeneration == 9)
        #expect(unavailable.snapshot.rejectionReason == .worldTrackingUnavailable)
        #expect(unavailable.snapshot.recoveryInstruction == .none)
        #expect(
            unavailable.effects == [.clearTrackingData, .cancelListeners, .stopSession]
        )

        let retry = TrackingRuntimeReducer.reduce(
            unavailable.snapshot,
            event: .retryRequested
        )
        #expect(retry.snapshot == snapshot(state: .requestingAuthorization, generation: 10))
        #expect(
            retry.effects == [.clearTrackingData, .cancelListeners, .stopSession, .prepareProviders]
        )
    }

    @Test("A canceled startup is generation-gated and stops before creating listeners")
    func canceledStartupUsesInjectedCancellationSeam() async {
        let service = HandTrackingService(startupIsCancelled: { true })

        await service.start()

        #expect(service.runtimeState == .stopped)
        #expect(service.providerGeneration == 2)
        #expect(service.continuityEpoch == 2)
        #expect(service.statusMessage == "Hand tracking stopped")
    }

    @Test("Stopping twice is idempotent")
    func duplicateStopDoesNotAdvanceGenerationOrRepeatEffects() {
        let stopped = snapshot(state: .stopped, generation: 11)
        let duplicate = TrackingRuntimeReducer.reduce(stopped, event: .stopRequested)

        #expect(duplicate.snapshot == stopped)
        #expect(duplicate.effects.isEmpty)
    }

    @Test("Starting twice does not create a second provider generation")
    func duplicateStartIsIdempotent() {
        let requesting = snapshot(state: .requestingAuthorization, generation: 12)
        let duplicate = TrackingRuntimeReducer.reduce(requesting, event: .startRequested)

        #expect(duplicate.snapshot == requesting)
        #expect(duplicate.effects.isEmpty)
    }

    @Test("Acquisition age and acquisition gaps reset the recovery streak")
    func staleAndGapTable() {
        let recovering = snapshot(
            state: .degraded,
            generation: 7,
            reason: .reacquiring,
            streak: 2,
            recovery: .keepHandsVisible,
            timestamps: [.left: 9.98, .right: 9.99]
        )
        let cases: [TimingFailureCase] = [
            TimingFailureCase(
                name: "stale acquisition despite a current receipt",
                event: .sampleAccepted(
                    generation: 7,
                    side: .left,
                    acquisitionTimestamp: 10,
                    receiptTimestamp: 10.2
                ),
                expectedKind: .stale,
                expectedDuration: 0.2
            ),
            TimingFailureCase(
                name: "material acquisition gap",
                event: .sampleAccepted(
                    generation: 7,
                    side: .left,
                    acquisitionTimestamp: 10.6,
                    receiptTimestamp: 10.61
                ),
                expectedKind: .gap,
                expectedDuration: 0.61
            )
        ]

        for testCase in cases {
            let transition = TrackingRuntimeReducer.reduce(recovering, event: testCase.event)
            #expect(transition.snapshot.state == .degraded, "\(testCase.name) must degrade")
            switch (testCase.expectedKind, transition.snapshot.rejectionReason) {
            case let (.stale, .staleSample(age)):
                #expect(abs(age - testCase.expectedDuration) < 1e-9)
            case let (.gap, .sampleGap(duration)):
                #expect(abs(duration - testCase.expectedDuration) < 1e-9)
            default:
                Issue.record("\(testCase.name) produced the wrong rejection reason")
            }
            #expect(transition.snapshot.acceptedSampleStreak == 0)
            #expect(transition.snapshot.lastAcceptedAcquisitionTimestamps.isEmpty)
            #expect(transition.effects == [.clearTrackingData])
        }
    }

    @Test("Acquisition continuity has a hard 0.20 second ceiling across both hands")
    func acquisitionGapBoundaryAndCrossChiralityReset() {
        #expect(TrackingRuntimeReducer.maximumSampleGap == 0.20)

        let recovering = snapshot(
            state: .degraded,
            generation: 7,
            reason: .reacquiring,
            streak: 1,
            recovery: .keepHandsVisible,
            timestamps: [.left: 10]
        )
        let exactBoundary = TrackingRuntimeReducer.reduce(
            recovering,
            event: .sampleAccepted(
                generation: 7,
                side: .left,
                acquisitionTimestamp: 10.20,
                receiptTimestamp: 10.21
            )
        )
        #expect(exactBoundary.snapshot.acceptedSampleStreak == 2)
        #expect(exactBoundary.snapshot.lastAcceptedAcquisitionTimestamps[.left] == 10.20)
        #expect(exactBoundary.effects == [.bufferSample])

        let overBoundary = TrackingRuntimeReducer.reduce(
            recovering,
            event: .sampleAccepted(
                generation: 7,
                side: .left,
                acquisitionTimestamp: 10.200_001,
                receiptTimestamp: 10.21
            )
        )
        guard case let .sampleGap(duration) = overBoundary.snapshot.rejectionReason else {
            Issue.record("A same-hand gap above 0.20 seconds was admitted")
            return
        }
        #expect(abs(duration - 0.200_001) < 1e-9)
        #expect(overBoundary.snapshot.acceptedSampleStreak == 0)
        #expect(overBoundary.snapshot.lastAcceptedAcquisitionTimestamps.isEmpty)
        #expect(overBoundary.effects == [.clearTrackingData])

        let crossHandGap = TrackingRuntimeReducer.reduce(
            recovering,
            event: .sampleAccepted(
                generation: 7,
                side: .right,
                acquisitionTimestamp: 20,
                receiptTimestamp: 20.01
            )
        )
        guard case .sampleGap = crossHandGap.snapshot.rejectionReason else {
            Issue.record("A cross-hand gap bypassed global continuity")
            return
        }
        #expect(crossHandGap.snapshot.acceptedSampleStreak == 0)
        #expect(crossHandGap.snapshot.lastAcceptedAcquisitionTimestamps.isEmpty)
        #expect(crossHandGap.effects == [.clearTrackingData])
    }

    @Test("A continuously tracked opposite hand cannot hide a returning hand's gap")
    func perHandGapStillResetsAfterInterleavedSamples() {
        let interleaved = snapshot(
            state: .degraded,
            generation: 7,
            reason: .reacquiring,
            streak: 2,
            recovery: .keepHandsVisible,
            timestamps: [.left: 10, .right: 20]
        )

        let returningLeft = TrackingRuntimeReducer.reduce(
            interleaved,
            event: .sampleAccepted(
                generation: 7,
                side: .left,
                acquisitionTimestamp: 20.01,
                receiptTimestamp: 20.02
            )
        )

        guard case let .sampleGap(duration) = returningLeft.snapshot.rejectionReason else {
            Issue.record("Recent opposite-hand evidence hid the returning hand's gap")
            return
        }
        #expect(abs(duration - 10.01) < 1e-9)
        #expect(returningLeft.snapshot.acceptedSampleStreak == 0)
        #expect(returningLeft.snapshot.lastAcceptedAcquisitionTimestamps.isEmpty)
        #expect(returningLeft.effects == [.clearTrackingData])
    }

    @Test("Buffered reacquisition observations must still be fresh at publication time")
    func bufferedReacquisitionFreshnessUsesAcquisitionTime() {
        #expect(
            TrackingRuntimeReducer.isFreshForRecovery(
                acquisitionTimestamp: 0,
                at: 0.10
            )
        )
        #expect(
            !TrackingRuntimeReducer.isFreshForRecovery(
                acquisitionTimestamp: 0,
                at: 0.100_001
            )
        )
    }

    @Test("Continuity loss invalidates active capture and calibration batches exactly once")
    func continuityEpochInvalidatesPartialEvidence() {
        let service = HandTrackingService()
        var captureContinuity = TrackingContinuityObserver(epoch: service.continuityEpoch)
        var calibrationContinuity = TrackingContinuityObserver(epoch: service.continuityEpoch)
        let recorder = MotionRecorder()
        recorder.begin(at: 1)
        var calibrationBatch = [1.0, 1.1, 1.2]

        service.stop()

        #expect(service.continuityEpoch == 1)
        if captureContinuity.observe(service.continuityEpoch) {
            recorder.cancel()
        }
        if calibrationContinuity.observe(service.continuityEpoch) {
            calibrationBatch.removeAll()
        }

        #expect(!recorder.isRecording)
        #expect(recorder.sampleCount == 0)
        #expect(calibrationBatch.isEmpty)
        let captureObservedAgain = captureContinuity.observe(service.continuityEpoch)
        let calibrationObservedAgain = calibrationContinuity.observe(service.continuityEpoch)
        #expect(!captureObservedAgain)
        #expect(!calibrationObservedAgain)
    }

    @Test("Receipt time is telemetry and never replaces acquisition time")
    func acceptedSampleStoresAcquisitionTime() {
        let running = snapshot(state: .running, generation: 3)
        let transition = TrackingRuntimeReducer.reduce(
            running,
            event: .sampleAccepted(
                generation: 3,
                side: .right,
                acquisitionTimestamp: 30,
                receiptTimestamp: 30.05
            )
        )

        #expect(transition.snapshot.lastAcceptedAcquisitionTimestamps == [.right: 30])
        #expect(transition.snapshot.acceptedSampleStreak == 1)
        #expect(transition.effects == [.admitSample])
    }

    @Test("The reducer is callable through a nonisolated Sendable function")
    nonisolated func reducerHasExplicitConcurrencyContract() async {
        let reduce: @Sendable (
            TrackingRuntimeSnapshot,
            TrackingRuntimeEvent
        ) -> TrackingRuntimeTransition = TrackingRuntimeReducer.reduce

        let transition = await Task.detached {
            reduce(.initial, .startRequested)
        }.value

        #expect(transition.snapshot.state == .requestingAuthorization)
        #expect(transition.snapshot.providerGeneration == 1)
    }

    private struct LifecycleStep {
        let name: String
        let event: TrackingRuntimeEvent
        let expected: TrackingRuntimeSnapshot
        let effects: Set<TrackingRuntimeEffect>

        init(
            name: String,
            event: TrackingRuntimeEvent,
            expected: TrackingRuntimeSnapshot,
            effects: Set<TrackingRuntimeEffect> = []
        ) {
            self.name = name
            self.event = event
            self.expected = expected
            self.effects = effects
        }
    }

    private struct FailureCase {
        let name: String
        let initial: TrackingRuntimeSnapshot
        let event: TrackingRuntimeEvent
        let expectedReason: TrackingRuntimeRejectionReason
        let expectedRecovery: TrackingRecoveryInstruction
    }

    private struct TimingFailureCase {
        let name: String
        let event: TrackingRuntimeEvent
        let expectedKind: TimingFailureKind
        let expectedDuration: TimeInterval
    }

    private enum TimingFailureKind {
        case stale
        case gap
    }

    private func snapshot(
        state: TrackingRuntimeState,
        generation: UInt64,
        reason: TrackingRuntimeRejectionReason? = nil,
        streak: Int = 0,
        recovery: TrackingRecoveryInstruction = .none,
        timestamps: [BodySide: TimeInterval] = [:]
    ) -> TrackingRuntimeSnapshot {
        TrackingRuntimeSnapshot(
            state: state,
            providerGeneration: generation,
            rejectionReason: reason,
            acceptedSampleStreak: streak,
            recoveryInstruction: recovery,
            lastAcceptedAcquisitionTimestamps: timestamps
        )
    }
}
