import AVFoundation
import Foundation
import Testing
@testable import BoxingCoach

@Suite("Semantic training audio coordination")
@MainActor
struct TrainingAudioCoordinatorTests {
    @Test("Foreground cues preempt in safety-first priority order")
    func foregroundCuePriorityIsDeterministic() async {
        let backend = RecordingTrainingAudioBackend()
        let resources = StubTrainingAudioResources(available: [
            .coach(.resultsGood),
            .coach(.guardUp),
            .coach(.qaWhatFix),
            .coach(.pauseAck)
        ])
        let coordinator = makeCoordinator(backend: backend, resources: resources)

        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.experienceDidEnter(.learn))
        #expect(await coordinator.handle(.coachCue(.init(
            kind: .result,
            clip: .resultsGood,
            caption: "Result"
        ))) == .handled)
        #expect(await coordinator.handle(.coachCue(.init(
            kind: .phaseInstruction,
            clip: .guardUp,
            caption: "Guard up"
        ))) == .handled)
        #expect(await coordinator.handle(.coachCue(.init(
            kind: .voiceResponse,
            clip: .qaWhatFix,
            caption: "Coach response"
        ))) == .handled)
        #expect(await coordinator.handle(.coachCue(.init(
            kind: .safety,
            clip: .pauseAck,
            caption: "Stop now"
        ))) == .handled)

        let suppressed = await coordinator.handle(.coachCue(.init(
            kind: .result,
            clip: .resultsGood,
            caption: "Lower priority result"
        )))

        #expect(suppressed == .suppressed(by: .safety))
        #expect(backend.playedResources == [
            .coach(.resultsGood),
            .coach(.guardUp),
            .coach(.qaWhatFix),
            .coach(.pauseAck)
        ])
        #expect(backend.stoppedHandles.count == 3)
        #expect(coordinator.presentation.caption == "Stop now")
        #expect(coordinator.presentation.activePriority == .safety)
        #expect(coordinator.presentation.mix.ambience == .decibels(-40))
        #expect(coordinator.presentation.mix.crowd == .muted)
        #expect(coordinator.presentation.mix.impact == .muted)
    }

    @Test(
        "Every training stage applies the approved ambience and crowd gains",
        arguments: TrainingAudioStageMixCase.all
    )
    func stageMixMatchesApprovedTargets(testCase: TrainingAudioStageMixCase) async {
        let backend = RecordingTrainingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources()
        )
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))

        await coordinator.handle(.experienceDidEnter(testCase.stage))

        #expect(coordinator.presentation.stage == testCase.stage)
        #expect(coordinator.presentation.mix.ambience == testCase.ambience)
        #expect(coordinator.presentation.mix.crowd == testCase.crowd)
    }

    @Test("All live mix transitions fade between 150 and 300 milliseconds")
    func liveMixTransitionsUseComfortableFades() async {
        let journal = TrainingAudioTestJournal()
        let backend = RecordingTrainingAudioBackend(journal: journal)
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources(),
            waiter: ImmediateTrainingAudioWaiter(journal: journal)
        )

        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.experienceDidEnter(.compete))
        await coordinator.handle(.trackingDidPause(.handsUnavailable))
        await coordinator.handle(.trackingDidResume)
        await coordinator.handle(.voiceCaptureDidBegin(origin: .immersiveSpace))
        await coordinator.handle(.voiceCaptureDidEnd)

        let fades = backend.commands.compactMap { command -> Duration? in
            guard case let .applyMix(_, fadeDuration) = command else { return nil }
            return fadeDuration
        }
        #expect(fades.isEmpty == false)
        #expect(fades.allSatisfy { $0 >= .milliseconds(150) && $0 <= .milliseconds(300) })
    }

    @Test("Capture starts only after playback stops, ducking, and acoustic decay")
    func captureFocusPreventsSelfTranscription() async {
        let journal = TrainingAudioTestJournal()
        let backend = RecordingTrainingAudioBackend(journal: journal)
        let resources = StubTrainingAudioResources(available: [
            .coach(.guardUp),
            .coach(.qaWhatFix)
        ])
        let coordinator = makeCoordinator(
            backend: backend,
            resources: resources,
            waiter: ImmediateTrainingAudioWaiter(journal: journal)
        )
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.coachCue(.init(
            kind: .phaseInstruction,
            clip: .guardUp,
            caption: "Guard up"
        )))
        journal.removeAll()

        let captureOutcome = await coordinator.handle(.voiceCaptureDidBegin(origin: .immersiveSpace))

        #expect(captureOutcome == .captureReady)
        #expect(journal.entries.prefix(4) == [
            .stopChannels([.coach, .impact, .status]),
            .applyMix,
            .wait(.milliseconds(200)),
            .beginCapture
        ])
        #expect(coordinator.presentation.isCapturing)
        #expect(coordinator.presentation.mix.ambience == .decibels(-40))
        #expect(coordinator.presentation.mix.impact == .muted)

        let deferred = await coordinator.handle(.coachCue(.init(
            kind: .voiceResponse,
            clip: .qaWhatFix,
            caption: "Keep the guard close to your cheek."
        )))
        #expect(deferred == .deferredUntilCaptureEnds)
        #expect(backend.playedResources.contains(.coach(.qaWhatFix)) == false)
        #expect(coordinator.presentation.caption == "Keep the guard close to your cheek.")

        await coordinator.handle(.voiceCaptureDidEnd)

        let endIndex = journal.entries.firstIndex(of: .endCapture)
        let responseIndex = journal.entries.firstIndex(of: .play(.coach(.qaWhatFix)))
        #expect(endIndex != nil)
        #expect(responseIndex != nil)
        if let endIndex, let responseIndex {
            #expect(endIndex < responseIndex)
        }
        #expect(coordinator.presentation.isCapturing == false)
    }

    @Test("Deferred voice response survives failed recovery and waits for explicit success")
    func deferredResponseSurvivesFailedPlaybackRecovery() async {
        let backend = RecordingTrainingAudioBackend()
        let resources = StubTrainingAudioResources(available: [.coach(.qaWhatFix)])
        let coordinator = makeCoordinator(backend: backend, resources: resources)
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        #expect(await coordinator.handle(.voiceCaptureDidBegin(origin: .immersiveSpace)) == .captureReady)
        #expect(await coordinator.handle(.coachCue(.init(
            kind: .voiceResponse,
            clip: .qaWhatFix,
            caption: "Keep the guard close to your cheek."
        ))) == .deferredUntilCaptureEnds)
        backend.recoverPlaybackFailuresRemaining = 1

        let failedRecovery = await coordinator.handle(.voiceCaptureDidEnd)

        #expect(failedRecovery == .backendUnavailable)
        #expect(coordinator.presentation.requiresExplicitRecovery)
        #expect(backend.playedResources.contains(.coach(.qaWhatFix)) == false)

        let successfulRecovery = await coordinator.handle(.audioRecoveryConfirmed)

        #expect(successfulRecovery == .handled)
        #expect(coordinator.presentation.requiresExplicitRecovery == false)
        #expect(backend.playedResources == [.coach(.qaWhatFix)])
    }

    @Test("Training start clears custom voice audio without weakening safety priority")
    func trainingStartCannotCarryVoiceResponsesIntoTraining() async throws {
        let playingBackend = RecordingTrainingAudioBackend()
        let playingCoordinator = makeCoordinator(
            backend: playingBackend,
            resources: StubTrainingAudioResources(available: [
                .coach(.qaWhatFix),
                .coach(.guardUp)
            ])
        )
        await playingCoordinator.handle(.sceneDidAttach(.immersiveSpace))
        #expect(await playingCoordinator.handle(.coachCue(.init(
            kind: .voiceResponse,
            clip: .qaWhatFix,
            caption: "Coach response"
        ))) == .handled)
        let playingResponseHandles: [TrainingAudioPlaybackHandle] = playingBackend.commands.compactMap { command in
            guard case let .play(handle, resource) = command,
                  resource == .coach(.qaWhatFix) else { return nil }
            return handle
        }
        let playingResponseHandle = try #require(playingResponseHandles.last)

        #expect(await playingCoordinator.handle(.trainingWillBegin) == .handled)
        #expect(playingBackend.stoppedHandles.contains(playingResponseHandle))
        #expect(await playingCoordinator.handle(.coachCue(.init(
            kind: .phaseInstruction,
            clip: .guardUp,
            caption: "Guard up"
        ))) == .handled)

        let recoveryBackend = RecordingTrainingAudioBackend()
        let recoveryCoordinator = makeCoordinator(
            backend: recoveryBackend,
            resources: StubTrainingAudioResources(available: [
                .coach(.qaWhatFix),
                .coach(.guardUp)
            ])
        )
        await recoveryCoordinator.handle(.sceneDidAttach(.immersiveSpace))
        #expect(await recoveryCoordinator.handle(.voiceCaptureDidBegin(
            origin: .immersiveSpace
        )) == .captureReady)
        #expect(await recoveryCoordinator.handle(.coachCue(.init(
            kind: .voiceResponse,
            clip: .qaWhatFix,
            caption: "Deferred response"
        ))) == .deferredUntilCaptureEnds)
        recoveryBackend.recoverPlaybackFailuresRemaining = 1
        #expect(await recoveryCoordinator.handle(.voiceCaptureDidEnd) == .backendUnavailable)
        #expect(recoveryCoordinator.presentation.requiresExplicitRecovery)

        #expect(await recoveryCoordinator.handle(.trainingWillBegin) == .handled)
        #expect(recoveryCoordinator.presentation.requiresExplicitRecovery == false)
        #expect(await recoveryCoordinator.handle(.audioRecoveryConfirmed) == .handled)
        #expect(recoveryBackend.playedResources.contains(.coach(.qaWhatFix)) == false)
        #expect(await recoveryCoordinator.handle(.coachCue(.init(
            kind: .phaseInstruction,
            clip: .guardUp,
            caption: "Guard up"
        ))) == .handled)

        let safetyBackend = RecordingTrainingAudioBackend()
        let safetyCoordinator = makeCoordinator(
            backend: safetyBackend,
            resources: StubTrainingAudioResources(available: [
                .coach(.pauseAck),
                .coach(.guardUp)
            ])
        )
        await safetyCoordinator.handle(.sceneDidAttach(.immersiveSpace))
        #expect(await safetyCoordinator.handle(.coachCue(.init(
            kind: .safety,
            clip: .pauseAck,
            caption: "Stop now."
        ))) == .handled)
        let safetyHandles: [TrainingAudioPlaybackHandle] = safetyBackend.commands.compactMap { command in
            guard case let .play(handle, resource) = command,
                  resource == .coach(.pauseAck) else { return nil }
            return handle
        }
        let safetyHandle = try #require(safetyHandles.last)

        #expect(await safetyCoordinator.handle(.trainingWillBegin) == .handled)
        #expect(safetyBackend.stoppedHandles.contains(safetyHandle) == false)
        #expect(safetyCoordinator.presentation.activePriority == .safety)
        #expect(safetyCoordinator.presentation.caption == "Stop now.")
        #expect(await safetyCoordinator.handle(.coachCue(.init(
            kind: .phaseInstruction,
            clip: .guardUp,
            caption: "Guard up"
        ))) == .suppressed(by: .safety))
    }

    @Test("Voice responses arriving during acoustic decay wait until capture has ended")
    func cueDuringCapturePreparationCannotPlayIntoMicrophone() async {
        let backend = RecordingTrainingAudioBackend()
        let waiter = ControlledTrainingAudioWaiter()
        let resources = StubTrainingAudioResources(available: [.coach(.qaWhatFix)])
        let coordinator = makeCoordinator(
            backend: backend,
            resources: resources,
            waiter: waiter
        )
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))

        let captureTask = Task { @MainActor in
            await coordinator.handle(.voiceCaptureDidBegin(origin: .immersiveSpace))
        }
        await waiter.waitUntilSuspended()

        let cueOutcome = await coordinator.handle(.coachCue(.init(
            kind: .voiceResponse,
            clip: .qaWhatFix,
            caption: "Keep the guard close to your cheek."
        )))

        #expect(cueOutcome == .deferredUntilCaptureEnds)
        #expect(backend.playedResources.contains(.coach(.qaWhatFix)) == false)

        waiter.resume()
        #expect(await captureTask.value == .captureReady)
        #expect(backend.playedResources.contains(.coach(.qaWhatFix)) == false)

        await coordinator.handle(.voiceCaptureDidEnd)
        #expect(backend.playedResources.contains(.coach(.qaWhatFix)))
    }

    @Test("Duplicate capture begin shares one preparation and one backend transition")
    func duplicateCaptureBeginIsIdempotent() async {
        let backend = RecordingTrainingAudioBackend()
        let waiter = ControlledTrainingAudioWaiter()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources(),
            waiter: waiter
        )
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))

        let first = Task { @MainActor in
            await coordinator.handle(.voiceCaptureDidBegin(origin: .immersiveSpace))
        }
        await waiter.waitUntilSuspended()

        var secondEntered = false
        let second = Task { @MainActor in
            secondEntered = true
            return await coordinator.handle(.voiceCaptureDidBegin(origin: .immersiveSpace))
        }
        while !secondEntered {
            await Task.yield()
        }
        await Task.yield()

        waiter.resumeAll()
        #expect(await first.value == .captureReady)
        #expect(await second.value == .captureReady)
        #expect(waiter.waitCallCount == 1)
        #expect(backend.commands.filter { $0 == .beginCapture }.count == 1)
    }

    @Test("Cancelling preparation restores playback even when the decay waiter ignores cancellation")
    func cancelledPreparationCannotLeaveCoordinatorStuck() async {
        let backend = RecordingTrainingAudioBackend()
        let waiter = ControlledTrainingAudioWaiter()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources(),
            waiter: waiter
        )
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))

        let preparation = Task { @MainActor in
            await coordinator.handle(.voiceCaptureDidBegin(origin: .immersiveSpace))
        }
        await waiter.waitUntilSuspended()
        preparation.cancel()
        waiter.resume()

        #expect(await preparation.value == .staleGeneration)
        #expect(coordinator.presentation.status == .ready)
        #expect(coordinator.presentation.isCapturing == false)
        #expect(coordinator.presentation.mix == .stage(.fit))
    }

    @Test("Safety cues preempt microphone preparation and active capture")
    func safetyCueAlwaysPreemptsVoiceCapture() async {
        let preparingBackend = RecordingTrainingAudioBackend()
        let waiter = ControlledTrainingAudioWaiter()
        let resources = StubTrainingAudioResources(available: [.coach(.pauseAck)])
        let preparingCoordinator = makeCoordinator(
            backend: preparingBackend,
            resources: resources,
            waiter: waiter
        )
        await preparingCoordinator.handle(.sceneDidAttach(.immersiveSpace))

        let preparation = Task { @MainActor in
            await preparingCoordinator.handle(.voiceCaptureDidBegin(origin: .immersiveSpace))
        }
        await waiter.waitUntilSuspended()

        let preparingSafety = await preparingCoordinator.handle(.coachCue(.init(
            kind: .safety,
            clip: .pauseAck,
            caption: "Stop now"
        )))

        #expect(preparingSafety == .handled)
        #expect(preparingBackend.playedResources == [.coach(.pauseAck)])
        #expect(preparingCoordinator.presentation.caption == "Stop now")
        waiter.resume()
        #expect(await preparation.value == .staleGeneration)
        #expect(preparingBackend.commands.contains(.beginCapture) == false)

        let capturingBackend = RecordingTrainingAudioBackend()
        let capturingCoordinator = makeCoordinator(
            backend: capturingBackend,
            resources: resources
        )
        await capturingCoordinator.handle(.sceneDidAttach(.immersiveSpace))
        #expect(await capturingCoordinator.handle(.voiceCaptureDidBegin(origin: .immersiveSpace)) == .captureReady)

        let capturingSafety = await capturingCoordinator.handle(.coachCue(.init(
            kind: .safety,
            clip: .pauseAck,
            caption: "Stop now"
        )))

        #expect(capturingSafety == .handled)
        #expect(capturingCoordinator.presentation.isCapturing == false)
        #expect(capturingCoordinator.presentation.caption == "Stop now")
        #expect(capturingBackend.commands.contains(.endCapture))
        #expect(capturingBackend.commands.contains(.recoverPlaybackSession))
        #expect(capturingBackend.playedResources == [.coach(.pauseAck)])
    }

    @Test("Failed safety playback recovery keeps Resume Audio visible")
    func safetyRecoveryFailureRequiresExplicitRecovery() async {
        let backend = RecordingTrainingAudioBackend()
        backend.recoverPlaybackFailuresRemaining = 1
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources(available: [.coach(.pauseAck)])
        )
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        #expect(await coordinator.handle(.voiceCaptureDidBegin(origin: .immersiveSpace)) == .captureReady)

        let outcome = coordinator.handleImmediately(.coachCue(.init(
            kind: .safety,
            clip: .pauseAck,
            caption: "Stop now."
        )))
        let visibility = ImmersiveAudioControlVisibility(
            allowsVoiceCoaching: false,
            requiresExplicitRecovery: coordinator.presentation.requiresExplicitRecovery
        )

        #expect(outcome == .backendUnavailable)
        #expect(coordinator.presentation.isCapturing == false)
        #expect(coordinator.presentation.status == .awaitingExplicitRecovery)
        #expect(coordinator.presentation.requiresExplicitRecovery)
        #expect(coordinator.presentation.caption == "Stop now.")
        #expect(visibility.showsPushToTalk == false)
        #expect(visibility.showsRecoveryAction)

        #expect(coordinator.handleImmediately(.audioRecoveryConfirmed) == .handled)
        #expect(coordinator.presentation.requiresExplicitRecovery == false)
        #expect(coordinator.presentation.status == .ready)
    }

    @Test("Tracking and explicit audio recovery suppress narration without replacing safety captions")
    func pausedSafetyStatesBlockOrdinaryNarration() async {
        let backend = RecordingTrainingAudioBackend()
        let resources = StubTrainingAudioResources(available: [
            .coach(.guardUp),
            .coach(.qaWhatFix),
            .trackingLost
        ])
        let coordinator = makeCoordinator(backend: backend, resources: resources)
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.trackingDidPause(.handsUnavailable))
        let trackingCaption = coordinator.presentation.caption

        let phaseOutcome = await coordinator.handle(.coachCue(.init(
            kind: .phaseInstruction,
            clip: .guardUp,
            caption: "Guard up"
        )))
        let voiceOutcome = await coordinator.handle(.coachCue(.init(
            kind: .voiceResponse,
            clip: .qaWhatFix,
            caption: "Coach response"
        )))

        #expect(phaseOutcome == .suppressed(by: .safety))
        #expect(voiceOutcome == .suppressed(by: .safety))
        #expect(coordinator.presentation.caption == trackingCaption)
        #expect(backend.playedResources.contains(.coach(.guardUp)) == false)
        #expect(backend.playedResources.contains(.coach(.qaWhatFix)) == false)

        await coordinator.handle(.experienceDidEnter(.compete))
        await coordinator.handle(.targetDidAppear(position: .init(0, 1, -0.5)))
        await coordinator.handle(.validatedImpact(position: .init(0, 1, -0.5), quality: .clean))
        #expect(coordinator.presentation.caption == trackingCaption)

        await coordinator.handle(.trackingDidResume)
        await coordinator.handle(.audioSystemEvent(.routeChanged))
        let recoveryCaption = coordinator.presentation.caption
        let recoveryOutcome = await coordinator.handle(.coachCue(.init(
            kind: .phaseInstruction,
            clip: .guardUp,
            caption: "Guard up"
        )))

        #expect(recoveryOutcome == .suppressed(by: .safety))
        #expect(coordinator.presentation.caption == recoveryCaption)
        #expect(backend.playedResources.contains(.coach(.guardUp)) == false)
    }

    @Test("Tracking status prompts retain safety priority until playback finishes")
    func trackingStatusPromptBlocksLowerPriorityCoachCue() async throws {
        let backend = RecordingTrainingAudioBackend()
        let resources = StubTrainingAudioResources(available: [
            .trackingLost,
            .trackingRestored,
            .coach(.guardUp)
        ])
        let coordinator = makeCoordinator(backend: backend, resources: resources)
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.trackingDidPause(.handsUnavailable))
        await coordinator.handle(.trackingDidResume)
        let safetyCaption = coordinator.presentation.caption

        #expect(await coordinator.handle(.voiceCaptureDidBegin(origin: .immersiveSpace)) == .suppressed(by: .safety))
        #expect(backend.commands.contains(.beginCapture) == false)

        let suppressed = await coordinator.handle(.coachCue(.init(
            kind: .phaseInstruction,
            clip: .guardUp,
            caption: "Guard up"
        )))

        #expect(suppressed == .suppressed(by: .safety))
        #expect(coordinator.presentation.caption == safetyCaption)

        let statusHandles: [TrainingAudioPlaybackHandle] = backend.commands.compactMap { command in
            guard case let .play(handle, resource) = command,
                  resource == .trackingRestored else { return nil }
            return handle
        }
        let statusHandle = try #require(statusHandles.last)
        backend.playbackDidFinish?(statusHandle)

        #expect(await coordinator.handle(.coachCue(.init(
            kind: .phaseInstruction,
            clip: .guardUp,
            caption: "Guard up"
        ))) == .handled)
    }

    @Test("Tracking loss mutes crowd and scoring effects until explicit tracking resume")
    func trackingLossAppliesSafetyMix() async {
        let backend = RecordingTrainingAudioBackend()
        let resources = StubTrainingAudioResources(available: [
            .gymAmbience,
            .competitionCrowd,
            .cleanImpact1
        ])
        let coordinator = makeCoordinator(backend: backend, resources: resources)
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.experienceDidEnter(.compete))
        await coordinator.handle(.validatedImpact(position: .init(0.1, 1.2, -0.6), quality: .clean))

        await coordinator.handle(.trackingDidPause(.handsUnavailable))

        #expect(coordinator.presentation.status == .trackingPaused)
        #expect(coordinator.presentation.caption == "Tracking paused. Keep your space clear and bring both hands into view.")
        #expect(coordinator.presentation.mix.ambience == .decibels(-38))
        #expect(coordinator.presentation.mix.crowd == .muted)
        #expect(coordinator.presentation.mix.impact == .muted)
        #expect(coordinator.activeImpactVoiceCount == 0)

        await coordinator.handle(.trackingDidResume)

        #expect(coordinator.presentation.status == .ready)
        #expect(coordinator.presentation.mix.ambience == .decibels(-28))
        #expect(coordinator.presentation.mix.crowd == .decibels(-24))
    }

    @Test("Interruption recovery never auto-resumes training audio")
    func interruptionRequiresExplicitRecovery() async {
        let backend = RecordingTrainingAudioBackend()
        let resources = StubTrainingAudioResources(available: [.gymAmbience, .competitionCrowd])
        let coordinator = makeCoordinator(backend: backend, resources: resources)
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.experienceDidEnter(.compete))
        let playsBeforeInterruption = backend.playedResources.count

        await coordinator.handle(.audioSystemEvent(.interruptionBegan))
        await coordinator.handle(.audioSystemEvent(.interruptionEnded))

        #expect(coordinator.presentation.status == .awaitingExplicitRecovery)
        #expect(coordinator.presentation.requiresExplicitRecovery)
        #expect(backend.playedResources.count == playsBeforeInterruption)
        #expect(backend.commands.contains(.recoverPlaybackSession))
        #expect(backend.commands.contains(.stopAll) == false)

        await coordinator.handle(.audioRecoveryConfirmed)

        #expect(coordinator.presentation.status == .ready)
        #expect(coordinator.presentation.requiresExplicitRecovery == false)
        #expect(backend.playedResources.count == playsBeforeInterruption)
    }

    @Test("Route changes and media resets invalidate playback and require an explicit recovery")
    func routeAndMediaLossAreGenerationSafe() async {
        let backend = RecordingTrainingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources(available: [.gymAmbience])
        )
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        let initialGeneration = coordinator.generation

        await coordinator.handle(.audioSystemEvent(.routeChanged))
        let routeGeneration = coordinator.generation
        #expect(routeGeneration > initialGeneration)
        #expect(coordinator.presentation.requiresExplicitRecovery)
        #expect(backend.commands.contains(.stopAll) == false)
        #expect(backend.playedResources == [.gymAmbience])

        await coordinator.handle(.audioRecoveryConfirmed)
        #expect(backend.playedResources == [.gymAmbience])
        await coordinator.handle(.audioSystemEvent(.mediaServicesWereReset))

        #expect(coordinator.generation > routeGeneration)
        #expect(coordinator.presentation.requiresExplicitRecovery)
        #expect(backend.commands.contains(.stopAll))
        #expect(backend.commands.contains(.mediaServicesWereReset))
    }

    @Test("Explicit recovery remains available when competition hides voice coaching")
    func competitionKeepsAudioRecoveryDiscoverableWithoutRankedCoaching() {
        let backend = RecordingTrainingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources()
        )
        let session = ReactiveStrikeSession(
            feedbackGenerator: MockFeedbackGenerator(),
            audioCoordinator: coordinator
        )
        session.controlWindowDidOpen()
        coordinator.handleImmediately(.audioSystemEvent(.routeChanged))

        let visibility = ImmersiveAudioControlVisibility(
            allowsVoiceCoaching: false,
            requiresExplicitRecovery: coordinator.presentation.requiresExplicitRecovery
        )

        #expect(visibility.showsRecoveryAction)
        #expect(visibility.showsPushToTalk == false)
        #expect(session.resumeAudio() == .handled)
        #expect(coordinator.presentation.requiresExplicitRecovery == false)
        #expect(backend.commands.contains(.recoverPlaybackSession))
    }

    @Test("Missing resources preserve captions and state before lookup")
    func missingResourcesKeepVisibleEquivalent() async {
        let backend = RecordingTrainingAudioBackend()
        let resources = StubTrainingAudioResources()
        let coordinator = makeCoordinator(backend: backend, resources: resources)
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        resources.onResolve = { _ in
            #expect(coordinator.presentation.caption == "Visual coaching remains available.")
        }

        let outcome = await coordinator.handle(.coachCue(.init(
            kind: .phaseInstruction,
            clip: .guardUp,
            caption: "Visual coaching remains available."
        )))

        #expect(outcome == .missingResource(.coach(.guardUp)))
        #expect(coordinator.presentation.caption == "Visual coaching remains available.")
        #expect(coordinator.presentation.activePriority == nil)
        #expect(backend.playedResources.isEmpty)

        resources.onResolve = { _ in
            #expect(coordinator.presentation.caption == "Clean impact.")
        }
        let impactOutcome = await coordinator.handle(.validatedImpact(
            position: .init(0, 1, -0.5),
            quality: .clean
        ))
        #expect(impactOutcome == .missingResource(.cleanImpact1))
        #expect(coordinator.presentation.caption == "Clean impact.")
    }

    @Test("Scene attachment and teardown are idempotent")
    func sceneLifecycleIsExactlyOnce() async {
        let backend = RecordingTrainingAudioBackend()
        let coordinator = makeCoordinator(backend: backend, resources: StubTrainingAudioResources())

        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.sceneDidDetach(.immersiveSpace))
        await coordinator.handle(.sceneDidDetach(.immersiveSpace))

        #expect(backend.commands.filter { $0 == .attachScene }.count == 1)
        #expect(backend.commands.filter { $0 == .detachScene }.count == 1)
        #expect(coordinator.presentation.status == .detached)
    }

    @Test("Window voice remains available while audio ownership hands off to immersion")
    func windowAndImmersiveScenesHoldIndependentAudioLeases() async {
        let backend = RecordingTrainingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources()
        )
        let speechClient = RecordingSpeechRecognitionClient()
        let session = ReactiveStrikeSession(
            feedbackGenerator: MockFeedbackGenerator(),
            audioCoordinator: coordinator,
            speechClient: speechClient
        )

        session.controlWindowDidOpen()
        #expect(await coordinator.handle(.voiceCaptureDidBegin(
            origin: .controlWindow
        )) == .captureReady)
        #expect(await coordinator.handle(.voiceCaptureDidEnd) == .handled)

        session.immersiveSpaceDidOpen()
        session.controlWindowDidClose()
        #expect(await coordinator.handle(.voiceCaptureDidBegin(
            origin: .immersiveSpace
        )) == .captureReady)
        #expect(await coordinator.handle(.voiceCaptureDidEnd) == .handled)

        session.controlWindowDidOpen()
        session.voiceCoach.beginPushToTalk(origin: .controlWindow)
        await speechClient.waitForStartCount(1)
        session.immersiveSpaceDidClose()

        #expect(session.voiceCoach.isListening)
        #expect(session.voiceCoach.isCaptureReady)
        #expect(speechClient.isRecording)
        session.controlWindowDidClose()

        #expect(await coordinator.handle(.voiceCaptureDidBegin(
            origin: .controlWindow
        )) == .ignoredWhileDetached)
        #expect(session.voiceCoach.isListening == false)
        #expect(speechClient.isRecording == false)
        #expect(backend.commands.filter { $0 == .attachScene }.count == 1)
        #expect(backend.commands.filter { $0 == .detachScene }.count == 1)
    }

    @Test("The live immersive finalizer preserves capture owned by the restored window")
    func immersiveFinalizerPreservesRestoredWindowCapture() async {
        let backend = RecordingTrainingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources()
        )
        let speechClient = RecordingSpeechRecognitionClient()
        let session = ReactiveStrikeSession(
            feedbackGenerator: MockFeedbackGenerator(),
            audioCoordinator: coordinator,
            speechClient: speechClient
        )
        let flow = TrainingFlowCoordinator()
        flow.immersiveSceneDidBecomeReady(session: session)
        session.controlWindowDidOpen()
        session.voiceCoach.beginPushToTalk(origin: .controlWindow)
        await speechClient.waitForStartCount(1)

        flow.immersiveSceneDidClose(session: session)

        #expect(session.isImmersiveSpaceOpen == false)
        #expect(session.voiceCoach.isListening)
        #expect(session.voiceCoach.isCaptureReady)
        #expect(speechClient.isRecording)
        #expect(coordinator.presentation.status == .capturing)
        #expect(backend.commands.filter { $0 == .detachScene }.isEmpty)

        session.controlWindowDidClose()
    }

    @Test("The live immersive finalizer revokes capture owned by the disappearing immersion")
    func immersiveFinalizerRevokesImmersiveCaptureAfterWindowRestores() async {
        let backend = RecordingTrainingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources()
        )
        let speechClient = RecordingSpeechRecognitionClient()
        let session = ReactiveStrikeSession(
            feedbackGenerator: MockFeedbackGenerator(),
            audioCoordinator: coordinator,
            speechClient: speechClient
        )
        let flow = TrainingFlowCoordinator()
        flow.immersiveSceneDidBecomeReady(session: session)
        session.voiceCoach.beginPushToTalk(origin: .immersiveSpace)
        await speechClient.waitForStartCount(1)

        session.controlWindowDidOpen()
        flow.immersiveSceneDidClose(session: session)

        #expect(session.isImmersiveSpaceOpen == false)
        #expect(session.voiceCoach.isListening == false)
        #expect(session.voiceCoach.isCaptureReady == false)
        #expect(speechClient.isRecording == false)
        #expect(coordinator.presentation.isCapturing == false)
        #expect(backend.commands.filter { $0 == .endCapture }.count == 1)
        #expect(backend.commands.filter { $0 == .detachScene }.isEmpty)

        session.controlWindowDidClose()
    }

    @Test("Starting training revokes window capture before the control scene disappears")
    func trainingHandoffRevokesWindowCaptureWithoutDetachingAudio() async {
        let backend = RecordingTrainingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources()
        )
        let speechClient = RecordingSpeechRecognitionClient()
        let session = ReactiveStrikeSession(
            feedbackGenerator: MockFeedbackGenerator(),
            audioCoordinator: coordinator,
            speechClient: speechClient
        )
        let flow = TrainingFlowCoordinator()
        let selection = TrainingSelection.reactive(
            mode: .air,
            combination: nil,
            stance: .orthodox
        )
        flow.navigate(to: .experience(selection))
        session.controlWindowDidOpen()
        session.voiceCoach.beginPushToTalk(origin: .controlWindow)
        await speechClient.waitForStartCount(1)
        flow.immersiveSceneDidBecomeReady(session: session)
        var hideCount = 0

        await flow.startExperience(
            selection,
            session: session,
            supportsMultipleScenes: true,
            openImmersive: { _ in .opened },
            dismissImmersive: {},
            hideControlWindow: { hideCount += 1 }
        )

        #expect(hideCount == 1)
        #expect(session.voiceCoach.isListening == false)
        #expect(session.voiceCoach.isCaptureReady == false)
        #expect(speechClient.isRecording == false)
        #expect(coordinator.presentation.isCapturing == false)
        #expect(backend.commands.filter { $0 == .endCapture }.count == 1)
        #expect(backend.commands.filter { $0 == .attachScene }.count == 1)
        #expect(backend.commands.filter { $0 == .detachScene }.isEmpty)

        session.controlWindowDidClose()
        flow.immersiveSceneDidClose(session: session)
    }

    @Test("Impact playback is capped at four simultaneous voices")
    func impactVoicePoolHasHardLimit() async {
        let backend = RecordingTrainingAudioBackend()
        let resources = StubTrainingAudioResources(available: [
            .cleanImpact1, .cleanImpact2, .cleanImpact3
        ])
        let coordinator = makeCoordinator(backend: backend, resources: resources)
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))

        for index in 0..<5 {
            await coordinator.handle(.validatedImpact(
                position: .init(Float(index) / 10, 1, -0.5),
                quality: .clean
            ))
        }

        #expect(coordinator.activeImpactVoiceCount == 4)
        #expect(backend.playedResources == [
            .cleanImpact1, .cleanImpact2, .cleanImpact3, .cleanImpact1, .cleanImpact2
        ])
        #expect(backend.stoppedHandles == [.init(rawValue: 1)])
    }

    @Test("Ambient loops fade through stage changes and hard-stop only at teardown")
    func ambienceLoopsDoNotRestartOrHardCutBetweenStages() async {
        let backend = RecordingTrainingAudioBackend()
        let resources = StubTrainingAudioResources(available: [
            .gymAmbience, .competitionCrowd
        ])
        let coordinator = makeCoordinator(backend: backend, resources: resources)
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.experienceDidEnter(.compete))
        let stopCountBeforeStageChange = backend.stoppedHandles.count

        await coordinator.handle(.experienceDidEnter(.learn))

        #expect(backend.playedResources == [.gymAmbience, .competitionCrowd])
        #expect(backend.stoppedHandles.count == stopCountBeforeStageChange)
        #expect(coordinator.presentation.mix.crowd == .muted)

        await coordinator.handle(.sceneDidDetach(.immersiveSpace))
        #expect(backend.commands.contains(.stopAll))
    }

    @Test("Teardown invalidates capture preparation that is still waiting for decay")
    func teardownInvalidatesPendingCaptureByGeneration() async {
        let backend = RecordingTrainingAudioBackend()
        let waiter = ControlledTrainingAudioWaiter()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources(),
            waiter: waiter
        )
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))

        let captureTask = Task { @MainActor in
            await coordinator.handle(.voiceCaptureDidBegin(origin: .immersiveSpace))
        }
        await waiter.waitUntilSuspended()
        await coordinator.handle(.sceneDidDetach(.immersiveSpace))
        waiter.resume()
        let outcome = await captureTask.value

        #expect(outcome == .staleGeneration)
        #expect(backend.commands.contains(.beginCapture) == false)
        #expect(coordinator.presentation.status == .detached)
    }

    @Test(
        "Only system deactivation is treated as an interruption",
        arguments: [
            TrainingAudioDeactivationCase(
                deactivation: .appInitiated,
                expectedEvent: nil
            ),
            TrainingAudioDeactivationCase(
                deactivation: .systemInterruption,
                expectedEvent: .interruptionBegan
            )
        ]
    )
    func appRequestedDeactivationDoesNotPauseTraining(testCase: TrainingAudioDeactivationCase) {
        #expect(TrainingAudioSystemEventMapper.event(for: testCase.deactivation) == testCase.expectedEvent)
    }

    @Test("App-driven audio category changes do not enter route recovery")
    func routeChangeMappingPreservesAndFiltersTheTypedReason() throws {
        let notification = Notification(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.categoryChange.rawValue
            ]
        )
        let message = try #require(AudioRouteDidChangeMessage.makeMessage(notification))

        #expect(message.reason == .categoryChange)
        #expect(TrainingAudioRouteChangeEventMapper.event(for: message.reason) == nil)
        #expect(TrainingAudioRouteChangeEventMapper.event(for: .oldDeviceUnavailable) == .routeChanged)
    }

    @Test("System, safety, and training-stop preemption synchronously revoke local speech")
    func capturePreemptionRevokesLocalSpeechAndPreservesReuse() async throws {
        let backend = RecordingTrainingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources(available: [.coach(.pauseAck)])
        )
        let speechClient = RecordingSpeechRecognitionClient()
        let session = ReactiveStrikeSession(
            feedbackGenerator: MockFeedbackGenerator(),
            audioCoordinator: coordinator,
            speechClient: speechClient
        )
        session.controlWindowDidOpen()

        session.voiceCoach.beginPushToTalk(origin: .controlWindow)
        await speechClient.waitForStartCount(1)
        #expect(session.voiceCoach.isListening)
        #expect(session.voiceCoach.isCaptureReady)
        #expect(speechClient.isRecording)

        #expect(coordinator.handleImmediately(.audioSystemEvent(.routeChanged)) == .handled)
        #expect(session.voiceCoach.isListening == false)
        #expect(session.voiceCoach.isCaptureReady == false)
        #expect(speechClient.isRecording == false)

        #expect(session.resumeAudio() == .handled)
        session.voiceCoach.beginPushToTalk(origin: .controlWindow)
        await speechClient.waitForStartCount(2)
        #expect(session.voiceCoach.isCaptureReady)

        let safetyOutcome = coordinator.handleImmediately(.coachCue(.init(
            kind: .safety,
            clip: .pauseAck,
            caption: "Stop now."
        )))
        #expect(safetyOutcome == .handled)
        #expect(session.voiceCoach.isListening == false)
        #expect(session.voiceCoach.isCaptureReady == false)
        #expect(speechClient.isRecording == false)

        let safetyHandles: [TrainingAudioPlaybackHandle] = backend.commands.compactMap { command in
            guard case let .play(handle, resource) = command,
                  resource == .coach(.pauseAck) else { return nil }
            return handle
        }
        let safetyHandle = try #require(safetyHandles.last)
        backend.playbackDidFinish?(safetyHandle)

        session.voiceCoach.beginPushToTalk(origin: .controlWindow)
        await speechClient.waitForStartCount(3)
        #expect(session.voiceCoach.isCaptureReady)

        session.stopDrill()

        #expect(session.voiceCoach.isListening == false)
        #expect(session.voiceCoach.isCaptureReady == false)
        #expect(session.voiceCoach.isRouting == false)
        #expect(session.voiceCoach.isGeneratingResponse == false)
        #expect(speechClient.isRecording == false)
        #expect(speechClient.cancelCount == 3)
        #expect(backend.commands.filter { $0 == .endCapture }.count == 3)
    }

    @Test("Reactive, Aura, voice, and scene lifecycle share one semantic audio owner")
    func liveTrainingSessionsUseTheInjectedCoordinator() {
        let backend = RecordingTrainingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources(available: [.coach(.guardUp)])
        )
        let session = ReactiveStrikeSession(
            feedbackGenerator: MockFeedbackGenerator(),
            audioCoordinator: coordinator
        )

        #expect(session.audioCoordinator === coordinator)
        #expect(session.auraPunch.audioCoordinator === coordinator)
        #expect(session.voiceCoach.audioCoordinator === coordinator)

        session.immersiveSpaceDidOpen()
        session.startDrill()
        #expect(coordinator.presentation.stage == .baseline)
        session.stopDrill()
        session.immersiveSpaceDidClose()

        #expect(backend.commands.filter { $0 == .attachScene }.count == 1)
        #expect(backend.playedResources == [.coach(.guardUp)])
        #expect(backend.commands.contains(.stopChannels([.coach, .impact, .status])))
        #expect(backend.commands.filter { $0 == .detachScene }.count == 1)
    }

    private func makeCoordinator(
        backend: RecordingTrainingAudioBackend,
        resources: StubTrainingAudioResources,
        waiter: (any TrainingAudioDecayWaiting)? = nil
    ) -> TrainingAudioCoordinator {
        TrainingAudioCoordinator(
            backend: backend,
            resources: resources,
            decayWaiter: waiter ?? ImmediateTrainingAudioWaiter(),
            fadeDuration: .milliseconds(200),
            captureDecay: .milliseconds(200)
        )
    }
}

nonisolated struct TrainingAudioDeactivationCase: Sendable, CustomTestStringConvertible {
    let deactivation: TrainingAudioSessionDeactivation
    let expectedEvent: TrainingAudioSystemEvent?

    var testDescription: String { String(describing: deactivation) }
}

nonisolated struct TrainingAudioStageMixCase: Sendable, CustomTestStringConvertible {
    let stage: TrainingAudioStage
    let ambience: TrainingAudioGain
    let crowd: TrainingAudioGain

    var testDescription: String { String(describing: stage) }

    static let all: [Self] = [
        .init(stage: .fit, ambience: .decibels(-24), crowd: .muted),
        .init(stage: .learn, ambience: .decibels(-22), crowd: .muted),
        .init(stage: .baseline, ambience: .decibels(-26), crowd: .muted),
        .init(stage: .correct, ambience: .decibels(-32), crowd: .muted),
        .init(stage: .prove, ambience: .decibels(-24), crowd: .muted),
        .init(stage: .transfer, ambience: .decibels(-24), crowd: .muted),
        .init(stage: .compete, ambience: .decibels(-28), crowd: .decibels(-24)),
        .init(stage: .celebrate, ambience: .decibels(-30), crowd: .decibels(-14))
    ]
}

@MainActor
private final class TrainingAudioTestJournal {
    enum Entry: Equatable {
        case stopChannels(Set<TrainingAudioChannel>)
        case applyMix
        case wait(Duration)
        case beginCapture
        case endCapture
        case play(TrainingAudioResourceID)
    }

    private(set) var entries: [Entry] = []

    func append(_ entry: Entry) {
        entries.append(entry)
    }

    func removeAll() {
        entries.removeAll()
    }
}

@MainActor
private final class StubTrainingAudioResources: TrainingAudioResourceResolving {
    var onResolve: ((TrainingAudioResourceID) -> Void)?
    private let available: Set<TrainingAudioResourceID>

    init(available: Set<TrainingAudioResourceID> = []) {
        self.available = available
    }

    func url(for resource: TrainingAudioResourceID) -> URL? {
        onResolve?(resource)
        guard available.contains(resource) else { return nil }
        return URL(fileURLWithPath: "/tmp/\(resource.fileName).mp3")
    }
}

@MainActor
private final class RecordingTrainingAudioBackend: TrainingAudioBackend {
    private enum Failure: Error {
        case playbackRecovery
    }

    enum Command: Equatable {
        case attachScene
        case detachScene
        case applyMix(TrainingAudioMix, Duration)
        case play(TrainingAudioPlaybackHandle, TrainingAudioResourceID)
        case stop(TrainingAudioPlaybackHandle)
        case stopChannels(Set<TrainingAudioChannel>)
        case stopAll
        case beginCapture
        case endCapture
        case recoverPlaybackSession
        case mediaServicesWereReset
    }

    var playbackDidFinish: ((TrainingAudioPlaybackHandle) -> Void)?
    var systemEventHandler: ((TrainingAudioSystemEvent) -> Void)?
    private(set) var commands: [Command] = []
    var recoverPlaybackFailuresRemaining = 0
    private var nextHandle = 1
    private let journal: TrainingAudioTestJournal?

    init(journal: TrainingAudioTestJournal? = nil) {
        self.journal = journal
    }

    var playedResources: [TrainingAudioResourceID] {
        commands.compactMap { command in
            guard case let .play(_, resource) = command else { return nil }
            return resource
        }
    }

    var stoppedHandles: [TrainingAudioPlaybackHandle] {
        commands.compactMap { command in
            guard case let .stop(handle) = command else { return nil }
            return handle
        }
    }

    func attachScene() throws {
        commands.append(.attachScene)
    }

    func detachScene() {
        commands.append(.detachScene)
    }

    func apply(mix: TrainingAudioMix, fadeDuration: Duration) {
        commands.append(.applyMix(mix, fadeDuration))
        journal?.append(.applyMix)
    }

    func play(_ request: TrainingAudioPlaybackRequest) -> TrainingAudioPlaybackHandle? {
        let handle = TrainingAudioPlaybackHandle(rawValue: nextHandle)
        nextHandle += 1
        commands.append(.play(handle, request.resource))
        journal?.append(.play(request.resource))
        return handle
    }

    func stop(_ handle: TrainingAudioPlaybackHandle) {
        commands.append(.stop(handle))
    }

    func stop(channels: Set<TrainingAudioChannel>) {
        commands.append(.stopChannels(channels))
        journal?.append(.stopChannels(channels))
    }

    func stopAll() {
        commands.append(.stopAll)
    }

    func beginVoiceCapture() throws {
        commands.append(.beginCapture)
        journal?.append(.beginCapture)
    }

    func endVoiceCapture() {
        commands.append(.endCapture)
        journal?.append(.endCapture)
    }

    func recoverPlaybackSession() throws {
        commands.append(.recoverPlaybackSession)
        if recoverPlaybackFailuresRemaining > 0 {
            recoverPlaybackFailuresRemaining -= 1
            throw Failure.playbackRecovery
        }
    }

    func mediaServicesWereReset() throws {
        commands.append(.mediaServicesWereReset)
    }
}

@MainActor
private final class ImmediateTrainingAudioWaiter: TrainingAudioDecayWaiting {
    private let journal: TrainingAudioTestJournal?

    init(journal: TrainingAudioTestJournal? = nil) {
        self.journal = journal
    }

    func wait(for duration: Duration) async throws {
        journal?.append(.wait(duration))
    }
}

@MainActor
private final class ControlledTrainingAudioWaiter: TrainingAudioDecayWaiting {
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waitCallCount = 0

    func wait(for duration: Duration) async throws {
        waitCallCount += 1
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        guard releaseContinuations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        guard !releaseContinuations.isEmpty else { return }
        releaseContinuations.removeFirst().resume()
    }

    func resumeAll() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

@MainActor
private final class RecordingSpeechRecognitionClient: SpeechRecognizing {
    private struct StartWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var startWaiters: [StartWaiter] = []
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var isRecording = false

    func requestPermissions() async -> Bool {
        true
    }

    func start() throws {
        startCount += 1
        isRecording = true

        let ready = startWaiters.filter { startCount >= $0.count }
        startWaiters.removeAll { startCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func stop() async -> SpeechRecognitionResult {
        isRecording = false
        return SpeechRecognitionResult(transcript: "", duration: 0)
    }

    func cancel() {
        cancelCount += 1
        isRecording = false
    }

    func waitForStartCount(_ count: Int) async {
        guard startCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(StartWaiter(count: count, continuation: continuation))
        }
    }
}
