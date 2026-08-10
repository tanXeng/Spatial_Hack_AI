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
        let memory = InMemoryAthleteMemoryRepository()

        let root = BoxingCoachCompositionRoot(
            feedbackGenerator: MockFeedbackGenerator(),
            audioCoordinator: audio,
            speechClient: speech,
            flow: flow,
            competitionStore: store,
            athleteMemoryRepository: memory
        )

        #expect(root.flow === flow)
        #expect(root.competitionStore === store)
        #expect(root.athleteMemoryRepository === memory)
        #expect(root.audioCoordinator === audio)
        #expect(root.speechClient === speech)
        #expect(root.voiceCoach === root.session.voiceCoach)
        #expect(root.auraPunch === root.session.auraPunch)
        #expect(root.session.audioCoordinator === audio)
    }
}
