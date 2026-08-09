import Foundation

nonisolated enum VoiceIntent: String, CaseIterable, Hashable, Sendable {
    case pause
    case resume
    case requestEnd
    case confirmEnd
    case cancelEnd
    case repeatDemo
    case slower
    case normalPace
    case faster
    case next
    case correction
    case guardExplanation
    case targetHelp
    case progress
    case help
    case score
    case why
    case leaderboard
    /// Requests a confirmation-gated handoff. This never authorizes participant-state clearing.
    case requestParticipantHandoff

    var requiredCapability: VoiceCommandCapability {
        switch self {
        case .pause: .pause
        case .resume: .resume
        case .requestEnd: .requestEnd
        case .confirmEnd: .confirmEnd
        case .cancelEnd: .cancelEnd
        case .repeatDemo: .repeatDemo
        case .slower: .slower
        case .normalPace: .normalPace
        case .faster: .faster
        case .next: .next
        case .correction: .correction
        case .guardExplanation: .guardExplanation
        case .targetHelp: .targetHelp
        case .progress: .progress
        case .help: .help
        case .score: .score
        case .why: .why
        case .leaderboard: .leaderboard
        case .requestParticipantHandoff: .requestParticipantHandoff
        }
    }

    func isAvailable(in state: VoiceCommandState) -> Bool {
        switch self {
        case .pause:
            [.learn, .baseline, .correction, .retest, .transfer].contains(state)
        case .resume:
            state == .trackingPaused
        case .requestEnd:
            [.learn, .baseline, .correction, .retest, .transfer, .results, .trackingPaused]
                .contains(state)
        case .confirmEnd, .cancelEnd:
            state == .awaitingEndConfirmation
        case .repeatDemo, .slower, .normalPace, .faster:
            [.learn, .correction].contains(state)
        case .next:
            [.learn, .correction, .results].contains(state)
        case .correction:
            [.baseline, .correction, .retest, .results].contains(state)
        case .guardExplanation:
            [.learn, .baseline, .correction, .retest, .transfer, .trackingPaused]
                .contains(state)
        case .targetHelp:
            [.learn, .baseline, .correction, .retest, .transfer].contains(state)
        case .progress:
            [.learn, .baseline, .correction, .retest, .transfer, .results].contains(state)
        case .help:
            state != .ranked
        case .score:
            state == .results
        case .why:
            [.correction, .retest, .results].contains(state)
        case .leaderboard:
            [.idle, .results].contains(state)
        case .requestParticipantHandoff:
            state == .results
        }
    }
}

nonisolated enum VoiceRecognitionConfidence: String, Hashable, Sendable {
    case high
    case medium
    case low
}

nonisolated struct VoiceUtterance: Equatable, Sendable {
    let transcript: String
    let localeIdentifier: String
    let isFinal: Bool
    let confidence: VoiceRecognitionConfidence
}

nonisolated enum VoiceCommandState: String, CaseIterable, Hashable, Sendable {
    case idle
    case learn
    case baseline
    case correction
    case retest
    case transfer
    case ranked
    case results
    case trackingPaused
    case awaitingEndConfirmation
}

nonisolated enum VoiceCommandCapability: String, CaseIterable, Hashable, Sendable {
    case pause
    case resume
    case requestEnd
    case confirmEnd
    case cancelEnd
    case repeatDemo
    case slower
    case normalPace
    case faster
    case next
    case correction
    case guardExplanation
    case targetHelp
    case progress
    case help
    case score
    case why
    case leaderboard
    case requestParticipantHandoff
}

nonisolated struct VoiceCommandContext: Equatable, Sendable {
    let state: VoiceCommandState
    let capabilities: Set<VoiceCommandCapability>
}

nonisolated struct VoiceIntentMatch: Equatable, Sendable {
    let intent: VoiceIntent
    let normalizedPhrase: String
    let confidence: VoiceRecognitionConfidence
}

nonisolated enum VoiceIntentRejectionReason: Equatable, Sendable {
    case emptyInput
    case incompleteUtterance
    case lowConfidence
    case unsupportedLocale
    case ambiguous
    case unrecognized
    case unavailableInState(intent: VoiceIntent, state: VoiceCommandState)
    case unavailableCapability(intent: VoiceIntent)
}

nonisolated struct VoiceIntentRejection: Equatable, Sendable {
    let normalizedPhrase: String
    let confidence: VoiceRecognitionConfidence
    let reason: VoiceIntentRejectionReason
    let recoveryMessage: String
}

nonisolated enum VoiceIntentParseResult: Equatable, Sendable {
    case accepted(VoiceIntentMatch)
    case rejected(VoiceIntentRejection)

    var acceptedIntent: VoiceIntent? {
        guard case let .accepted(match) = self else { return nil }
        return match.intent
    }
}
