import Foundation

enum TrainingFeature: String, CaseIterable, Identifiable, Hashable, Sendable {
    case auraPunch
    case reactiveStrike

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auraPunch: return "Aura Punch"
        case .reactiveStrike: return "Reactive Strike"
        }
    }

    var subtitle: String {
        switch self {
        case .auraPunch: return "Follow a spatial punch guide"
        case .reactiveStrike: return "Hit floating targets on reaction"
        }
    }

    var isAvailable: Bool { true }
}

enum TrainingSelection: Hashable, Sendable {
    case reactive(mode: ReactiveStrikeMode, combination: Combination?, stance: Stance)
    case aura(technique: Technique, stance: Stance)
    case reachCalibration
    case competitionCalibration(playerID: UUID)
    case competition(playerID: UUID, mode: CompetitionMode, stance: Stance, reach: BilateralReach)

    var feature: TrainingFeature {
        switch self {
        case .reactive, .reachCalibration, .competitionCalibration, .competition:
            return .reactiveStrike
        case .aura: return .auraPunch
        }
    }
}

enum TrainingFlowRoute: Hashable, Sendable {
    case features
    case reactiveSetup
    case combinationSetup
    case auraSetup
    case experience(TrainingSelection)
}

enum TrainingFlowTransition: String, Sendable {
    case idle
    case openingImmersion
    case closingImmersion
}

enum ImmersiveOpenOutcome: Sendable {
    case opened
    case cancelled
    case failed(String)
}

private enum ImmersiveSceneState: Sendable {
    case closed
    case opening
    case ready
    case closing
}

/// Owns window navigation and serializes every immersive-space transition.
///
/// Selection and experience views only emit user intent. They never open a scene, dismiss one,
/// or mutate a drill engine directly, which keeps overlapping SwiftUI tasks from racing each
/// other and leaving the app in a half-open state.
@Observable
@MainActor
final class TrainingFlowCoordinator {
    private(set) var route: TrainingFlowRoute = .features
    private(set) var transition: TrainingFlowTransition = .idle
    private(set) var presentationError: String?
    private(set) var draftStance: Stance = .orthodox
    private(set) var commandGeneration: UInt64 = 1
    private(set) var pendingVoiceConfirmation: TrainingCommandConfirmation?

    private var immersiveState: ImmersiveSceneState = .closed
    private var isControlWindowVisible = false
    private let readinessTimeout: Duration = .seconds(5)
    private let controlWindowReadinessTimeout: Duration = .seconds(2)

    var controlsDisabled: Bool {
        transition != .idle
    }

    func navigate(to route: TrainingFlowRoute) {
        guard transition == .idle else { return }
        presentationError = nil
        setRoute(route)
    }

    func chooseFeature(_ feature: TrainingFeature) {
        guard transition == .idle else { return }
        presentationError = nil

        switch feature {
        case .reactiveStrike:
            setRoute(.reactiveSetup)
        case .auraPunch:
            setRoute(.auraSetup)
        }
    }

    func setDraftStance(_ stance: Stance) {
        guard transition == .idle else { return }
        draftStance = stance
    }

    func controlWindowDidAppear() {
        isControlWindowVisible = true
    }

    func controlWindowDidDisappear() {
        isControlWindowVisible = false
    }

    func chooseReactiveMode(_ mode: ReactiveStrikeMode) {
        guard transition == .idle else { return }
        presentationError = nil
        if mode == .combination {
            setRoute(.combinationSetup)
        } else {
            setRoute(.experience(.reactive(mode: mode, combination: nil, stance: draftStance)))
        }
    }

    func chooseCombination(_ combination: Combination) {
        guard transition == .idle else { return }
        presentationError = nil
        setRoute(.experience(
            .reactive(mode: .combination, combination: combination, stance: draftStance)
        ))
    }

    func chooseAuraTechnique(_ technique: Technique) {
        guard transition == .idle, technique.isImplemented else { return }
        presentationError = nil
        setRoute(.experience(.aura(technique: technique, stance: draftStance)))
    }

    func backFromSetup() {
        guard transition == .idle else { return }
        presentationError = nil
        if route == .combinationSetup {
            setRoute(.reactiveSetup)
        } else {
            setRoute(.features)
        }
    }

    func startExperience(
        _ selection: TrainingSelection,
        session: ReactiveStrikeSession,
        supportsMultipleScenes: Bool,
        openImmersive: (String) async -> ImmersiveOpenOutcome,
        dismissImmersive: () async -> Void,
        hideControlWindow: () -> Void
    ) async {
        guard transition == .idle,
              route == .experience(selection) else { return }

        presentationError = nil
        transition = .openingImmersion

        guard supportsMultipleScenes else {
            presentationError = "Multiple scenes are disabled. Enable multiple-scene support to start training."
            transition = .idle
            return
        }

        if immersiveState != .ready || !session.isImmersiveSpaceOpen {
            immersiveState = .opening
            switch await openImmersive(session.immersiveSpaceID) {
            case .opened:
                break
            case .cancelled:
                immersiveState = .closed
                presentationError = "Immersive space cancelled."
                transition = .idle
                return
            case .failed(let message):
                immersiveState = .closed
                presentationError = message
                transition = .idle
                return
            }
        }

        guard await waitForSceneReadiness() else {
            presentationError = "The training space opened but did not become ready. Close it and try again."
            transition = .closingImmersion
            immersiveState = .closing
            await dismissImmersive()
            finalizeImmersiveClosure(session: session)
            transition = .idle
            return
        }

        // Apply the committed selection only after the scene is usable. A failed retry therefore
        // leaves the previous score/results intact instead of erasing useful feedback.
        session.prepareForTrainingStart()
        switch selection {
        case .reactive(let mode, let combination, let stance):
            session.configure(mode: mode, combination: combination, stance: stance)
            if session.phase == .finished {
                session.resetForNewRound()
            }
            session.startDrill()

        case .aura(let technique, let stance):
            session.auraPunch.technique = technique
            session.auraPunch.stance = stance
            session.auraPunch.reset()
            session.auraPunch.start()

        case .reachCalibration:
            session.configureReachCalibration()
            session.resetForNewRound(keepingCompetitionConfiguration: true)
            session.startDrill()

        case .competitionCalibration:
            session.configureCompetitionCalibration()
            session.resetForNewRound(keepingCompetitionConfiguration: true)
            session.startDrill()

        case .competition(_, let mode, let stance, let reach):
            session.configureCompetition(mode: mode, stance: stance, reach: reach)
            session.resetForNewRound(keepingCompetitionConfiguration: true)
            session.startDrill()
        }

        invalidateCommands()

        transition = .idle
        hideControlWindow()
        // The SwiftUI disappearance callback can arrive on a later update. Mark the requested
        // state immediately so the eventual restore waits for a fresh appearance event.
        isControlWindowVisible = false
    }

    func endExperience(
        session: ReactiveStrikeSession,
        showControlWindow: () -> Void,
        dismissImmersive: () async -> Void
    ) async {
        guard transition == .idle else { return }
        invalidateCommands()
        presentationError = nil
        transition = .closingImmersion

        if hasActiveImmersiveScene(session: session) {
            // Cancellation takes effect when the user taps, not after window restoration. Leaving
            // an engine alive during that wait can record another hit/miss or finish scoring after
            // the user explicitly ended training.
            session.stopDrill()
            showControlWindow()
            guard await waitForControlWindowReadiness() else {
                presentationError = "Could not restore the results window. Try End Training again."
                transition = .idle
                return
            }
            immersiveState = .closing
            await dismissImmersive()
            finalizeImmersiveClosure(session: session)
        } else {
            session.stopDrill()
        }

        transition = .idle
    }

    func finishExperience(
        session: ReactiveStrikeSession,
        showControlWindow: () -> Void,
        dismissImmersive: () async -> Void
    ) async {
        guard transition == .idle,
              hasActiveImmersiveScene(session: session) else { return }

        presentationError = nil
        transition = .closingImmersion
        showControlWindow()
        guard await waitForControlWindowReadiness() else {
            presentationError = "Could not restore the results window. Use End Training to try again."
            transition = .idle
            return
        }
        immersiveState = .closing
        await dismissImmersive()
        finalizeImmersiveClosure(session: session)
        transition = .idle
    }

    func returnToSetup(
        from selection: TrainingSelection,
        session: ReactiveStrikeSession,
        dismissImmersive: () async -> Void
    ) async {
        guard transition == .idle,
              route == .experience(selection) else { return }

        transition = .closingImmersion
        if hasActiveImmersiveScene(session: session) {
            immersiveState = .closing
            await dismissImmersive()
            finalizeImmersiveClosure(session: session)
        } else {
            session.stopDrill()
        }

        switch selection {
        case .reactive(let mode, _, let stance):
            draftStance = stance
            session.resetForNewRound()
            setRoute(mode == .combination ? .combinationSetup : .reactiveSetup)
        case .aura(_, let stance):
            draftStance = stance
            session.auraPunch.reset()
            setRoute(.auraSetup)

        case .reachCalibration, .competitionCalibration, .competition:
            session.resetForNewRound()
            setRoute(.features)
        }

        presentationError = nil
        transition = .idle
    }

    /// Called by the immersive RealityView only after its scene root has been attached.
    func immersiveSceneDidBecomeReady(session: ReactiveStrikeSession) {
        guard immersiveState != .closing else { return }
        immersiveState = .ready
        session.immersiveSpaceDidOpen()
    }

    /// Handles both explicit dismissal and the system taking the immersive space away.
    func immersiveSceneDidClose(session: ReactiveStrikeSession) {
        finalizeImmersiveClosure(session: session)
    }

    func voiceCommandState(session: ReactiveStrikeSession) -> VoiceCommandState {
        if pendingVoiceConfirmation == .endTraining {
            return .awaitingEndConfirmation
        }

        switch route {
        case .experience(.competition):
            return .ranked
        case .experience(.aura):
            if session.auraPunch.isVoicePaused { return .trackingPaused }
            switch session.auraPunch.phase {
            case .idle: return .idle
            case .acquiring, .guiding: return .learn
            case .countdown, .attempting: return .baseline
            case .scoring, .results: return .results
            }
        case .experience(.reactive), .experience(.reachCalibration),
             .experience(.competitionCalibration):
            if session.isVoicePaused || session.isTrackingPaused { return .trackingPaused }
            switch session.phase {
            case .idle: return .idle
            case .calibrating, .running: return .baseline
            case .finished: return .results
            }
        case .features, .reactiveSetup, .combinationSetup, .auraSetup:
            return .idle
        }
    }

    func voiceCommandContext(session: ReactiveStrikeSession) -> VoiceCommandContext {
        let state = voiceCommandState(session: session)
        let capabilities: Set<VoiceCommandCapability>
        switch state {
        case .idle:
            capabilities = [.help, .leaderboard]
        case .learn:
            capabilities = [
                .pause, .requestEnd, .repeatDemo, .slower, .normalPace, .faster,
                .next, .guardExplanation, .targetHelp, .progress, .help
            ]
        case .baseline, .retest, .transfer:
            capabilities = [
                .pause, .requestEnd, .correction, .guardExplanation, .targetHelp,
                .progress, .help
            ]
        case .correction:
            capabilities = [
                .pause, .requestEnd, .repeatDemo, .slower, .normalPace, .faster,
                .next, .correction, .guardExplanation, .targetHelp, .progress, .help, .why
            ]
        case .ranked:
            capabilities = []
        case .results:
            capabilities = [
                .requestEnd, .next, .correction, .progress, .help, .score, .why,
                .leaderboard, .requestParticipantHandoff
            ]
        case .trackingPaused:
            capabilities = [.resume, .requestEnd, .guardExplanation, .help]
        case .awaitingEndConfirmation:
            capabilities = [.confirmEnd, .cancelEnd, .help]
        }
        return VoiceCommandContext(state: state, capabilities: capabilities)
    }

    @discardableResult
    func requestEndConfirmation(issuedFor generation: UInt64) -> String? {
        guard generation == commandGeneration,
              transition == .idle,
              pendingVoiceConfirmation == nil,
              case let .experience(selection) = route else { return nil }
        if case .competition = selection { return nil }
        pendingVoiceConfirmation = .endTraining
        return "End training? Say confirm end, or say cancel to keep training."
    }

    @discardableResult
    func cancelEndConfirmation(issuedFor generation: UInt64) -> String? {
        guard generation == commandGeneration,
              pendingVoiceConfirmation == .endTraining else { return nil }
        pendingVoiceConfirmation = nil
        return "Continuing training."
    }

    @discardableResult
    func requestParticipantHandoffConfirmation(
        issuedFor generation: UInt64,
        session: ReactiveStrikeSession
    ) -> String? {
        guard generation == commandGeneration,
              transition == .idle,
              pendingVoiceConfirmation == nil,
              voiceCommandState(session: session) == .results else {
            return nil
        }
        pendingVoiceConfirmation = .participantHandoff
        return "Use the visible confirmation to switch participants."
    }

    func confirmVoiceEnd(
        issuedFor generation: UInt64,
        session: ReactiveStrikeSession,
        showControlWindow: () -> Void,
        dismissImmersive: () async -> Void
    ) async -> String? {
        guard generation == commandGeneration,
              pendingVoiceConfirmation == .endTraining,
              transition == .idle else { return nil }
        pendingVoiceConfirmation = nil
        await endExperience(
            session: session,
            showControlWindow: showControlWindow,
            dismissImmersive: dismissImmersive
        )
        guard transition == .idle else { return nil }
        return "Training ended."
    }

    private func waitForSceneReadiness() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: readinessTimeout)

        while clock.now < deadline {
            if immersiveState == .ready { return true }
            if immersiveState == .closed { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }

        return immersiveState == .ready
    }

    /// Waits for the restored window's real `onAppear` instead of guessing that a fixed sleep is
    /// long enough. On a loaded device, dismissing immersion before this event can discard the
    /// final result because no scene is yet available to own it.
    private func waitForControlWindowReadiness() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: controlWindowReadinessTimeout)

        while clock.now < deadline {
            if isControlWindowVisible { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }

        return isControlWindowVisible
    }

    private func hasActiveImmersiveScene(session: ReactiveStrikeSession) -> Bool {
        immersiveState != .closed || session.isImmersiveSpaceOpen
    }

    private func finalizeImmersiveClosure(session: ReactiveStrikeSession) {
        guard immersiveState != .closed || session.isImmersiveSpaceOpen else { return }
        immersiveState = .closed
        session.immersiveSpaceDidClose()
        session.stopDrill(preservingVoiceCapture: true)
        session.hands.stop()
    }

    private func setRoute(_ newRoute: TrainingFlowRoute) {
        guard route != newRoute else { return }
        route = newRoute
        invalidateCommands()
    }

    private func invalidateCommands() {
        commandGeneration &+= 1
        pendingVoiceConfirmation = nil
    }
}
