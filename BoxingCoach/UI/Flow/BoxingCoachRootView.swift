import Accessibility
import SwiftUI

/// Window-level composition root. This is the only view that can invoke visionOS scene actions;
/// every child view receives synchronous intent closures instead.
struct BoxingCoachRootView: View {
    @Environment(ReactiveStrikeSession.self) private var session
    @Environment(TrainingFlowCoordinator.self) private var flow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            switch flow.route {
            case .features:
                FeatureSelectionView(
                    controlsDisabled: flow.controlsDisabled,
                    onSelect: flow.chooseFeature,
                    onExit: exit
                )

            case .reactiveSetup:
                ReactiveSetupView(
                    controlsDisabled: flow.controlsDisabled,
                    onSelect: flow.chooseReactiveMode,
                    onBack: flow.backFromSetup,
                    onExit: exit
                )

            case .auraSetup:
                AuraSetupView(
                    stance: flow.draftStance,
                    controlsDisabled: flow.controlsDisabled,
                    onStanceChange: flow.setDraftStance,
                    onSelect: flow.chooseAuraTechnique,
                    onBack: flow.backFromSetup,
                    onExit: exit
                )

            case .unavailableFeature(let feature):
                UnavailableFeatureView(
                    feature: feature,
                    controlsDisabled: flow.controlsDisabled,
                    onBack: flow.backFromSetup,
                    onExit: exit
                )

            case .experience(let selection):
                TrainingExperienceView(
                    selection: selection,
                    session: session,
                    presentationError: flow.presentationError,
                    controlsDisabled: flow.controlsDisabled,
                    onStart: { start(selection) },
                    onEnd: end,
                    onChangeSelection: { changeSelection(selection) },
                    onExit: exit
                )
            }
        }
        .padding(32)
        .frame(
            minWidth: 480,
            maxWidth: .infinity,
            minHeight: 520,
            maxHeight: .infinity
        )
        .onChange(of: session.phase) { _, phase in
            guard case .experience(.reactive) = flow.route,
                  phase == .finished else { return }
            announce("Reactive Strike complete")
            finishExperience()
        }
        .onChange(of: session.auraPunch.phase) { _, phase in
            guard case .experience(.aura) = flow.route,
                  phase == .results else { return }
            announce("Aura Punch scoring complete")
            finishExperience()
        }
        .onChange(of: session.errorMessage) { _, message in
            guard case .experience(.reactive) = flow.route,
                  let message else { return }
            announce(message)
            finishExperience()
        }
        .onChange(of: session.auraPunch.errorMessage) { _, message in
            guard case .experience(.aura) = flow.route,
                  let message else { return }
            announce(message)
            finishExperience()
        }
        .onChange(of: flow.presentationError) { _, message in
            if let message { announce(message) }
        }
        .onChange(of: flow.route) {
            AccessibilityNotification.ScreenChanged().post()
        }
        .onChange(of: session.lastFeedback) { _, message in
            guard case .experience(.reactive) = flow.route,
                  session.phase == .running else { return }
            announce(message)
        }
        .onChange(of: session.auraPunch.statusMessage) { _, message in
            guard case .experience(.aura) = flow.route,
                  session.auraPunch.isRunning else { return }
            announce(message)
        }
    }

    private func start(_ selection: TrainingSelection) {
        Task {
            await flow.startExperience(
                selection,
                session: session,
                supportsMultipleScenes: supportsMultipleWindows,
                openImmersive: openImmersive,
                dismissImmersive: dismissImmersive
            )
        }
    }

    private func end() {
        Task {
            await flow.endExperience(
                session: session,
                dismissImmersive: dismissImmersive
            )
        }
    }

    private func changeSelection(_ selection: TrainingSelection) {
        Task {
            await flow.returnToSetup(
                from: selection,
                session: session,
                dismissImmersive: dismissImmersive
            )
        }
    }

    private func finishExperience() {
        Task {
            await flow.finishExperience(
                session: session,
                dismissImmersive: dismissImmersive
            )
        }
    }

    private func exit() {
        Task {
            await flow.exit(
                session: session,
                dismissImmersive: dismissImmersive,
                dismissWindow: { dismissWindow() }
            )
        }
    }

    private func openImmersive(_ id: String) async -> ImmersiveOpenOutcome {
        switch await openImmersiveSpace(id: id) {
        case .opened:
            return .opened
        case .userCancelled:
            return .cancelled
        case .error:
            return .failed("Could not open the immersive training space because of a system error.")
        @unknown default:
            return .failed("Could not open the immersive training space.")
        }
    }

    private func dismissImmersive() async {
        await dismissImmersiveSpace()
    }

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}

#Preview {
    BoxingCoachRootView()
        .environment(ReactiveStrikeSession())
        .environment(TrainingFlowCoordinator())
}
