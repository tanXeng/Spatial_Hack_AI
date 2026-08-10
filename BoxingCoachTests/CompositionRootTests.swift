import Testing
@testable import BoxingCoach

@Suite("Application composition root")
@MainActor
struct CompositionRootTests {
    @Test("Both scenes receive one shared owner for session, flow, storage, voice, and audio")
    func sharedOwnersRetainTheirInjectedIdentity() {
        let audio = TrainingAudioCoordinator(
            backend: IntegrationRecordingAudioBackend(),
            resources: IntegrationAudioResources(available: []),
            decayWaiter: IntegrationImmediateAudioWaiter()
        )
        let speech = SpeechRecognitionClient()
        let flow = TrainingFlowCoordinator()
        let store = CompetitionStore(repository: InMemoryCompetitionRepository())
        let root = BoxingCoachCompositionRoot(
            feedbackGenerator: MockFeedbackGenerator(),
            audioCoordinator: audio,
            speechClient: speech,
            flow: flow,
            competitionStore: store
        )

        #expect(root.flow === flow)
        #expect(root.competitionStore === store)
        #expect(root.audioCoordinator === audio)
        #expect(root.speechClient === speech)
        #expect(root.voiceCoach === root.session.voiceCoach)
        #expect(root.auraPunch === root.session.auraPunch)
        #expect(root.session.audioCoordinator === audio)
    }
}
