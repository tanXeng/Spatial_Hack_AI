import Foundation
import Testing
@testable import BoxingCoach

@Suite("State-gated training command execution")
@MainActor
struct TrainingCommandExecutorTests {
    @Test(
        "Every intent is executed only in its literal approved states",
        arguments: TrainingCommandMatrixCase.all
    )
    func everyIntentUsesExactStateGate(testCase: TrainingCommandMatrixCase) async {
        let target = TrainingCommandTargetFixture(
            state: testCase.state,
            capabilities: Set(VoiceCommandCapability.allCases)
        )

        let result = await TrainingCommandExecutor().execute(
            testCase.intent,
            issuedFor: target.commandGeneration,
            on: target
        )

        if testCase.isAllowed {
            guard case let .executed(receipt) = result else {
                Issue.record("Expected an execution receipt for \(testCase.testDescription)")
                return
            }
            #expect(receipt.intent == testCase.intent)
            #expect(receipt.generation == 41)
            #expect(target.executedIntents == [testCase.intent])
        } else {
            #expect(
                result == .rejected(
                    .unavailableInState(intent: testCase.intent, state: testCase.state)
                )
            )
            #expect(target.executedIntents.isEmpty)
        }
    }

    @Test("An unavailable explicit capability cannot mutate training")
    func unavailableCapabilityRejectsBeforeMutation() async {
        let target = TrainingCommandTargetFixture(state: .learn, capabilities: [])

        let result = await TrainingCommandExecutor().execute(
            .pause,
            issuedFor: target.commandGeneration,
            on: target
        )

        #expect(result == .rejected(.unavailableCapability(intent: .pause)))
        #expect(target.executedIntents.isEmpty)
        #expect(target.isPaused == false)
    }

    @Test("A stale command generation cannot mutate a replacement route or session")
    func staleGenerationRejectsBeforeMutation() async {
        let target = TrainingCommandTargetFixture(
            state: .learn,
            capabilities: [.pause],
            generation: 42
        )

        let result = await TrainingCommandExecutor().execute(
            .pause,
            issuedFor: 41,
            on: target
        )

        #expect(result == .rejected(.staleGeneration(expected: 42, actual: 41)))
        #expect(target.executedIntents.isEmpty)
        #expect(target.isPaused == false)
    }

    @Test("An explicit end request creates confirmation without shutting down")
    func endRequestRequiresConfirmation() async throws {
        let target = TrainingCommandTargetFixture(
            state: .baseline,
            capabilities: [.requestEnd]
        )

        let result = await TrainingCommandExecutor().execute(
            .requestEnd,
            issuedFor: target.commandGeneration,
            on: target
        )

        let receipt = try #require(result.receipt)
        #expect(receipt.followUp == .confirmEnd)
        #expect(target.pendingConfirmation == .endTraining)
        #expect(target.didEndTraining == false)
    }

    @Test("Only confirm end runs serialized shutdown")
    func confirmEndRunsShutdown() async throws {
        let target = TrainingCommandTargetFixture(
            state: .awaitingEndConfirmation,
            capabilities: [.confirmEnd],
            pendingConfirmation: .endTraining
        )

        let result = await TrainingCommandExecutor().execute(
            .confirmEnd,
            issuedFor: target.commandGeneration,
            on: target
        )

        let receipt = try #require(result.receipt)
        #expect(receipt.intent == .confirmEnd)
        #expect(receipt.followUp == nil)
        #expect(target.didEndTraining)
        #expect(target.pendingConfirmation == nil)
    }

    @Test("Cancel end clears confirmation and preserves training")
    func cancelEndPreservesTraining() async {
        let target = TrainingCommandTargetFixture(
            state: .awaitingEndConfirmation,
            capabilities: [.cancelEnd],
            pendingConfirmation: .endTraining
        )

        let result = await TrainingCommandExecutor().execute(
            .cancelEnd,
            issuedFor: target.commandGeneration,
            on: target
        )

        #expect(result.receipt?.intent == .cancelEnd)
        #expect(target.pendingConfirmation == nil)
        #expect(target.didEndTraining == false)
    }

    @Test("Participant handoff is request-only and cannot clear participant state")
    func participantHandoffRequiresVisibleConfirmation() async throws {
        let target = TrainingCommandTargetFixture(
            state: .results,
            capabilities: [.requestParticipantHandoff]
        )

        let result = await TrainingCommandExecutor().execute(
            .requestParticipantHandoff,
            issuedFor: target.commandGeneration,
            on: target
        )

        let receipt = try #require(result.receipt)
        #expect(receipt.followUp == .confirmParticipantHandoff)
        #expect(target.pendingConfirmation == .participantHandoff)
        #expect(target.didResetParticipant == false)
    }

    @Test("Action acknowledgement exists only after the target accepts execution")
    func rejectedActionHasNoSuccessReceipt() async {
        let target = TrainingCommandTargetFixture(
            state: .learn,
            capabilities: [.pause]
        )
        target.rejectNextAction = true

        let result = await TrainingCommandExecutor().execute(
            .pause,
            issuedFor: target.commandGeneration,
            on: target
        )

        #expect(result == .rejected(.targetRejected(intent: .pause)))
        #expect(result.receipt == nil)
        #expect(target.isPaused == false)
    }

    @Test("Portable command values have explicit Sendable contracts")
    nonisolated func commandValuesAreSendable() {
        requireSendable(TrainingDemoRate.self)
        requireSendable(TrainingCommandConfirmation.self)
        requireSendable(TrainingCommandFollowUp.self)
        requireSendable(TrainingCommandExecutionReceipt.self)
        requireSendable(TrainingCommandExecutionRejection.self)
        requireSendable(TrainingCommandExecutionResult.self)
        requireSendable(TrainingShutdownOutcome.self)
    }

    @Test("Voice pause invalidates an active reactive partial without recording a miss")
    func reactivePauseInvalidatesPartialWithoutMiss() {
        let session = makeCommandSession()
        session.startDrill()
        defer {
            session.stopDrill()
            session.hands.stop()
        }
        let attemptsBeforePause = session.metrics.attempts.count

        let response = session.pauseForVoice()

        #expect(response != nil)
        #expect(session.isVoicePaused)
        #expect(session.isTrackingPaused)
        #expect(session.voicePauseInvalidationCount == 1)
        #expect(session.metrics.attempts.count == attemptsBeforePause)
    }

    @Test("Air pause during completed-target delay resumes at the next target")
    func airDelayUsesNextExecutionCheckpointWithoutReplayingScore() {
        let session = makeCommandSession()
        let completedAttempt = TargetAttempt(
            id: UUID(),
            spawnTime: Date(timeIntervalSince1970: 10),
            hitTime: Date(timeIntervalSince1970: 10.2),
            result: .hit,
            distanceAtHit: 0.01,
            fistTravelDistance: 0.4,
            estimatedSpeedMetersPerSecond: 2
        )
        session.metrics.record(completedAttempt)

        session.voiceTargetDidBegin(at: 2)
        session.voiceTargetDidComplete(at: 2)

        #expect(session.voiceContinuationCheckpoint == .interTargetDelay(
            displayedTargetIndex: 2,
            nextTargetIndex: 3
        ))
        #expect(session.voiceContinuationCheckpoint.resumeLocation == .airTarget(index: 3))
        #expect(session.currentTargetIndex == 2)
        #expect(session.metrics.attempts.map(\.id) == [completedAttempt.id])
    }

    @Test("Combination pause during completed-rep delay resumes once at the next rep")
    func combinationDelayDoesNotReplayCompletedStepOrDoubleRep() {
        let session = makeCommandSession()
        session.configure(
            mode: .combination,
            combination: .oneTwo,
            stance: .orthodox
        )
        let completedAttempts = [0, 1].map { index in
            TargetAttempt(
                id: UUID(),
                spawnTime: Date(timeIntervalSince1970: TimeInterval(index)),
                hitTime: Date(timeIntervalSince1970: TimeInterval(index) + 0.2),
                result: .hit,
                distanceAtHit: 0.01,
                fistTravelDistance: 0.4,
                estimatedSpeedMetersPerSecond: 2
            )
        }
        completedAttempts.forEach(session.metrics.record)

        session.voiceCombinationStepDidBegin(rep: 1, step: 1)
        session.voiceCombinationStepDidComplete(rep: 1, step: 1, stepCount: 2)
        session.voiceCombinationRepDidComplete(at: 1)

        #expect(session.voiceContinuationCheckpoint == .interCombinationDelay(
            displayedRepIndex: 1,
            nextRepIndex: 2
        ))
        #expect(session.voiceContinuationCheckpoint.resumeLocation == .combination(rep: 2, step: 0))
        #expect(session.currentTargetIndex == 1)
        #expect(session.currentComboStepIndex == 1)
        #expect(session.comboRepsCompleted == 1)
        #expect(session.metrics.attempts.map(\.id) == completedAttempts.map(\.id))
    }

    @Test("Resume rejects before countdown unless tracking is running with fresh guard")
    func reactiveResumeRequiresTrackingAndFreshGuard() async {
        let session = makeCommandSession()
        session.startDrill()
        defer {
            session.stopDrill()
            session.hands.stop()
        }
        _ = session.pauseForVoice()
        var countdownValues: [Int] = []

        let response = await session.resumeAfterFreshGuard { count in
            countdownValues.append(count)
        }

        #expect(response == nil)
        #expect(countdownValues.isEmpty)
        #expect(session.isVoicePaused)
        #expect(session.metrics.attempts.isEmpty)
    }

    @Test("Aura resume accepts near-head guard and rejects closed extended fists")
    func auraResumeRequiresSpatialGuardGeometry() {
        let session = makeCommandSession()
        let guarded = makeVoiceGuardSnapshot()
        let extended = makeVoiceGuardSnapshot(
            leftBody: SIMD3<Float>(-0.2, 0, 0.66),
            rightBody: SIMD3<Float>(0.2, 0, 0.66)
        )

        #expect(session.auraPunch.acceptsVoiceResumeGuard(guarded))
        #expect(!session.auraPunch.acceptsVoiceResumeGuard(extended))
    }

    @Test("Reactive calibration uses conservative fallback guard geometry")
    func reactiveCalibrationCannotResumeFromClosedExtendedFists() {
        let session = makeCommandSession()
        let guarded = makeVoiceGuardSnapshot()
        let extended = makeVoiceGuardSnapshot(
            leftBody: SIMD3<Float>(-0.2, 0, 0.66),
            rightBody: SIMD3<Float>(0.2, 0, 0.66)
        )

        #expect(session.acceptsVoiceResumeGuard(guarded))
        #expect(!session.acceptsVoiceResumeGuard(extended))
    }

    @Test("Reactive resume prefers captured bilateral guard positions when available")
    func reactiveResumeUsesCapturedGuardGeometry() {
        let session = makeCommandSession()
        let guarded = makeVoiceGuardSnapshot()
        let captured = [
            BodySide.left: guarded.frame.toBody(guarded.left.fistPosition),
            BodySide.right: guarded.frame.toBody(guarded.right.fistPosition)
        ]
        let displacedButNearHead = makeVoiceGuardSnapshot(
            leftBody: SIMD3<Float>(-0.34, 0.10, 0.25),
            rightBody: SIMD3<Float>(0.34, 0.10, 0.25)
        )

        #expect(session.acceptsVoiceResumeGuard(guarded, capturedGuards: captured))
        #expect(!session.acceptsVoiceResumeGuard(displacedButNearHead, capturedGuards: captured))
    }

    @Test("Resume guard evidence must be fresh finite and from one tracking chain")
    func resumeGuardRejectsBrokenEvidenceChain() {
        let session = makeCommandSession()
        let stale = makeVoiceGuardSnapshot(sampleTime: 19.8, capturedAt: 20)
        let splitChain = makeVoiceGuardSnapshot(rightGeneration: 8)
        let nonfinite = makeVoiceGuardSnapshot(
            leftBody: SIMD3<Float>(.infinity, 0.10, 0.25)
        )

        #expect(!session.acceptsVoiceResumeGuard(stale))
        #expect(!session.acceptsVoiceResumeGuard(splitChain))
        #expect(!session.auraPunch.acceptsVoiceResumeGuard(nonfinite))
    }

    @Test("Accepted next advances the live Aura demo exactly once")
    func acceptedNextAdvancesLiveAuraDemoExactlyOnce() async throws {
        let flow = TrainingFlowCoordinator()
        let session = makeCommandSession()
        flow.navigate(
            to: .experience(.aura(technique: .jab, stance: .orthodox))
        )
        let originalGeneration = session.auraPunch.demoContinuationGeneration
        #expect(
            session.auraPunch.guidedDemoDidBegin(
                at: 2,
                continuationGeneration: originalGeneration
            )
        )
        let target = TrainingSessionCommandTarget(
            flow: flow,
            session: session,
            showControlWindow: {},
            dismissImmersive: {}
        )

        let result = await TrainingCommandExecutor().execute(
            .next,
            issuedFor: target.commandGeneration,
            on: target
        )

        let receipt = try #require(result.receipt)
        #expect(receipt.response == "Moving to demo 3.")
        #expect(session.auraPunch.currentDemoRep == 3)
        #expect(session.auraPunch.demoContinuationGeneration == originalGeneration + 1)
        #expect(
            !session.auraPunch.guidedDemoDidBegin(
                at: 2,
                continuationGeneration: originalGeneration
            )
        )
        #expect(session.auraPunch.currentDemoRep == 3)
    }

    @Test("Results do not advertise unsupported next semantics")
    func resultsRemoveUnsupportedNextCapability() {
        let flow = TrainingFlowCoordinator()
        let session = makeCommandSession()
        flow.navigate(
            to: .experience(.reactive(mode: .air, combination: nil, stance: .orthodox))
        )
        session.startDrill()
        session.metrics.record(
            TargetAttempt(
                id: UUID(),
                spawnTime: Date(timeIntervalSince1970: 1),
                hitTime: Date(timeIntervalSince1970: 1.2),
                result: .hit,
                distanceAtHit: 0.01,
                fistTravelDistance: 0.4,
                estimatedSpeedMetersPerSecond: 2
            )
        )
        session.stopDrill()
        defer { session.hands.stop() }

        let context = flow.voiceCommandContext(session: session)

        #expect(context.state == .results)
        #expect(!context.capabilities.contains(.next))
    }

    @Test("Cancelled Reactive resume countdown cannot mutate or launch training")
    func cancelledReactiveResumeCannotLaunchTraining() async {
        let session = makeCommandSession()
        session.startDrill()
        _ = session.pauseForVoice()
        defer {
            session.stopDrill()
            session.hands.stop()
        }
        let originalGeneration = session.voiceResumeGeneration

        let response = await Task { @MainActor in
            await session.resumeAfterFreshGuard(using: makeVoiceGuardSnapshot()) { _ in
                withUnsafeCurrentTask { task in task?.cancel() }
            }
        }.value

        #expect(response == nil)
        #expect(session.isVoicePaused)
        #expect(session.isTrackingPaused)
        #expect(session.voiceResumeGeneration == originalGeneration + 1)
        #expect(session.activeVoiceResumeGeneration == nil)
    }

    @Test("Cancelled Aura resume countdown cannot mutate or launch training")
    func cancelledAuraResumeCannotLaunchTraining() async {
        let session = makeCommandSession()
        let aura = session.auraPunch
        _ = aura.guidedDemoDidBegin(
            at: 1,
            continuationGeneration: aura.demoContinuationGeneration
        )
        _ = aura.pauseForVoice()
        defer {
            aura.stop()
            session.hands.stop()
        }
        let originalGeneration = aura.voiceResumeGeneration

        let response = await Task { @MainActor in
            await aura.resumeAfterFreshGuard(using: makeVoiceGuardSnapshot()) { _ in
                withUnsafeCurrentTask { task in task?.cancel() }
            }
        }.value

        #expect(response == nil)
        #expect(aura.isVoicePaused)
        #expect(aura.voiceResumeGeneration == originalGeneration + 1)
        #expect(aura.activeVoiceResumeGeneration == nil)
    }

    @Test("A newer Reactive resume supersedes the same-route countdown")
    func reactiveResumeSupersessionLaunchesOnlyNewestContinuation() async {
        let session = makeCommandSession()
        session.startDrill()
        _ = session.pauseForVoice()
        defer {
            session.stopDrill()
            session.hands.stop()
        }
        let originalGeneration = session.voiceResumeGeneration
        var newestResponse: String?
        var newestGeneration: UInt64?

        let staleResponse = await session.resumeAfterFreshGuard(
            using: makeVoiceGuardSnapshot()
        ) { count in
            guard count == 3, newestResponse == nil else { return }
            newestResponse = await session.resumeAfterFreshGuard(
                using: makeVoiceGuardSnapshot(),
                countdown: { _ in }
            )
            newestGeneration = session.voiceResumeGeneration
        }

        #expect(staleResponse == nil)
        #expect(newestResponse != nil)
        #expect(session.voiceResumeGeneration == originalGeneration + 2)
        #expect(session.activeVoiceResumeGeneration == newestGeneration)
    }

    @Test("A newer Aura resume supersedes the same-route countdown")
    func auraResumeSupersessionLaunchesOnlyNewestContinuation() async {
        let session = makeCommandSession()
        let aura = session.auraPunch
        _ = aura.guidedDemoDidBegin(
            at: 1,
            continuationGeneration: aura.demoContinuationGeneration
        )
        _ = aura.pauseForVoice()
        defer {
            aura.stop()
            session.hands.stop()
        }
        let originalGeneration = aura.voiceResumeGeneration
        var newestResponse: String?
        var newestGeneration: UInt64?

        let staleResponse = await aura.resumeAfterFreshGuard(
            using: makeVoiceGuardSnapshot()
        ) { count in
            guard count == 3, newestResponse == nil else { return }
            newestResponse = await aura.resumeAfterFreshGuard(
                using: makeVoiceGuardSnapshot(),
                countdown: { _ in }
            )
            newestGeneration = aura.voiceResumeGeneration
        }

        #expect(staleResponse == nil)
        #expect(newestResponse != nil)
        #expect(aura.voiceResumeGeneration == originalGeneration + 2)
        #expect(aura.activeVoiceResumeGeneration == newestGeneration)
    }

    @Test("Serialized shutdown reports readiness failure without closing immersion")
    func shutdownOutcomePreservesVisibleEndOnReadinessFailure() async {
        let flow = TrainingFlowCoordinator(controlWindowReadiness: { false })
        let session = makeCommandSession()
        let selection = TrainingSelection.reactive(
            mode: .air,
            combination: nil,
            stance: .orthodox
        )
        flow.navigate(to: .experience(selection))
        flow.immersiveSceneDidBecomeReady(session: session)
        session.startDrill()
        defer {
            flow.immersiveSceneDidClose(session: session)
            session.hands.stop()
        }
        var showCount = 0
        var dismissCount = 0

        let outcome = await flow.endExperience(
            session: session,
            showControlWindow: { showCount += 1 },
            dismissImmersive: { dismissCount += 1 }
        )

        #expect(outcome == .controlWindowRestorationFailed)
        #expect(flow.route == .experience(selection))
        #expect(flow.transition == .idle)
        #expect(!flow.controlsDisabled)
        #expect(session.isImmersiveSpaceOpen)
        #expect(showCount == 1)
        #expect(dismissCount == 0)
    }

    @Test("Voice end succeeds only after closure and recovers after readiness failure")
    func voiceEndReceiptRequiresActualClosureAndCanRecover() async throws {
        var readinessAttempt = 0
        let flow = TrainingFlowCoordinator(controlWindowReadiness: {
            readinessAttempt += 1
            return readinessAttempt > 1
        })
        let session = makeCommandSession()
        let selection = TrainingSelection.reactive(
            mode: .air,
            combination: nil,
            stance: .orthodox
        )
        flow.navigate(to: .experience(selection))
        flow.immersiveSceneDidBecomeReady(session: session)
        session.startDrill()
        defer {
            session.stopDrill()
            session.hands.stop()
        }
        var showCount = 0
        var dismissCount = 0
        let target = TrainingSessionCommandTarget(
            flow: flow,
            session: session,
            showControlWindow: { showCount += 1 },
            dismissImmersive: { dismissCount += 1 }
        )
        let executor = TrainingCommandExecutor()

        let request = await executor.execute(
            .requestEnd,
            issuedFor: target.commandGeneration,
            on: target
        )
        _ = try #require(request.receipt)
        let firstConfirm = await executor.execute(
            .confirmEnd,
            issuedFor: target.commandGeneration,
            on: target
        )

        #expect(firstConfirm == .rejected(.targetRejected(intent: .confirmEnd)))
        #expect(firstConfirm.receipt == nil)
        #expect(flow.pendingVoiceConfirmation == .endTraining)
        #expect(target.commandContext.state == .awaitingEndConfirmation)
        #expect(target.commandContext.capabilities.contains(.confirmEnd))
        #expect(target.commandContext.capabilities.contains(.cancelEnd))
        #expect(session.isImmersiveSpaceOpen)
        #expect(showCount == 1)
        #expect(dismissCount == 0)

        let secondConfirm = await executor.execute(
            .confirmEnd,
            issuedFor: target.commandGeneration,
            on: target
        )

        let receipt = try #require(secondConfirm.receipt)
        #expect(receipt.response == "Training ended.")
        #expect(flow.pendingVoiceConfirmation == nil)
        #expect(!session.isImmersiveSpaceOpen)
        #expect(showCount == 2)
        #expect(dismissCount == 1)
    }

    @Test("Live progress is derived from the active session counts")
    func liveTargetReportsStateDerivedProgress() async throws {
        let flow = TrainingFlowCoordinator()
        let session = makeCommandSession()
        let selection = TrainingSelection.reactive(
            mode: .air,
            combination: nil,
            stance: .orthodox
        )
        flow.navigate(to: .experience(selection))
        session.startDrill()
        defer {
            session.stopDrill()
            session.hands.stop()
        }
        let target = TrainingSessionCommandTarget(
            flow: flow,
            session: session,
            showControlWindow: {},
            dismissImmersive: {}
        )

        let result = await TrainingCommandExecutor().execute(
            .progress,
            issuedFor: target.commandGeneration,
            on: target
        )

        let receipt = try #require(result.receipt)
        #expect(receipt.response == "Calibration")
    }

    @Test("Ranked time exposes no voice capabilities while route generation remains current")
    func rankedTargetDisablesCustomVoiceAndPause() throws {
        let flow = TrainingFlowCoordinator()
        let session = makeCommandSession()
        let reach = try #require(BilateralReach(left: 0.5, right: 0.5))
        flow.navigate(
            to: .experience(
                .competition(
                    playerID: UUID(),
                    mode: .reactiveStrike,
                    stance: .orthodox,
                    reach: reach
                )
            )
        )
        let target = TrainingSessionCommandTarget(
            flow: flow,
            session: session,
            showControlWindow: {},
            dismissImmersive: {}
        )

        #expect(target.commandContext.state == .ranked)
        #expect(target.commandContext.capabilities.isEmpty)
    }

    @Test("A route change advances command generation and clears confirmation")
    func routeChangeInvalidatesPendingCommands() {
        let flow = TrainingFlowCoordinator()
        let initialGeneration = flow.commandGeneration
        flow.navigate(to: .auraSetup)
        let auraGeneration = flow.commandGeneration
        flow.navigate(
            to: .experience(.aura(technique: .jab, stance: .orthodox))
        )
        #expect(flow.requestEndConfirmation(issuedFor: flow.commandGeneration) != nil)

        flow.navigate(to: .features)

        #expect(auraGeneration > initialGeneration)
        #expect(flow.commandGeneration > auraGeneration)
        #expect(flow.pendingVoiceConfirmation == nil)
    }

    @Test("Stale end request cannot enter confirmation on a replacement route")
    func staleEndRequestCannotMutateFlow() {
        let flow = TrainingFlowCoordinator()
        flow.navigate(
            to: .experience(.aura(technique: .jab, stance: .orthodox))
        )
        let staleGeneration = flow.commandGeneration
        flow.navigate(to: .features)

        let response = flow.requestEndConfirmation(issuedFor: staleGeneration)

        #expect(response == nil)
        #expect(flow.pendingVoiceConfirmation == nil)
        #expect(flow.route == .features)
    }

    @Test("Confirmed voice end uses coordinator shutdown and stops the engine")
    func confirmedEndUsesSerializedFlowShutdown() async {
        let flow = TrainingFlowCoordinator()
        let session = makeCommandSession()
        let selection = TrainingSelection.reactive(
            mode: .air,
            combination: nil,
            stance: .orthodox
        )
        flow.navigate(to: .experience(selection))
        session.startDrill()
        defer {
            session.stopDrill()
            session.hands.stop()
        }
        let generation = flow.commandGeneration
        #expect(flow.requestEndConfirmation(issuedFor: generation) != nil)
        var showCount = 0
        var dismissCount = 0

        let response = await flow.confirmVoiceEnd(
            issuedFor: generation,
            session: session,
            showControlWindow: { showCount += 1 },
            dismissImmersive: { dismissCount += 1 }
        )

        #expect(response != nil)
        #expect(session.phase == .idle)
        #expect(flow.pendingVoiceConfirmation == nil)
        #expect(flow.transition == .idle)
        #expect(showCount == 0)
        #expect(dismissCount == 0)
    }

    private func makeCommandSession() -> ReactiveStrikeSession {
        let audioSystem = SilentCommandAudioSystem()
        let coordinator = TrainingAudioCoordinator(
            backend: audioSystem,
            resources: audioSystem,
            decayWaiter: audioSystem
        )
        return ReactiveStrikeSession(audioCoordinator: coordinator)
    }

    private func makeVoiceGuardSnapshot(
        leftBody: SIMD3<Float> = SIMD3<Float>(-0.12, 0.10, 0.25),
        rightBody: SIMD3<Float> = SIMD3<Float>(0.12, 0.10, 0.25),
        sampleTime: TimeInterval = 19.98,
        capturedAt: TimeInterval = 20,
        rightGeneration: UInt64 = 7
    ) -> VoiceGuardSnapshot {
        let frame = VoiceGuardFrame(
            origin: .zero,
            right: SIMD3<Float>(1, 0, 0),
            up: SIMD3<Float>(0, 1, 0),
            forward: SIMD3<Float>(0, 0, 1),
            headPosition: SIMD3<Float>(0, 0.20, 0.10)
        )
        return VoiceGuardSnapshot(
            trackingIsRunning: true,
            capturedAt: capturedAt,
            generation: 7,
            continuityEpoch: 3,
            frame: frame,
            left: VoiceGuardHandEvidence(
                side: .left,
                fistPosition: frame.toWorld(leftBody),
                fistState: .closed,
                acquisitionTimestamp: sampleTime,
                generation: 7,
                continuityEpoch: 3
            ),
            right: VoiceGuardHandEvidence(
                side: .right,
                fistPosition: frame.toWorld(rightBody),
                fistState: .closed,
                acquisitionTimestamp: sampleTime,
                generation: rightGeneration,
                continuityEpoch: 3
            )
        )
    }

    nonisolated private func requireSendable<T: Sendable>(_: T.Type) {}

}

@MainActor
private final class SilentCommandAudioSystem:
    TrainingAudioBackend,
    TrainingAudioResourceResolving,
    TrainingAudioDecayWaiting {
    var playbackDidFinish: ((TrainingAudioPlaybackHandle) -> Void)?
    var systemEventHandler: ((TrainingAudioSystemEvent) -> Void)?

    func attachScene() throws {}
    func detachScene() {}
    func apply(mix: TrainingAudioMix, fadeDuration: Duration) {}
    func play(_ request: TrainingAudioPlaybackRequest) -> TrainingAudioPlaybackHandle? { nil }
    func stop(_ handle: TrainingAudioPlaybackHandle) {}
    func stop(channels: Set<TrainingAudioChannel>) {}
    func stopAll() {}
    func beginVoiceCapture() throws {}
    func endVoiceCapture() {}
    func recoverPlaybackSession() throws {}
    func mediaServicesWereReset() throws {}
    func url(for resource: TrainingAudioResourceID) -> URL? { nil }
    func wait(for duration: Duration) async throws {}
}

@MainActor
final class TrainingCommandTargetFixture: TrainingCommandTarget {
    let commandGeneration: UInt64
    var commandContext: VoiceCommandContext
    var executedIntents: [VoiceIntent] = []
    var isPaused = false
    var demoRate: TrainingDemoRate = .normal
    var pendingConfirmation: TrainingCommandConfirmation?
    var didEndTraining = false
    var didResetParticipant = false
    var rejectNextAction = false

    init(
        state: VoiceCommandState,
        capabilities: Set<VoiceCommandCapability>,
        generation: UInt64 = 41,
        pendingConfirmation: TrainingCommandConfirmation? = nil
    ) {
        commandGeneration = generation
        commandContext = VoiceCommandContext(state: state, capabilities: capabilities)
        self.pendingConfirmation = pendingConfirmation
            ?? (state == .awaitingEndConfirmation ? .endTraining : nil)
    }

    func pauseForVoice() -> String? {
        accept(.pause) { isPaused = true }
    }

    func resumeAfterFreshGuard() async -> String? {
        accept(.resume) { isPaused = false }
    }

    func repeatDemo() -> String? {
        accept(.repeatDemo)
    }

    func setDemoRate(_ rate: TrainingDemoRate) -> String? {
        let intent: VoiceIntent = switch rate {
        case .slower: .slower
        case .normal: .normalPace
        case .faster: .faster
        }
        return accept(intent) { demoRate = rate }
    }

    func advance() -> String? { accept(.next) }
    func requestCorrection() -> String? { accept(.correction) }
    func requestGuardExplanation() -> String? { accept(.guardExplanation) }
    func requestTargetHelp() -> String? { accept(.targetHelp) }
    func requestProgress() -> String? { accept(.progress) }
    func requestHelp() -> String? { accept(.help) }
    func requestScore() -> String? { accept(.score) }
    func requestWhy() -> String? { accept(.why) }
    func requestLeaderboard() -> String? { accept(.leaderboard) }

    func requestEndConfirmation() -> String? {
        accept(.requestEnd) { pendingConfirmation = .endTraining }
    }

    func confirmEnd() async -> String? {
        guard pendingConfirmation == .endTraining else { return nil }
        return accept(.confirmEnd) {
            pendingConfirmation = nil
            didEndTraining = true
        }
    }

    func cancelEndConfirmation() -> String? {
        guard pendingConfirmation == .endTraining else { return nil }
        return accept(.cancelEnd) { pendingConfirmation = nil }
    }

    func requestParticipantHandoffConfirmation() -> String? {
        accept(.requestParticipantHandoff) {
            pendingConfirmation = .participantHandoff
        }
    }

    private func accept(_ intent: VoiceIntent, mutation: () -> Void = {}) -> String? {
        guard !rejectNextAction else {
            rejectNextAction = false
            return nil
        }
        mutation()
        executedIntents.append(intent)
        return "Executed \(intent.rawValue)"
    }
}

nonisolated struct TrainingCommandMatrixCase: Sendable, CustomTestStringConvertible {
    let intent: VoiceIntent
    let state: VoiceCommandState
    let isAllowed: Bool

    var testDescription: String { "\(intent.rawValue)-\(state.rawValue)" }

    static let approvedStates: [VoiceIntent: Set<VoiceCommandState>] = [
        .pause: [.learn, .baseline, .correction, .retest, .transfer],
        .resume: [.trackingPaused],
        .requestEnd: [.learn, .baseline, .correction, .retest, .transfer, .results, .trackingPaused],
        .confirmEnd: [.awaitingEndConfirmation],
        .cancelEnd: [.awaitingEndConfirmation],
        .repeatDemo: [.learn, .correction],
        .slower: [.learn, .correction],
        .normalPace: [.learn, .correction],
        .faster: [.learn, .correction],
        .next: [.learn, .correction, .results],
        .correction: [.baseline, .correction, .retest, .results],
        .guardExplanation: [.learn, .baseline, .correction, .retest, .transfer, .trackingPaused],
        .targetHelp: [.learn, .baseline, .correction, .retest, .transfer],
        .progress: [.learn, .baseline, .correction, .retest, .transfer, .results],
        .help: [.idle, .learn, .baseline, .correction, .retest, .transfer, .results, .trackingPaused, .awaitingEndConfirmation],
        .score: [.results],
        .why: [.correction, .retest, .results],
        .leaderboard: [.idle, .results],
        .requestParticipantHandoff: [.results]
    ]

    static let all: [Self] = VoiceIntent.allCases.flatMap { intent in
        VoiceCommandState.allCases.map { state in
            Self(
                intent: intent,
                state: state,
                isAllowed: approvedStates[intent, default: []].contains(state)
            )
        }
    }
}
