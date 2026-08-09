import Foundation

nonisolated enum TrainingDemoRate: String, CaseIterable, Hashable, Sendable {
    case slower
    case normal
    case faster

    var playbackMultiplier: Double {
        switch self {
        case .slower: 0.65
        case .normal: 1
        case .faster: 1.25
        }
    }
}

nonisolated enum TrainingCommandConfirmation: String, Hashable, Sendable {
    case endTraining
    case participantHandoff
}

nonisolated enum TrainingCommandFollowUp: String, Hashable, Sendable {
    case confirmEnd
    case confirmParticipantHandoff
}

/// Proof that the target accepted and applied an intent. Action acknowledgement audio may be
/// routed only from this value, never directly from a raw transcript or parser match.
nonisolated struct TrainingCommandExecutionReceipt: Equatable, Sendable {
    let intent: VoiceIntent
    let generation: UInt64
    let response: String
    let followUp: TrainingCommandFollowUp?
}

nonisolated enum TrainingCommandExecutionRejection: Equatable, Sendable {
    case staleGeneration(expected: UInt64, actual: UInt64)
    case unavailableInState(intent: VoiceIntent, state: VoiceCommandState)
    case unavailableCapability(intent: VoiceIntent)
    case targetRejected(intent: VoiceIntent)
}

nonisolated enum TrainingCommandExecutionResult: Equatable, Sendable {
    case executed(TrainingCommandExecutionReceipt)
    case rejected(TrainingCommandExecutionRejection)

    var receipt: TrainingCommandExecutionReceipt? {
        guard case let .executed(receipt) = self else { return nil }
        return receipt
    }
}

/// The explicit mutation boundary between deterministic intent parsing and live training state.
/// Main-actor isolation makes session and flow mutation serial under the project's default actor.
@MainActor
protocol TrainingCommandTarget: AnyObject {
    var commandGeneration: UInt64 { get }
    var commandContext: VoiceCommandContext { get }

    func pauseForVoice() -> String?
    func resumeAfterFreshGuard() async -> String?
    func repeatDemo() -> String?
    func setDemoRate(_ rate: TrainingDemoRate) -> String?
    func advance() -> String?
    func requestCorrection() -> String?
    func requestGuardExplanation() -> String?
    func requestTargetHelp() -> String?
    func requestProgress() -> String?
    func requestHelp() -> String?
    func requestScore() -> String?
    func requestWhy() -> String?
    func requestLeaderboard() -> String?
    func requestEndConfirmation() -> String?
    func confirmEnd() async -> String?
    func cancelEndConfirmation() -> String?
    func requestParticipantHandoffConfirmation() -> String?
}

/// Revalidates state, capability, and generation at the instant of mutation. Parsing can occur
/// earlier, but a route change between parse and execution always fails closed here.
@MainActor
struct TrainingCommandExecutor {
    func execute(
        _ intent: VoiceIntent,
        issuedFor generation: UInt64,
        on target: any TrainingCommandTarget
    ) async -> TrainingCommandExecutionResult {
        guard generation == target.commandGeneration else {
            return .rejected(
                .staleGeneration(expected: target.commandGeneration, actual: generation)
            )
        }

        let context = target.commandContext
        guard intent.isAvailable(in: context.state) else {
            return .rejected(.unavailableInState(intent: intent, state: context.state))
        }
        guard context.capabilities.contains(intent.requiredCapability) else {
            return .rejected(.unavailableCapability(intent: intent))
        }

        let response: String?
        let followUp: TrainingCommandFollowUp?

        switch intent {
        case .pause:
            response = target.pauseForVoice()
            followUp = nil
        case .resume:
            response = await target.resumeAfterFreshGuard()
            followUp = nil
        case .requestEnd:
            response = target.requestEndConfirmation()
            followUp = response == nil ? nil : .confirmEnd
        case .confirmEnd:
            response = await target.confirmEnd()
            followUp = nil
        case .cancelEnd:
            response = target.cancelEndConfirmation()
            followUp = nil
        case .repeatDemo:
            response = target.repeatDemo()
            followUp = nil
        case .slower:
            response = target.setDemoRate(.slower)
            followUp = nil
        case .normalPace:
            response = target.setDemoRate(.normal)
            followUp = nil
        case .faster:
            response = target.setDemoRate(.faster)
            followUp = nil
        case .next:
            response = target.advance()
            followUp = nil
        case .correction:
            response = target.requestCorrection()
            followUp = nil
        case .guardExplanation:
            response = target.requestGuardExplanation()
            followUp = nil
        case .targetHelp:
            response = target.requestTargetHelp()
            followUp = nil
        case .progress:
            response = target.requestProgress()
            followUp = nil
        case .help:
            response = target.requestHelp()
            followUp = nil
        case .score:
            response = target.requestScore()
            followUp = nil
        case .why:
            response = target.requestWhy()
            followUp = nil
        case .leaderboard:
            response = target.requestLeaderboard()
            followUp = nil
        case .requestParticipantHandoff:
            response = target.requestParticipantHandoffConfirmation()
            followUp = response == nil ? nil : .confirmParticipantHandoff
        }

        guard let response else {
            return .rejected(.targetRejected(intent: intent))
        }
        return .executed(
            TrainingCommandExecutionReceipt(
                intent: intent,
                generation: generation,
                response: response,
                followUp: followUp
            )
        )
    }
}

/// Production adapter over the existing session and serialized flow coordinator. Task 5 can
/// construct this after on-device speech finalization without coupling capture to drill engines.
@MainActor
final class TrainingSessionCommandTarget: TrainingCommandTarget {
    private let flow: TrainingFlowCoordinator
    private let session: ReactiveStrikeSession
    private let showControlWindow: () -> Void
    private let dismissImmersive: () async -> Void

    init(
        flow: TrainingFlowCoordinator,
        session: ReactiveStrikeSession,
        showControlWindow: @escaping () -> Void,
        dismissImmersive: @escaping () async -> Void
    ) {
        self.flow = flow
        self.session = session
        self.showControlWindow = showControlWindow
        self.dismissImmersive = dismissImmersive
    }

    var commandGeneration: UInt64 { flow.commandGeneration }
    var commandContext: VoiceCommandContext {
        flow.voiceCommandContext(session: session)
    }

    func pauseForVoice() -> String? {
        switch flow.route {
        case .experience(.aura):
            return session.auraPunch.pauseForVoice()
        case .experience(.reactive), .experience(.reachCalibration),
             .experience(.competitionCalibration):
            return session.pauseForVoice()
        case .experience(.competition), .features, .reactiveSetup, .combinationSetup,
             .auraSetup:
            return nil
        }
    }

    func resumeAfterFreshGuard() async -> String? {
        let issuedGeneration = commandGeneration
        switch flow.route {
        case .experience(.aura):
            return await session.auraPunch.resumeAfterFreshGuard(
                commandIsCurrent: { [flow] in
                    flow.commandGeneration == issuedGeneration
                }
            )
        case .experience(.reactive), .experience(.reachCalibration),
             .experience(.competitionCalibration):
            return await session.resumeAfterFreshGuard(
                commandIsCurrent: { [flow] in
                    flow.commandGeneration == issuedGeneration
                }
            )
        case .experience(.competition), .features, .reactiveSetup, .combinationSetup,
             .auraSetup:
            return nil
        }
    }

    func repeatDemo() -> String? {
        guard case .experience(.aura) = flow.route else { return nil }
        return session.auraPunch.repeatDemo()
    }

    func setDemoRate(_ rate: TrainingDemoRate) -> String? {
        guard case .experience(.aura) = flow.route else { return nil }
        return session.auraPunch.setDemoRate(rate)
    }

    func advance() -> String? {
        guard case .experience(.aura) = flow.route else { return nil }
        return session.auraPunch.advanceDemo()
    }

    func requestCorrection() -> String? {
        switch flow.route {
        case .experience(.aura): return session.auraPunch.requestCorrection()
        case .experience: return session.requestCorrection()
        default: return nil
        }
    }

    func requestGuardExplanation() -> String? {
        switch flow.route {
        case .experience(.aura): return session.auraPunch.requestGuardExplanation()
        case .experience: return session.requestGuardExplanation()
        default: return nil
        }
    }

    func requestTargetHelp() -> String? {
        switch flow.route {
        case .experience(.aura): return session.auraPunch.requestTargetHelp()
        case .experience: return session.requestTargetHelp()
        default: return nil
        }
    }

    func requestProgress() -> String? {
        switch flow.route {
        case .experience(.aura): return session.auraPunch.requestProgress()
        case .experience: return session.requestProgress()
        default: return nil
        }
    }

    func requestHelp() -> String? {
        let names = commandContext.capabilities
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
        return names.isEmpty
            ? "Use the visible End Training control."
            : "Available commands: \(names)."
    }

    func requestScore() -> String? {
        switch flow.route {
        case .experience(.aura):
            guard let score = session.auraPunch.score else { return nil }
            return "Your score is \(Int(score.overall.rounded())) out of 100."
        case .experience:
            let percent = Int((session.metrics.accuracy * 100).rounded())
            return "Your accuracy is \(percent) percent."
        default:
            return nil
        }
    }

    func requestWhy() -> String? {
        switch flow.route {
        case .experience(.aura): return session.auraPunch.feedback?.whyItMatters
        case .experience: return session.lastFeedback
        default: return nil
        }
    }

    func requestLeaderboard() -> String? {
        "Use the visible leaderboard to review ranked results."
    }

    func requestEndConfirmation() -> String? {
        flow.requestEndConfirmation(issuedFor: commandGeneration)
    }

    func confirmEnd() async -> String? {
        await flow.confirmVoiceEnd(
            issuedFor: commandGeneration,
            session: session,
            showControlWindow: showControlWindow,
            dismissImmersive: dismissImmersive
        )
    }

    func cancelEndConfirmation() -> String? {
        flow.cancelEndConfirmation(issuedFor: commandGeneration)
    }

    func requestParticipantHandoffConfirmation() -> String? {
        flow.requestParticipantHandoffConfirmation(
            issuedFor: commandGeneration,
            session: session
        )
    }
}
