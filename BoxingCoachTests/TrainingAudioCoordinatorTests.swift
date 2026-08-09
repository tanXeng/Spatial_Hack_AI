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

        await coordinator.handle(.sceneDidAttach)
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
        await coordinator.handle(.sceneDidAttach)

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

        await coordinator.handle(.sceneDidAttach)
        await coordinator.handle(.experienceDidEnter(.compete))
        await coordinator.handle(.trackingDidPause(.handsUnavailable))
        await coordinator.handle(.trackingDidResume)
        await coordinator.handle(.voiceCaptureDidBegin)
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
        await coordinator.handle(.sceneDidAttach)
        await coordinator.handle(.coachCue(.init(
            kind: .phaseInstruction,
            clip: .guardUp,
            caption: "Guard up"
        )))
        journal.removeAll()

        let captureOutcome = await coordinator.handle(.voiceCaptureDidBegin)

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

    @Test("Tracking loss mutes crowd and scoring effects until explicit tracking resume")
    func trackingLossAppliesSafetyMix() async {
        let backend = RecordingTrainingAudioBackend()
        let resources = StubTrainingAudioResources(available: [
            .gymAmbience,
            .competitionCrowd,
            .cleanImpact1
        ])
        let coordinator = makeCoordinator(backend: backend, resources: resources)
        await coordinator.handle(.sceneDidAttach)
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
        await coordinator.handle(.sceneDidAttach)
        await coordinator.handle(.experienceDidEnter(.compete))
        let playsBeforeInterruption = backend.playedResources.count

        await coordinator.handle(.audioSystemEvent(.interruptionBegan))
        await coordinator.handle(.audioSystemEvent(.interruptionEnded))

        #expect(coordinator.presentation.status == .awaitingExplicitRecovery)
        #expect(coordinator.presentation.requiresExplicitRecovery)
        #expect(backend.playedResources.count == playsBeforeInterruption)
        #expect(backend.commands.contains(.recoverPlaybackSession))

        await coordinator.handle(.audioRecoveryConfirmed)

        #expect(coordinator.presentation.status == .ready)
        #expect(coordinator.presentation.requiresExplicitRecovery == false)
        #expect(backend.playedResources.count > playsBeforeInterruption)
    }

    @Test("Route changes and media resets invalidate playback and require an explicit recovery")
    func routeAndMediaLossAreGenerationSafe() async {
        let backend = RecordingTrainingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: StubTrainingAudioResources(available: [.gymAmbience])
        )
        await coordinator.handle(.sceneDidAttach)
        let initialGeneration = coordinator.generation

        await coordinator.handle(.audioSystemEvent(.routeChanged))
        let routeGeneration = coordinator.generation
        #expect(routeGeneration > initialGeneration)
        #expect(coordinator.presentation.requiresExplicitRecovery)
        #expect(backend.commands.contains(.stopAll))

        await coordinator.handle(.audioRecoveryConfirmed)
        await coordinator.handle(.audioSystemEvent(.mediaServicesWereReset))

        #expect(coordinator.generation > routeGeneration)
        #expect(coordinator.presentation.requiresExplicitRecovery)
        #expect(backend.commands.contains(.mediaServicesWereReset))
    }

    @Test("Missing resources preserve captions and state before lookup")
    func missingResourcesKeepVisibleEquivalent() async {
        let backend = RecordingTrainingAudioBackend()
        let resources = StubTrainingAudioResources()
        let coordinator = makeCoordinator(backend: backend, resources: resources)
        await coordinator.handle(.sceneDidAttach)
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

        await coordinator.handle(.sceneDidAttach)
        await coordinator.handle(.sceneDidAttach)
        await coordinator.handle(.sceneDidDetach)
        await coordinator.handle(.sceneDidDetach)

        #expect(backend.commands.filter { $0 == .attachScene }.count == 1)
        #expect(backend.commands.filter { $0 == .detachScene }.count == 1)
        #expect(coordinator.presentation.status == .detached)
    }

    @Test("Impact playback is capped at four simultaneous voices")
    func impactVoicePoolHasHardLimit() async {
        let backend = RecordingTrainingAudioBackend()
        let resources = StubTrainingAudioResources(available: [
            .cleanImpact1, .cleanImpact2, .cleanImpact3
        ])
        let coordinator = makeCoordinator(backend: backend, resources: resources)
        await coordinator.handle(.sceneDidAttach)

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
        await coordinator.handle(.sceneDidAttach)
        await coordinator.handle(.experienceDidEnter(.compete))
        let stopCountBeforeStageChange = backend.stoppedHandles.count

        await coordinator.handle(.experienceDidEnter(.learn))

        #expect(backend.playedResources == [.gymAmbience, .competitionCrowd])
        #expect(backend.stoppedHandles.count == stopCountBeforeStageChange)
        #expect(coordinator.presentation.mix.crowd == .muted)

        await coordinator.handle(.sceneDidDetach)
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
        await coordinator.handle(.sceneDidAttach)

        let captureTask = Task { @MainActor in
            await coordinator.handle(.voiceCaptureDidBegin)
        }
        await waiter.waitUntilSuspended()
        await coordinator.handle(.sceneDidDetach)
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
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func wait(for duration: Duration) async throws {
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard releaseContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
