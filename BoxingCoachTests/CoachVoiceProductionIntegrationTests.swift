import Foundation
import Testing
@testable import BoxingCoach

@Suite("Coach voice production integration")
@MainActor
struct CoachVoiceProductionIntegrationTests {
    @Test("A final live transcript executes an accepted command through the production router")
    func finalTranscriptExecutesCommand() async throws {
        let target = ProductionVoiceTarget(state: .learn, capabilities: [.pause])

        let response = await CoachVoiceCommandRouter().resolve(
            transcript: "pause training",
            issuedFor: target.commandGeneration,
            on: target
        )

        #expect(target.pauseCount == 1)
        #expect(response?.clip == .pauseAck)
        #expect(response?.caption == "Training paused.")
    }

    @Test("A transcript uses its pre-capture context while generation is revalidated live")
    func finalTranscriptUsesPreCaptureContext() async throws {
        let target = ProductionVoiceTarget(state: .trackingPaused, capabilities: [.resume])
        let issuedContext = VoiceCommandContext(state: .learn, capabilities: [.next])

        let response = await CoachVoiceCommandRouter().resolve(
            transcript: "next",
            issuedFor: target.commandGeneration,
            issuedContext: issuedContext,
            on: target
        )

        #expect(target.advanceCount == 1)
        #expect(response?.intent == .next)
        #expect(response?.caption == "Next step.")
    }

    @Test("A coach response owns the pause until its actual playback finishes")
    func responseCompletionFollowsPlayback() async throws {
        let audio = ProductionVoiceAudioSystem()
        let coordinator = TrainingAudioCoordinator(
            backend: audio,
            resources: audio,
            decayWaiter: audio
        )
        coordinator.handleImmediately(.sceneDidAttach(.immersiveSpace))
        let speech = ProductionVoiceSpeechClient(transcript: "pause training")
        let target = ProductionVoiceTarget(state: .learn, capabilities: [.pause])
        let coach = CoachVoiceCoach(audioCoordinator: coordinator, speechClient: speech)
        coach.setCommandHandler { transcript, issuance in
            await CoachVoiceCommandRouter().resolve(
                transcript: transcript,
                issuedFor: target.commandGeneration,
                issuedContext: issuance?.context,
                on: target
            )
        }

        #expect(coach.beginPushToTalk(origin: .immersiveSpace))
        coach.acceptPrivacyNotice()
        for _ in 0..<100 where !coach.isCaptureReady { await Task.yield() }
        #expect(coach.isCaptureReady)

        coach.endPushToTalk()
        for _ in 0..<100 where !coach.isGeneratingResponse { await Task.yield() }
        #expect(coach.isGeneratingResponse)
        #expect(target.pauseCount == 1)
        let handle = try #require(audio.lastPlaybackHandle)

        audio.playbackDidFinish?(handle)

        #expect(coach.state == .awaitingGuard)
    }

    @Test("Reactive push to talk pauses an active drill through the live capture callback")
    func reactiveCapturePausesActiveDrill() async {
        let audio = ProductionVoiceAudioSystem()
        let coordinator = TrainingAudioCoordinator(
            backend: audio,
            resources: audio,
            decayWaiter: audio
        )
        let speech = ProductionVoiceSpeechClient(transcript: "help")
        let session = ReactiveStrikeSession(
            audioCoordinator: coordinator,
            speechClient: speech,
            roundReadyDelay: {},
            postAttemptRecordDelay: {}
        )
        session.controlWindowDidOpen()
        session.startDrill()
        #expect(session.phase == .calibrating || session.phase == .running)

        #expect(session.voiceCoach.beginPushToTalk(origin: .controlWindow))
        session.voiceCoach.acceptPrivacyNotice()
        for _ in 0..<100 where !session.voiceCoach.isCaptureReady { await Task.yield() }

        #expect(session.voiceCoach.isCaptureReady)
        #expect(session.isVoicePaused)
        #expect(session.isTrackingPaused)
    }

    @Test("Private session reset leaves a prepared coach ready without stale guard copy")
    func privateSessionResetClearsLifecycle() {
        var lifecycle = CoachVoiceLifecycle()
        #expect(lifecycle.handle(.activate(origin: .controlWindow)) == .presentPrivacyNotice)
        let id = lifecycle.activeCaptureID!
        #expect(lifecycle.handle(.privacyAccepted(id: id)) == .requestMicrophonePermission)
        #expect(lifecycle.handle(.permissionGranted(id: id)) == .prepareModel)
        _ = lifecycle.handle(.modelPrepared(id: id))
        _ = lifecycle.handle(.activate(origin: .controlWindow))
        let captureID = lifecycle.activeCaptureID!
        _ = lifecycle.handle(.captureReady(id: captureID))
        _ = lifecycle.handle(.stopRequested(id: captureID))
        _ = lifecycle.handle(.recognitionFinalized(id: captureID))
        _ = lifecycle.handle(.commandExecuted(id: captureID))
        _ = lifecycle.handle(.responseFinished(id: captureID))
        #expect(lifecycle.state == .awaitingGuard)

        _ = lifecycle.handle(.sessionCleared)

        #expect(lifecycle.state == .ready)
        #expect(lifecycle.activeCaptureID == nil)
    }

    @Test("An older scene cannot clear a newer command registration")
    func commandRegistrationIsOwnerTokened() {
        let audio = ProductionVoiceAudioSystem()
        let coordinator = TrainingAudioCoordinator(
            backend: audio,
            resources: audio,
            decayWaiter: audio
        )
        let coach = CoachVoiceCoach(audioCoordinator: coordinator)
        let older = coach.registerCommandHandler { _, _ in nil }
        let newer = coach.registerCommandHandler { _, _ in nil }

        coach.unregisterCommandHandler(older)
        #expect(coach.activeCommandHandlerRegistrationID == newer)

        coach.unregisterCommandHandler(newer)
        #expect(coach.activeCommandHandlerRegistrationID == nil)
    }

    @Test("A pause command transfers the temporary capture pause into a persistent pause")
    func pauseCommandPersistsAfterResponse() {
        let session = ReactiveStrikeSession()
        session.startDrill()
        #expect(session.pauseForVoice() != nil)

        #expect(session.pauseForVoiceCommand() == "Training paused.")
        #expect(session.voiceCommandPauseIsPersistent)

        #expect(session.requestVoiceResumeAfterResponse() == "Return both fists to guard to resume.")
        #expect(!session.voiceCommandPauseIsPersistent)
        #expect(session.isVoicePaused)
    }

    @Test(
        "Aura learning stages map exhaustively to voice command states",
        arguments: [
            (LearningStage.fit, VoiceCommandState.learn),
            (.learnWatch, .learn),
            (.learnOutbound, .learn),
            (.learnLanding, .learn),
            (.learnReturn, .learn),
            (.guidedRehearsal, .learn),
            (.baseline, .baseline),
            (.correction, .correction),
            (.correctiveDrill, .correction),
            (.proof, .retest),
            (.retest, .retest),
            (.transfer, .transfer),
            (.complete, .results),
        ]
    )
    func auraStageMapsToCommandState(stage: LearningStage, expected: VoiceCommandState) {
        #expect(AuraVoiceCommandStatePolicy.state(for: stage, trackingPaused: false) == expected)
    }
}

@MainActor
private final class ProductionVoiceTarget: TrainingCommandTarget {
    var commandGeneration: UInt64 = 7
    var commandContext: VoiceCommandContext
    private(set) var pauseCount = 0
    private(set) var advanceCount = 0

    init(state: VoiceCommandState, capabilities: Set<VoiceCommandCapability>) {
        commandContext = VoiceCommandContext(state: state, capabilities: capabilities)
    }

    func pauseForVoice() -> String? { pauseCount += 1; return "Training paused." }
    func resumeAfterFreshGuard() async -> String? { "Training resumed." }
    func repeatDemo() -> String? { nil }
    func setDemoRate(_ rate: TrainingDemoRate) -> String? { nil }
    func advance() -> String? { advanceCount += 1; return "Next step." }
    func requestCorrection() -> String? { nil }
    func requestGuardExplanation() -> String? { nil }
    func requestTargetHelp() -> String? { nil }
    func requestProgress() -> String? { nil }
    func requestHelp() -> String? { nil }
    func requestScore() -> String? { nil }
    func requestWhy() -> String? { nil }
    func requestLeaderboard() -> String? { nil }
    func requestEndConfirmation() -> String? { nil }
    func confirmEnd() async -> String? { nil }
    func cancelEndConfirmation() -> String? { nil }
    func requestParticipantHandoffConfirmation() -> String? { nil }
}

@MainActor
private final class ProductionVoiceSpeechClient: SpeechRecognizing {
    private let transcript: String
    init(transcript: String) { self.transcript = transcript }
    func requestPermissions() async -> Bool { true }
    func prepareModel() async throws {}
    func start() throws {}
    func stop() async -> SpeechRecognitionResult {
        SpeechRecognitionResult(transcript: transcript, duration: 0.5)
    }
    func cancel() {}
}

@MainActor
private final class ProductionVoiceAudioSystem:
    TrainingAudioBackend,
    TrainingAudioResourceResolving,
    TrainingAudioDecayWaiting {
    var playbackDidFinish: ((TrainingAudioPlaybackHandle) -> Void)?
    var systemEventHandler: ((TrainingAudioSystemEvent) -> Void)?
    private(set) var lastPlaybackHandle: TrainingAudioPlaybackHandle?

    func attachScene() throws {}
    func detachScene() {}
    func apply(mix: TrainingAudioMix, fadeDuration: Duration) {}
    func play(_ request: TrainingAudioPlaybackRequest) -> TrainingAudioPlaybackHandle? {
        let handle = TrainingAudioPlaybackHandle(rawValue: 99)
        lastPlaybackHandle = handle
        return handle
    }
    func stop(_ handle: TrainingAudioPlaybackHandle) {}
    func stop(channels: Set<TrainingAudioChannel>) {}
    func stopAll() {}
    func beginVoiceCapture() throws {}
    func endVoiceCapture() {}
    func recoverPlaybackSession() throws {}
    func mediaServicesWereReset() throws {}
    func url(for resource: TrainingAudioResourceID) -> URL? {
        URL(fileURLWithPath: "/private/tmp/\(resource.fileName).wav")
    }
    func wait(for duration: Duration) async throws {}
}
