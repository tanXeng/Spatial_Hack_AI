import Foundation
import Testing
@testable import BoxingCoach

@Suite("State-gated training command execution")
@MainActor
struct TrainingCommandExecutorTests {
    @Test(
        "Every intent is executed only in its literal approved states",
        arguments: TrainingCommandMatrixCase.all
    )
    func everyIntentUsesExactStateGate(testCase: TrainingCommandMatrixCase) async {
        let target = TrainingCommandTargetFixture(
            state: testCase.state,
            capabilities: Set(VoiceCommandCapability.allCases)
        )

        let result = await TrainingCommandExecutor().execute(
            testCase.intent,
            issuedFor: target.commandGeneration,
            on: target
        )

        if testCase.isAllowed {
            guard case let .executed(receipt) = result else {
                Issue.record("Expected an execution receipt for \(testCase.testDescription)")
                return
            }
            #expect(receipt.intent == testCase.intent)
            #expect(receipt.generation == 41)
            #expect(target.executedIntents == [testCase.intent])
        } else {
            #expect(
                result == .rejected(
                    .unavailableInState(intent: testCase.intent, state: testCase.state)
                )
            )
            #expect(target.executedIntents.isEmpty)
        }
    }

    @Test("An unavailable explicit capability cannot mutate training")
    func unavailableCapabilityRejectsBeforeMutation() async {
        let target = TrainingCommandTargetFixture(state: .learn, capabilities: [])

        let result = await TrainingCommandExecutor().execute(
            .pause,
            issuedFor: target.commandGeneration,
            on: target
        )

        #expect(result == .rejected(.unavailableCapability(intent: .pause)))
        #expect(target.executedIntents.isEmpty)
        #expect(target.isPaused == false)
    }

    @Test("A stale command generation cannot mutate a replacement route or session")
    func staleGenerationRejectsBeforeMutation() async {
        let target = TrainingCommandTargetFixture(
            state: .learn,
            capabilities: [.pause],
            generation: 42
        )

        let result = await TrainingCommandExecutor().execute(
            .pause,
            issuedFor: 41,
            on: target
        )

        #expect(result == .rejected(.staleGeneration(expected: 42, actual: 41)))
        #expect(target.executedIntents.isEmpty)
        #expect(target.isPaused == false)
    }

    @Test("An explicit end request creates confirmation without shutting down")
    func endRequestRequiresConfirmation() async throws {
        let target = TrainingCommandTargetFixture(
            state: .baseline,
            capabilities: [.requestEnd]
        )

        let result = await TrainingCommandExecutor().execute(
            .requestEnd,
            issuedFor: target.commandGeneration,
            on: target
        )

        let receipt = try #require(result.receipt)
        #expect(receipt.followUp == .confirmEnd)
        #expect(target.pendingConfirmation == .endTraining)
        #expect(target.didEndTraining == false)
    }

    @Test("Only confirm end runs serialized shutdown")
    func confirmEndRunsShutdown() async throws {
        let target = TrainingCommandTargetFixture(
            state: .awaitingEndConfirmation,
            capabilities: [.confirmEnd],
            pendingConfirmation: .endTraining
        )

        let result = await TrainingCommandExecutor().execute(
            .confirmEnd,
            issuedFor: target.commandGeneration,
            on: target
        )

        let receipt = try #require(result.receipt)
        #expect(receipt.intent == .confirmEnd)
        #expect(receipt.followUp == nil)
        #expect(target.didEndTraining)
        #expect(target.pendingConfirmation == nil)
    }

    @Test("Cancel end clears confirmation and preserves training")
    func cancelEndPreservesTraining() async {
        let target = TrainingCommandTargetFixture(
            state: .awaitingEndConfirmation,
            capabilities: [.cancelEnd],
            pendingConfirmation: .endTraining
        )

        let result = await TrainingCommandExecutor().execute(
            .cancelEnd,
            issuedFor: target.commandGeneration,
            on: target
        )

        #expect(result.receipt?.intent == .cancelEnd)
        #expect(target.pendingConfirmation == nil)
        #expect(target.didEndTraining == false)
    }

    @Test("Participant handoff is request-only and cannot clear participant state")
    func participantHandoffRequiresVisibleConfirmation() async throws {
        let target = TrainingCommandTargetFixture(
            state: .results,
            capabilities: [.requestParticipantHandoff]
        )

        let result = await TrainingCommandExecutor().execute(
            .requestParticipantHandoff,
            issuedFor: target.commandGeneration,
            on: target
        )

        let receipt = try #require(result.receipt)
        #expect(receipt.followUp == .confirmParticipantHandoff)
        #expect(target.pendingConfirmation == .participantHandoff)
        #expect(target.didResetParticipant == false)
    }

    @Test("Action acknowledgement exists only after the target accepts execution")
    func rejectedActionHasNoSuccessReceipt() async {
        let target = TrainingCommandTargetFixture(
            state: .learn,
            capabilities: [.pause]
        )
        target.rejectNextAction = true

        let result = await TrainingCommandExecutor().execute(
            .pause,
            issuedFor: target.commandGeneration,
            on: target
        )

        #expect(result == .rejected(.targetRejected(intent: .pause)))
        #expect(result.receipt == nil)
        #expect(target.isPaused == false)
    }

    @Test("Portable command values have explicit Sendable contracts")
    nonisolated func commandValuesAreSendable() {
        requireSendable(TrainingDemoRate.self)
        requireSendable(TrainingCommandConfirmation.self)
        requireSendable(TrainingCommandFollowUp.self)
        requireSendable(TrainingCommandExecutionReceipt.self)
        requireSendable(TrainingCommandExecutionRejection.self)
        requireSendable(TrainingCommandExecutionResult.self)
    }

    @Test("Voice pause invalidates an active reactive partial without recording a miss")
    func reactivePauseInvalidatesPartialWithoutMiss() {
        let session = ReactiveStrikeSession(coachAudio: SilentCommandCoachAudio())
        session.startDrill()
        defer {
            session.stopDrill()
            session.hands.stop()
        }
        let attemptsBeforePause = session.metrics.attempts.count

        let response = session.pauseForVoice()

        #expect(response != nil)
        #expect(session.isVoicePaused)
        #expect(session.isTrackingPaused)
        #expect(session.voicePauseInvalidationCount == 1)
        #expect(session.metrics.attempts.count == attemptsBeforePause)
    }

    @Test("Resume rejects before countdown unless tracking is running with fresh guard")
    func reactiveResumeRequiresTrackingAndFreshGuard() async {
        let session = ReactiveStrikeSession(coachAudio: SilentCommandCoachAudio())
        session.startDrill()
        defer {
            session.stopDrill()
            session.hands.stop()
        }
        _ = session.pauseForVoice()
        var countdownValues: [Int] = []

        let response = await session.resumeAfterFreshGuard { count in
            countdownValues.append(count)
        }

        #expect(response == nil)
        #expect(countdownValues.isEmpty)
        #expect(session.isVoicePaused)
        #expect(session.metrics.attempts.isEmpty)
    }

    @Test("Live progress is derived from the active session counts")
    func liveTargetReportsStateDerivedProgress() async throws {
        let flow = TrainingFlowCoordinator()
        let session = ReactiveStrikeSession(coachAudio: SilentCommandCoachAudio())
        let selection = TrainingSelection.reactive(
            mode: .air,
            combination: nil,
            stance: .orthodox
        )
        flow.navigate(to: .experience(selection))
        session.startDrill()
        defer {
            session.stopDrill()
            session.hands.stop()
        }
        let target = TrainingSessionCommandTarget(
            flow: flow,
            session: session,
            showControlWindow: {},
            dismissImmersive: {}
        )

        let result = await TrainingCommandExecutor().execute(
            .progress,
            issuedFor: target.commandGeneration,
            on: target
        )

        let receipt = try #require(result.receipt)
        #expect(receipt.response == "Calibration")
    }

    @Test("Ranked time exposes no voice capabilities while route generation remains current")
    func rankedTargetDisablesCustomVoiceAndPause() throws {
        let flow = TrainingFlowCoordinator()
        let session = ReactiveStrikeSession(coachAudio: SilentCommandCoachAudio())
        let reach = try #require(BilateralReach(left: 0.5, right: 0.5))
        flow.navigate(
            to: .experience(
                .competition(
                    playerID: UUID(),
                    mode: .reactiveStrike,
                    stance: .orthodox,
                    reach: reach
                )
            )
        )
        let target = TrainingSessionCommandTarget(
            flow: flow,
            session: session,
            showControlWindow: {},
            dismissImmersive: {}
        )

        #expect(target.commandContext.state == .ranked)
        #expect(target.commandContext.capabilities.isEmpty)
    }

    @Test("A route change advances command generation and clears confirmation")
    func routeChangeInvalidatesPendingCommands() {
        let flow = TrainingFlowCoordinator()
        let initialGeneration = flow.commandGeneration
        flow.navigate(to: .auraSetup)
        let auraGeneration = flow.commandGeneration
        flow.navigate(
            to: .experience(.aura(technique: .jab, stance: .orthodox))
        )
        #expect(flow.requestEndConfirmation(issuedFor: flow.commandGeneration) != nil)

        flow.navigate(to: .features)

        #expect(auraGeneration > initialGeneration)
        #expect(flow.commandGeneration > auraGeneration)
        #expect(flow.pendingVoiceConfirmation == nil)
    }

    @Test("Stale end request cannot enter confirmation on a replacement route")
    func staleEndRequestCannotMutateFlow() {
        let flow = TrainingFlowCoordinator()
        flow.navigate(
            to: .experience(.aura(technique: .jab, stance: .orthodox))
        )
        let staleGeneration = flow.commandGeneration
        flow.navigate(to: .features)

        let response = flow.requestEndConfirmation(issuedFor: staleGeneration)

        #expect(response == nil)
        #expect(flow.pendingVoiceConfirmation == nil)
        #expect(flow.route == .features)
    }

    @Test("Confirmed voice end uses coordinator shutdown and stops the engine")
    func confirmedEndUsesSerializedFlowShutdown() async {
        let flow = TrainingFlowCoordinator()
        let session = ReactiveStrikeSession(coachAudio: SilentCommandCoachAudio())
        let selection = TrainingSelection.reactive(
            mode: .air,
            combination: nil,
            stance: .orthodox
        )
        flow.navigate(to: .experience(selection))
        session.startDrill()
        defer {
            session.stopDrill()
            session.hands.stop()
        }
        let generation = flow.commandGeneration
        #expect(flow.requestEndConfirmation(issuedFor: generation) != nil)
        var showCount = 0
        var dismissCount = 0

        let response = await flow.confirmVoiceEnd(
            issuedFor: generation,
            session: session,
            showControlWindow: { showCount += 1 },
            dismissImmersive: { dismissCount += 1 }
        )

        #expect(response != nil)
        #expect(session.phase == .idle)
        #expect(flow.pendingVoiceConfirmation == nil)
        #expect(flow.transition == .idle)
        #expect(showCount == 0)
        #expect(dismissCount == 0)
    }

    nonisolated private func requireSendable<T: Sendable>(_: T.Type) {}
}

@MainActor
private final class SilentCommandCoachAudio: CoachAudioPlaying {
    func prepare() {}
    func play(id: CoachClipID) {}
    func stop() {}
}

@MainActor
final class TrainingCommandTargetFixture: TrainingCommandTarget {
    let commandGeneration: UInt64
    var commandContext: VoiceCommandContext
    var executedIntents: [VoiceIntent] = []
    var isPaused = false
    var demoRate: TrainingDemoRate = .normal
    var pendingConfirmation: TrainingCommandConfirmation?
    var didEndTraining = false
    var didResetParticipant = false
    var rejectNextAction = false

    init(
        state: VoiceCommandState,
        capabilities: Set<VoiceCommandCapability>,
        generation: UInt64 = 41,
        pendingConfirmation: TrainingCommandConfirmation? = nil
    ) {
        commandGeneration = generation
        commandContext = VoiceCommandContext(state: state, capabilities: capabilities)
        self.pendingConfirmation = pendingConfirmation
            ?? (state == .awaitingEndConfirmation ? .endTraining : nil)
    }

    func pauseForVoice() -> String? {
        accept(.pause) { isPaused = true }
    }

    func resumeAfterFreshGuard() async -> String? {
        accept(.resume) { isPaused = false }
    }

    func repeatDemo() -> String? {
        accept(.repeatDemo)
    }

    func setDemoRate(_ rate: TrainingDemoRate) -> String? {
        let intent: VoiceIntent = switch rate {
        case .slower: .slower
        case .normal: .normalPace
        case .faster: .faster
        }
        return accept(intent) { demoRate = rate }
    }

    func advance() -> String? { accept(.next) }
    func requestCorrection() -> String? { accept(.correction) }
    func requestGuardExplanation() -> String? { accept(.guardExplanation) }
    func requestTargetHelp() -> String? { accept(.targetHelp) }
    func requestProgress() -> String? { accept(.progress) }
    func requestHelp() -> String? { accept(.help) }
    func requestScore() -> String? { accept(.score) }
    func requestWhy() -> String? { accept(.why) }
    func requestLeaderboard() -> String? { accept(.leaderboard) }

    func requestEndConfirmation() -> String? {
        accept(.requestEnd) { pendingConfirmation = .endTraining }
    }

    func confirmEnd() async -> String? {
        guard pendingConfirmation == .endTraining else { return nil }
        return accept(.confirmEnd) {
            pendingConfirmation = nil
            didEndTraining = true
        }
    }

    func cancelEndConfirmation() -> String? {
        guard pendingConfirmation == .endTraining else { return nil }
        return accept(.cancelEnd) { pendingConfirmation = nil }
    }

    func requestParticipantHandoffConfirmation() -> String? {
        accept(.requestParticipantHandoff) {
            pendingConfirmation = .participantHandoff
        }
    }

    private func accept(_ intent: VoiceIntent, mutation: () -> Void = {}) -> String? {
        guard !rejectNextAction else {
            rejectNextAction = false
            return nil
        }
        mutation()
        executedIntents.append(intent)
        return "Executed \(intent.rawValue)"
    }
}

nonisolated struct TrainingCommandMatrixCase: Sendable, CustomTestStringConvertible {
    let intent: VoiceIntent
    let state: VoiceCommandState
    let isAllowed: Bool

    var testDescription: String { "\(intent.rawValue)-\(state.rawValue)" }

    static let approvedStates: [VoiceIntent: Set<VoiceCommandState>] = [
        .pause: [.learn, .baseline, .correction, .retest, .transfer],
        .resume: [.trackingPaused],
        .requestEnd: [.learn, .baseline, .correction, .retest, .transfer, .results, .trackingPaused],
        .confirmEnd: [.awaitingEndConfirmation],
        .cancelEnd: [.awaitingEndConfirmation],
        .repeatDemo: [.learn, .correction],
        .slower: [.learn, .correction],
        .normalPace: [.learn, .correction],
        .faster: [.learn, .correction],
        .next: [.learn, .correction, .results],
        .correction: [.baseline, .correction, .retest, .results],
        .guardExplanation: [.learn, .baseline, .correction, .retest, .transfer, .trackingPaused],
        .targetHelp: [.learn, .baseline, .correction, .retest, .transfer],
        .progress: [.learn, .baseline, .correction, .retest, .transfer, .results],
        .help: [.idle, .learn, .baseline, .correction, .retest, .transfer, .results, .trackingPaused, .awaitingEndConfirmation],
        .score: [.results],
        .why: [.correction, .retest, .results],
        .leaderboard: [.idle, .results],
        .requestParticipantHandoff: [.results]
    ]

    static let all: [Self] = VoiceIntent.allCases.flatMap { intent in
        VoiceCommandState.allCases.map { state in
            Self(
                intent: intent,
                state: state,
                isAllowed: approvedStates[intent, default: []].contains(state)
            )
        }
    }
}
