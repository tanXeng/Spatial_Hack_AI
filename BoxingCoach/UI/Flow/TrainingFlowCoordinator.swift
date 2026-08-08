import Foundation

enum TrainingFeature: String, CaseIterable, Identifiable, Hashable, Sendable {
    case anthropometry
    case auraPunch
    case reactiveStrike

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropometry: return "Anthropometry"
        case .auraPunch: return "Aura Punch"
        case .reactiveStrike: return "Reactive Strike"
        }
    }

    var subtitle: String {
        switch self {
        case .anthropometry: return "Calibrate height, reach, and guard"
        case .auraPunch: return "Follow a spatial punch guide"
        case .reactiveStrike: return "Hit floating targets on reaction"
        }
    }

    var isAvailable: Bool {
        self == .reactiveStrike || self == .auraPunch
    }
}

enum TrainingSelection: Hashable, Sendable {
    case reactive(mode: ReactiveStrikeMode)
    case aura(technique: Technique, stance: Stance)

    var feature: TrainingFeature {
        switch self {
        case .reactive: return .reactiveStrike
        case .aura: return .auraPunch
        }
    }
}

enum TrainingFlowRoute: Hashable, Sendable {
    case features
    case reactiveSetup
    case auraSetup
    case unavailableFeature(TrainingFeature)
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

    private var immersiveState: ImmersiveSceneState = .closed
    private let readinessTimeout: Duration = .seconds(5)

    var controlsDisabled: Bool {
        transition != .idle
    }

    func chooseFeature(_ feature: TrainingFeature) {
        guard transition == .idle else { return }
        presentationError = nil

        switch feature {
        case .reactiveStrike:
            route = .reactiveSetup
        case .auraPunch:
            route = .auraSetup
        case .anthropometry:
            route = .unavailableFeature(feature)
        }
    }

    func setDraftStance(_ stance: Stance) {
        guard transition == .idle else { return }
        draftStance = stance
    }

    func chooseReactiveMode(_ mode: ReactiveStrikeMode) {
        guard transition == .idle else { return }
        presentationError = nil
        route = .experience(.reactive(mode: mode))
    }

    func chooseAuraTechnique(_ technique: Technique) {
        guard transition == .idle, technique.isImplemented else { return }
        presentationError = nil
        route = .experience(.aura(technique: technique, stance: draftStance))
    }

    func backFromSetup() {
        guard transition == .idle else { return }
        presentationError = nil
        route = .features
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
        switch selection {
        case .reactive(let mode):
            session.selectMode(mode)
            if session.phase == .finished {
                session.resetForNewRound()
            }
            session.startDrill()

        case .aura(let technique, let stance):
            session.auraPunch.technique = technique
            session.auraPunch.stance = stance
            session.auraPunch.reset()
            session.auraPunch.start()
        }

        transition = .idle
        hideControlWindow()
    }

    func endExperience(
        session: ReactiveStrikeSession,
        showControlWindow: () -> Void,
        dismissImmersive: () async -> Void
    ) async {
        guard transition == .idle else { return }
        transition = .closingImmersion

        if hasActiveImmersiveScene(session: session) {
            showControlWindow()
            try? await Task.sleep(for: .milliseconds(100))
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

        transition = .closingImmersion
        showControlWindow()
        try? await Task.sleep(for: .milliseconds(100))
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
        case .reactive:
            session.resetForNewRound()
            route = .reactiveSetup
        case .aura(_, let stance):
            draftStance = stance
            session.auraPunch.reset()
            route = .auraSetup
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

    private func hasActiveImmersiveScene(session: ReactiveStrikeSession) -> Bool {
        immersiveState != .closed || session.isImmersiveSpaceOpen
    }

    private func finalizeImmersiveClosure(session: ReactiveStrikeSession) {
        guard immersiveState != .closed || session.isImmersiveSpaceOpen else { return }
        immersiveState = .closed
        session.immersiveSpaceDidClose()
        session.stopDrill()
        session.hands.stop()
    }
}
