import Foundation
import RealityKit
import Testing
@testable import BoxingCoach

@Suite("Spatial training audio integration")
@MainActor
struct TrainingAudioIntegrationTests {
    @Test(
        "Every learning stage selects its semantic training audio stage",
        arguments: [
            (LearningStage.fit, TrainingAudioStage.fit),
            (.learnWatch, .learn),
            (.learnOutbound, .learn),
            (.learnLanding, .learn),
            (.learnReturn, .learn),
            (.guidedRehearsal, .learn),
            (.baseline, .baseline),
            (.correction, .correct),
            (.correctiveDrill, .correct),
            (.retest, .prove),
            (.proof, .prove),
            (.transfer, .transfer),
            (.complete, .celebrate),
        ]
    )
    func learningStageOwnsSemanticAudioStage(
        stage: LearningStage,
        expected: TrainingAudioStage
    ) {
        #expect(stage.trainingAudioStage == expected)
    }

    @Test("A restarted Aura cycle publishes Fit before waiting for tracking")
    func restartedAuraCycleClearsThePriorResultMixImmediately() async {
        let backend = IntegrationRecordingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: IntegrationAudioResources(available: [])
        )
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.experienceDidEnter(.celebrate))

        let session = AuraPunchSession(
            hands: IntegrationUnavailableAuraTracking(),
            feedbackGenerator: MockFeedbackGenerator(),
            audienceTrack: .beginner,
            audioCoordinator: coordinator
        )
        session.start()

        #expect(coordinator.presentation.stage == .fit)
        #expect(coordinator.presentation.mix == .stage(.fit))
    }

    @Test("Only admitted evidence gets a clean hit and one rejected chain gets one dull cue")
    func semanticEvidenceCannotDoubleFireImpactFeedback() async {
        let backend = IntegrationRecordingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: IntegrationAudioResources(available: [
                .rejectedImpact,
                .cleanImpact1
            ])
        )
        let target = SIMD3<Float>(0.18, 1.12, -0.72)

        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.targetDidAppear(position: target))

        #expect(await coordinator.handle(.rejectedImpact(
            position: target,
            reason: "Wrong hand · reset in guard"
        )) == .handled)
        #expect(coordinator.presentation.caption == "Wrong hand · reset in guard")
        #expect(coordinator.presentation.symbolName == "hand.raised.slash.fill")

        #expect(await coordinator.handle(.rejectedImpact(
            position: target,
            reason: "Wrong hand · reset in guard"
        )) == .duplicateEvidence)

        #expect(backend.playedResources == [.rejectedImpact])
        #expect(await coordinator.handle(.validatedImpact(
            position: target,
            quality: .clean
        )) == .handled)
        #expect(backend.playedResources == [.rejectedImpact, .cleanImpact1])
        #expect(coordinator.presentation.caption == "Clean impact.")
        #expect(coordinator.presentation.symbolName == "burst.fill")
    }

    @Test("Tracking loss freezes scoring and uses the tracking-safe mix until explicit recovery")
    func trackingLossFreezesScoringAndImpactAdmission() async {
        let backend = IntegrationRecordingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: IntegrationAudioResources(available: [
                .trackingLost,
                .trackingRestored,
                .cleanImpact1
            ])
        )

        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.experienceDidEnter(.compete))
        await coordinator.handle(.trackingDidPause(.staleSamples))

        #expect(coordinator.presentation.isScoringFrozen)
        #expect(coordinator.presentation.mix == .trackingPaused)
        #expect(coordinator.presentation.symbolName == "hand.raised.slash.fill")
        #expect(await coordinator.handle(.validatedImpact(
            position: SIMD3<Float>(0, 1, -0.7),
            quality: .clean
        )) == .scoringFrozen)
        #expect(backend.playedResources.contains(.cleanImpact1) == false)

        await coordinator.handle(.trackingDidResume)

        #expect(coordinator.presentation.isScoringFrozen == false)
        #expect(await coordinator.handle(.validatedImpact(
            position: SIMD3<Float>(0, 1, -0.7),
            quality: .clean
        )) == .handled)
        #expect(backend.playedResources.contains(.cleanImpact1))
    }

    @Test("Window ambience migrates to the immersive body field without double playback")
    func windowAmbienceMigratesToSpatialSceneOnce() async {
        let backend = IntegrationRecordingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: IntegrationAudioResources(available: [.gymAmbience])
        )
        let worldRoot = Entity()
        let bodyAnchor = Entity()

        await coordinator.handle(.sceneDidAttach(.controlWindow))

        #expect(backend.activePlayback(for: .gymAmbience)?.rendering == .fallback)

        coordinator.attachSpatialScene(worldRoot: worldRoot, bodyAnchor: bodyAnchor)
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        coordinator.attachSpatialScene(worldRoot: worldRoot, bodyAnchor: bodyAnchor)

        #expect(backend.activePlaybacks(for: .gymAmbience).count == 1)
        #expect(backend.activePlayback(for: .gymAmbience)?.rendering == .spatial)
        #expect(backend.playedResources.filter { $0 == .gymAmbience }.count == 2)
    }

    @Test("Spatial teardown clears ownership so the next immersive scene restarts every pool")
    func spatialTeardownClearsCoordinatorPlaybackOwnership() async {
        let backend = IntegrationRecordingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: IntegrationAudioResources(available: [
                .gymAmbience,
                .competitionCrowd,
                .cleanImpact1,
                .startBell
            ])
        )
        let firstWorldRoot = Entity()
        let firstBodyAnchor = Entity()
        let target = SIMD3<Float>(0.18, 1.12, -0.72)

        coordinator.attachSpatialScene(
            worldRoot: firstWorldRoot,
            bodyAnchor: firstBodyAnchor
        )
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.experienceDidEnter(.compete))
        await coordinator.handle(.targetDidAppear(position: target))
        await coordinator.handle(.validatedImpact(position: target, quality: .clean))
        await coordinator.handle(.roundDidStart)
        await coordinator.handle(.sceneDidAttach(.controlWindow))

        #expect(coordinator.activeImpactVoiceCount == 1)
        #expect(backend.playedResources.filter { $0 == .startBell }.count == 1)
        #expect(backend.activePlayback(for: .gymAmbience)?.rendering == .spatial)
        #expect(backend.activePlayback(for: .competitionCrowd)?.rendering == .spatial)

        coordinator.detachSpatialScene()
        await coordinator.handle(.sceneDidDetach(.immersiveSpace))

        #expect(coordinator.activeImpactVoiceCount == 0)
        #expect(backend.activePlaybacks.isEmpty)

        let secondWorldRoot = Entity()
        let secondBodyAnchor = Entity()
        coordinator.attachSpatialScene(
            worldRoot: secondWorldRoot,
            bodyAnchor: secondBodyAnchor
        )
        await coordinator.handle(.sceneDidAttach(.immersiveSpace))

        #expect(backend.activePlaybacks(for: .gymAmbience).count == 1)
        #expect(backend.activePlaybacks(for: .competitionCrowd).count == 1)
        #expect(backend.playedResources.filter { $0 == .gymAmbience }.count == 2)
        #expect(backend.playedResources.filter { $0 == .competitionCrowd }.count == 2)

        await coordinator.handle(.targetDidAppear(position: target))
        await coordinator.handle(.validatedImpact(position: target, quality: .clean))
        await coordinator.handle(.roundDidStart)

        #expect(coordinator.activeImpactVoiceCount == 1)
        #expect(backend.activePlaybacks(for: .cleanImpact1).count == 1)
        #expect(backend.playedResources.filter { $0 == .startBell }.count == 2)
    }

    @Test("Stage selection stays silent until the calibrated round explicitly starts")
    func semanticRoundStartOwnsTheStartBell() async {
        let backend = IntegrationRecordingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: IntegrationAudioResources(available: [.startBell])
        )

        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.experienceDidEnter(.compete))

        #expect(backend.playedResources.contains(.startBell) == false)

        await coordinator.handle(.roundDidStart)
        await coordinator.handle(.roundDidStart)

        #expect(backend.playedResources.filter { $0 == .startBell }.count == 1)
        #expect(coordinator.presentation.caption == "Competition round started.")
        #expect(coordinator.presentation.symbolName == "bell.fill")
    }

    @Test("Persisted rank controls winner audio and keeps a visible nonwinner result")
    func persistedCompetitionResultOwnsWinnerAccent() async {
        let nonwinnerBackend = IntegrationRecordingAudioBackend()
        let nonwinnerCoordinator = makeCoordinator(
            backend: nonwinnerBackend,
            resources: IntegrationAudioResources(available: [.endBell, .winnerSwell])
        )

        await nonwinnerCoordinator.handle(.sceneDidAttach(.controlWindow))
        await nonwinnerCoordinator.handle(.experienceDidEnter(.celebrate))
        await nonwinnerCoordinator.handle(.competitionResultDidPersist(rank: 3, isWinner: false))
        await nonwinnerCoordinator.handle(.competitionResultDidPersist(rank: 3, isWinner: false))

        #expect(nonwinnerBackend.playedResources.filter { $0 == .endBell }.count == 1)
        #expect(nonwinnerBackend.playedResources.contains(.winnerSwell) == false)
        #expect(nonwinnerCoordinator.presentation.caption == "Rank 3 confirmed. Round complete.")
        #expect(nonwinnerCoordinator.presentation.symbolName == "list.number")

        let winnerBackend = IntegrationRecordingAudioBackend()
        let winnerCoordinator = makeCoordinator(
            backend: winnerBackend,
            resources: IntegrationAudioResources(available: [.endBell, .winnerSwell])
        )

        await winnerCoordinator.handle(.sceneDidAttach(.controlWindow))
        await winnerCoordinator.handle(.experienceDidEnter(.celebrate))
        await winnerCoordinator.handle(.competitionResultDidPersist(rank: 1, isWinner: true))

        #expect(winnerBackend.playedResources.filter { $0 == .endBell }.count == 1)
        #expect(winnerBackend.playedResources.filter { $0 == .winnerSwell }.count == 1)
        #expect(winnerCoordinator.presentation.caption == "Rank 1. Winner confirmed. Round complete.")
        #expect(winnerCoordinator.presentation.symbolName == "trophy.fill")

        let inconsistentBackend = IntegrationRecordingAudioBackend()
        let inconsistentCoordinator = makeCoordinator(
            backend: inconsistentBackend,
            resources: IntegrationAudioResources(available: [.endBell, .winnerSwell])
        )

        await inconsistentCoordinator.handle(.sceneDidAttach(.controlWindow))
        await inconsistentCoordinator.handle(.experienceDidEnter(.celebrate))
        await inconsistentCoordinator.handle(.competitionResultDidPersist(rank: 2, isWinner: true))

        #expect(inconsistentBackend.playedResources.contains(.winnerSwell) == false)
        #expect(inconsistentCoordinator.presentation.caption == "Rank 2 confirmed. Round complete.")
        #expect(inconsistentCoordinator.presentation.symbolName == "list.number")
    }

    @Test("A competition stage cannot claim a winner before standings persist")
    func competitionCompletionWaitsForPersistedStanding() async {
        let backend = IntegrationRecordingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: IntegrationAudioResources(available: [.endBell, .winnerSwell])
        )

        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.experienceDidEnter(.compete))
        await coordinator.handle(.experienceDidEnter(.celebrate))

        #expect(backend.playedResources.contains(.endBell) == false)
        #expect(backend.playedResources.contains(.winnerSwell) == false)
        #expect(coordinator.presentation.caption == TrainingAudioStage.celebrate.caption)
    }

    @Test("An unranked result owns its end bell and improvement accent once")
    func unrankedResultOwnsCompletionAccents() async {
        let backend = IntegrationRecordingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: IntegrationAudioResources(available: [
                .endBell,
                .improvementSting,
            ])
        )

        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.experienceDidEnter(.baseline))
        await coordinator.handle(.experienceDidEnter(.celebrate))
        await coordinator.handle(.unrankedResultDidFinalize)
        await coordinator.handle(.unrankedResultDidFinalize)

        #expect(backend.playedResources.filter { $0 == .endBell }.count == 1)
        #expect(backend.playedResources.filter { $0 == .improvementSting }.count == 1)
        #expect(coordinator.presentation.caption == "Training improvement complete.")
        #expect(coordinator.presentation.symbolName == "chart.line.uptrend.xyaxis")
    }

    @Test(
        "Every audio preset keeps visible equivalents and applies its channel policy",
        arguments: TrainingAudioPreset.allCases
    )
    func presetsRemainAccessible(preset: TrainingAudioPreset) {
        let source = TrainingAudioMix.stage(.compete)
        let mix = preset.applying(to: source)

        #expect(preset.title.isEmpty == false)
        #expect(preset.symbolName.isEmpty == false)
        #expect(preset.accessibilityDescription.isEmpty == false)

        switch preset {
        case .full:
            #expect(mix == source)
        case .coachOnly:
            #expect(mix.coach == source.coach)
            #expect(mix.status == source.status)
            #expect(mix.ambience == .muted)
            #expect(mix.crowd == .muted)
            #expect(mix.impact == .muted)
        case .reduced:
            #expect(mix.ambience == .muted)
            #expect(mix.crowd == .muted)
            #expect(mix.impact == .decibels(-12))
        case .off:
            #expect(mix == .silent)
        }
    }

    @Test("Spatial scene fields and mono emitter pools attach and tear down exactly once")
    func spatialSceneLifetimeIsPooledAndIdempotent() {
        let worldRoot = Entity()
        let bodyAnchor = Entity()
        worldRoot.addChild(bodyAnchor)
        let scene = TrainingSpatialAudioScene()

        scene.attach(worldRoot: worldRoot, bodyAnchor: bodyAnchor)
        scene.attach(worldRoot: worldRoot, bodyAnchor: bodyAnchor)

        #expect(bodyAnchor.children.filter { $0.name == "TrainingGymAmbienceField" }.count == 1)
        #expect(bodyAnchor.children.filter { $0.name == "TrainingCompetitionCrowdField" }.count == 1)
        #expect(worldRoot.children.filter { $0.name.hasPrefix("TrainingTargetAudioEmitter") }.count == 4)
        #expect(bodyAnchor.children.filter { $0.name.hasPrefix("TrainingBodyAudioEmitter") }.count == 3)
        #expect(scene.entityCount == 9)

        scene.detach()
        scene.detach()

        #expect(scene.entityCount == 0)
        #expect(bodyAnchor.children.filter { $0.name.hasPrefix("Training") }.isEmpty)
        #expect(worldRoot.children.filter { $0.name.hasPrefix("TrainingTargetAudioEmitter") }.isEmpty)
    }

    private func makeCoordinator(
        backend: IntegrationRecordingAudioBackend,
        resources: IntegrationAudioResources
    ) -> TrainingAudioCoordinator {
        TrainingAudioCoordinator(
            backend: backend,
            resources: resources,
            decayWaiter: IntegrationImmediateAudioWaiter(),
            fadeDuration: .milliseconds(200),
            captureDecay: .milliseconds(200)
        )
    }
}

@MainActor
private final class IntegrationUnavailableAuraTracking: AuraHandTracking {
    let providerGeneration: UInt64 = 1
    let continuityEpoch: UInt64 = 1
    let statusMessage = "Tracking unavailable"
    let deviceTransform: simd_float4x4? = nil
    let isRunning = false
    let hasFullUpperBodyTracking = false

    func start() async {}
    func beginAttemptCapture() {}
    func endAttemptCapture() {}
    func observation(for side: BodySide) -> HandObservation? { nil }
    func freshObservation(for side: BodySide, maxAge: TimeInterval) -> HandObservation? { nil }
}

@MainActor
final class IntegrationRecordingAudioBackend: TrainingAudioBackend {
    enum Rendering: Equatable {
        case fallback
        case spatial
    }

    struct Playback: Equatable {
        let resource: TrainingAudioResourceID
        let channel: TrainingAudioChannel
        let rendering: Rendering
    }

    var playbackDidFinish: ((TrainingAudioPlaybackHandle) -> Void)?
    var systemEventHandler: ((TrainingAudioSystemEvent) -> Void)?
    private(set) var playedResources: [TrainingAudioResourceID] = []
    private(set) var activePlaybacks: [TrainingAudioPlaybackHandle: Playback] = [:]
    private var spatialSceneAttached = false
    private var nextHandle = 1

    func attachScene() throws {}
    func detachScene() {}
    func attachSpatialScene(worldRoot: Entity, bodyAnchor: Entity) {
        spatialSceneAttached = true
    }

    func detachSpatialScene() {
        spatialSceneAttached = false
        activePlaybacks = activePlaybacks.filter { $0.value.rendering != .spatial }
    }
    func apply(mix: TrainingAudioMix, fadeDuration: Duration) {}

    func play(_ request: TrainingAudioPlaybackRequest) -> TrainingAudioPlaybackHandle? {
        playedResources.append(request.resource)
        let handle = TrainingAudioPlaybackHandle(rawValue: nextHandle)
        nextHandle += 1
        let supportsSpatialPlayback = request.channel != .coach
        activePlaybacks[handle] = Playback(
            resource: request.resource,
            channel: request.channel,
            rendering: spatialSceneAttached && supportsSpatialPlayback ? .spatial : .fallback
        )
        return handle
    }

    func stop(_ handle: TrainingAudioPlaybackHandle) {
        activePlaybacks[handle] = nil
    }

    func stop(channels: Set<TrainingAudioChannel>) {
        activePlaybacks = activePlaybacks.filter { !channels.contains($0.value.channel) }
    }

    func stopAll() {
        activePlaybacks.removeAll()
    }
    func beginVoiceCapture() throws {}
    func endVoiceCapture() {}
    func recoverPlaybackSession() throws {}
    func mediaServicesWereReset() throws {}

    func activePlayback(for resource: TrainingAudioResourceID) -> Playback? {
        activePlaybacks(for: resource).first
    }

    func activePlaybacks(for resource: TrainingAudioResourceID) -> [Playback] {
        activePlaybacks.values.filter { $0.resource == resource }
    }
}

@MainActor
final class IntegrationAudioResources: TrainingAudioResourceResolving {
    private let available: Set<TrainingAudioResourceID>

    init(available: Set<TrainingAudioResourceID>) {
        self.available = available
    }

    func url(for resource: TrainingAudioResourceID) -> URL? {
        available.contains(resource)
            ? URL(fileURLWithPath: "/tmp/\(resource.fileName).wav")
            : nil
    }
}

@MainActor
struct IntegrationImmediateAudioWaiter: TrainingAudioDecayWaiting {
    func wait(for duration: Duration) async throws {}
}
