import Foundation
import Observation

/// Owns the single live instance of every cross-scene state boundary.
///
/// Window and immersive views receive these exact owners through the environment. Keeping their
/// construction here prevents a restored scene from silently creating a second audio, speech,
/// flow, or persistence pipeline.
@Observable
@MainActor
final class BoxingCoachCompositionRoot {
    let session: ReactiveStrikeSession
    let flow: TrainingFlowCoordinator
    let competitionStore: CompetitionStore
    let audioCoordinator: TrainingAudioCoordinator
    let speechClient: any SpeechRecognizing
    let relayClient: CoachRelayClient

    var voiceCoach: CoachVoiceCoach { session.voiceCoach }
    var auraPunch: AuraPunchSession { session.auraPunch }

    init(
        feedbackGenerator: any FeedbackGenerating,
        audioCoordinator: TrainingAudioCoordinator,
        speechClient: any SpeechRecognizing,
        flow: TrainingFlowCoordinator,
        competitionStore: CompetitionStore,
        relayClient: CoachRelayClient = CoachRelayClient(endpoint: nil)
    ) {
        self.flow = flow
        self.competitionStore = competitionStore
        self.audioCoordinator = audioCoordinator
        self.speechClient = speechClient
        self.relayClient = relayClient
        session = ReactiveStrikeSession(
            feedbackGenerator: feedbackGenerator,
            audioCoordinator: audioCoordinator,
            speechClient: speechClient
        )
    }

    static func live() -> BoxingCoachCompositionRoot {
        let audioCoordinator = TrainingAudioCoordinator()
        let speechClient = SpeechRecognitionClient()
        let relayClient = CoachRelayClient(endpoint: CoachSecrets.relayEndpoint)
        let feedbackGenerator = RelayFeedbackGenerator(
            client: relayClient,
            context: CoachRelayFeedbackContext(locale: Locale.current.identifier)
        )

        do {
            let container = try CompetitionModelContainer.make(inMemory: false)
            return BoxingCoachCompositionRoot(
                feedbackGenerator: feedbackGenerator,
                audioCoordinator: audioCoordinator,
                speechClient: speechClient,
                flow: TrainingFlowCoordinator(),
                competitionStore: CompetitionStore(
                    repository: CompetitionLiveRepositoryFactory.makeLiveRepository(
                        container: container
                    )
                ),
                relayClient: relayClient
            )
        } catch {
            return BoxingCoachCompositionRoot(
                feedbackGenerator: feedbackGenerator,
                audioCoordinator: audioCoordinator,
                speechClient: speechClient,
                flow: TrainingFlowCoordinator(),
                competitionStore: CompetitionStore(
                    repository: InMemoryCompetitionRepository(),
                    startupError: "Saved competition data is unavailable. Results will last only until the app closes.",
                    coachingCyclePersistenceScope: .sessionOnly
                ),
                relayClient: relayClient
            )
        }
    }
}
