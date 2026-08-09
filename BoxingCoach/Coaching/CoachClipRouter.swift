import Foundation

/// Chooses an authored response only after a typed voice intent has been accepted and executed.
nonisolated struct CoachClipRouter: Sendable {
    func responseClip(after intent: VoiceIntent) -> CoachClipID? {
        switch intent {
        case .correction:
            .qaWhatFix
        case .guardExplanation:
            .qaWhyGuard
        case .repeatDemo:
            .qaRepeatDemo
        case .slower:
            .qaSlower
        case .targetHelp:
            .qaHitTarget
        case .progress:
            .qaThreePunches
        case .pause:
            .pauseAck
        case .resume:
            .resumeAck
        case .help:
            .helpCommands
        case .requestEnd, .confirmEnd, .cancelEnd, .normalPace, .faster, .next, .score,
             .why, .leaderboard, .participantHandoff:
            nil
        }
    }

    /// Transitional entry point for the existing Ask Coach facade. It is intentionally limited
    /// to informational intents so raw speech can never claim that a session action executed.
    func resolve(transcript: String, context: CoachVoiceContext) async -> CoachClipID {
        let commandContext = Self.commandContext(from: context)
        let result = VoiceIntentParser().parse(
            VoiceUtterance(
                transcript: transcript,
                localeIdentifier: "en-US",
                isFinal: true,
                confidence: .high
            ),
            in: commandContext
        )
        guard let intent = result.acceptedIntent,
              Self.legacyInformationalIntents.contains(intent) else {
            return .didntCatch
        }
        return responseClip(after: intent) ?? .didntCatch
    }

    private static let legacyInformationalIntents: Set<VoiceIntent> = [
        .correction,
        .guardExplanation,
        .targetHelp,
        .progress,
        .help
    ]

    private static func commandContext(from context: CoachVoiceContext) -> VoiceCommandContext {
        let state = commandState(from: context)
        let capabilities = Set(
            VoiceIntent.allCases
                .filter { $0.isAvailable(in: state) }
                .map(\.requiredCapability)
        )
        return VoiceCommandContext(state: state, capabilities: capabilities)
    }

    private static func commandState(from context: CoachVoiceContext) -> VoiceCommandState {
        switch context.feature {
        case .auraPunch:
            switch context.auraPhase {
            case .idle, nil:
                .idle
            case .acquiring, .guiding, .countdown:
                .learn
            case .attempting:
                .baseline
            case .scoring, .results:
                .results
            }
        case .reactiveStrike:
            switch context.drillPhase {
            case .idle, nil:
                .idle
            case .calibrating, .running:
                .transfer
            case .finished:
                .results
            }
        }
    }
}
