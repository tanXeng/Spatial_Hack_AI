import Foundation
import RealityKit
import Testing
@testable import BoxingCoach

@Suite("Spatial training audio integration")
@MainActor
struct TrainingAudioIntegrationTests {
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

    @Test("Stage transitions drive bells, improvement, crowd, and winner celebration once")
    func semanticStagesOwnRingAccents() async {
        let backend = IntegrationRecordingAudioBackend()
        let coordinator = makeCoordinator(
            backend: backend,
            resources: IntegrationAudioResources(available: [
                .competitionCrowd,
                .startBell,
                .endBell,
                .improvementSting,
                .winnerSwell
            ])
        )

        await coordinator.handle(.sceneDidAttach(.immersiveSpace))
        await coordinator.handle(.experienceDidEnter(.compete))
        await coordinator.handle(.experienceDidEnter(.compete))
        await coordinator.handle(.experienceDidEnter(.celebrate))
        await coordinator.handle(.experienceDidEnter(.celebrate))

        #expect(backend.playedResources.filter { $0 == .startBell }.count == 1)
        #expect(backend.playedResources.filter { $0 == .endBell }.count == 1)
        #expect(backend.playedResources.filter { $0 == .winnerSwell }.count == 1)
        #expect(backend.playedResources.filter { $0 == .competitionCrowd }.count == 1)
        #expect(backend.playedResources.contains(.improvementSting) == false)
        #expect(coordinator.presentation.caption == "Winner confirmed. Round complete.")
        #expect(coordinator.presentation.symbolName == "trophy.fill")
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
private final class IntegrationRecordingAudioBackend: TrainingAudioBackend {
    var playbackDidFinish: ((TrainingAudioPlaybackHandle) -> Void)?
    var systemEventHandler: ((TrainingAudioSystemEvent) -> Void)?
    private(set) var playedResources: [TrainingAudioResourceID] = []
    private var nextHandle = 1

    func attachScene() throws {}
    func detachScene() {}
    func attachSpatialScene(worldRoot: Entity, bodyAnchor: Entity) {}
    func detachSpatialScene() {}
    func apply(mix: TrainingAudioMix, fadeDuration: Duration) {}

    func play(_ request: TrainingAudioPlaybackRequest) -> TrainingAudioPlaybackHandle? {
        playedResources.append(request.resource)
        defer { nextHandle += 1 }
        return TrainingAudioPlaybackHandle(rawValue: nextHandle)
    }

    func stop(_ handle: TrainingAudioPlaybackHandle) {}
    func stop(channels: Set<TrainingAudioChannel>) {}
    func stopAll() {}
    func beginVoiceCapture() throws {}
    func endVoiceCapture() {}
    func recoverPlaybackSession() throws {}
    func mediaServicesWereReset() throws {}
}

@MainActor
private final class IntegrationAudioResources: TrainingAudioResourceResolving {
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
private struct IntegrationImmediateAudioWaiter: TrainingAudioDecayWaiting {
    func wait(for duration: Duration) async throws {}
}
