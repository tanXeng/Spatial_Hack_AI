import Accessibility
import SwiftUI

/// Window-level composition root for selection, ready, error, and results screens.
/// The window hides once an engine starts; the immersive host restores it when training ends.
struct BoxingCoachRootView: View {
    @Environment(ReactiveStrikeSession.self) private var session
    @Environment(TrainingFlowCoordinator.self) private var flow
    @Environment(EventStore.self) private var eventStore
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            switch flow.route {
            case .hostSetup:
                HostSetupView()

            case .welcome:
                EventWelcomeView()

            case .newParticipant:
                NewParticipantView()

            case .returningParticipant:
                ReturningParticipantView()

            case .participantHome(let participantID):
                ParticipantHomeView(participantID: participantID)

            case .lessonOverview(let participantID):
                LessonOverviewView(participantID: participantID)

            case .safetyPreflight(let participantID, let plan):
                SafetyPreflightView(participantID: participantID, plan: plan)

            case .permissionPreflight(let participantID, let plan):
                PermissionPreflightView(participantID: participantID, plan: plan)

            case .eventExperience(let runID, let plan):
                EventRunExperienceView(runID: runID, plan: plan)

            case .savingResults(let runID), .eventResults(let runID):
                EventResultView(runID: runID)

            case .profile(let participantID):
                EventProfileView(participantID: participantID)

            case .leaderboard(let eventID):
                EventLeaderboardView(eventID: eventID)

            case .hostDashboard(let eventID):
                HostDashboardView(eventID: eventID)

            case .closeEventReview(let eventID):
                CloseEventReviewView(eventID: eventID)

            case .winnerReveal(let eventID):
                WinnerRevealView(eventID: eventID)

            case .experimentalLab:
                FeatureSelectionView(
                    controlsDisabled: flow.controlsDisabled,
                    onSelect: flow.chooseFeature
                )

            case .features:
                FeatureSelectionView(
                    controlsDisabled: flow.controlsDisabled,
                    onSelect: flow.chooseFeature
                )

            case .reactiveSetup:
                ReactiveSetupView(
                    controlsDisabled: flow.controlsDisabled,
                    onSelect: flow.chooseReactiveMode,
                    onBack: flow.backFromSetup
                )

            case .combinationSetup:
                CombinationSetupView(
                    stance: flow.draftStance,
                    controlsDisabled: flow.controlsDisabled,
                    onStanceChange: flow.setDraftStance,
                    onSelect: flow.chooseCombination,
                    onBack: flow.backFromSetup
                )

            case .auraSetup:
                AuraSetupView(
                    stance: flow.draftStance,
                    controlsDisabled: flow.controlsDisabled,
                    onStanceChange: flow.setDraftStance,
                    onSelect: flow.chooseAuraTechnique,
                    onBack: flow.backFromSetup
                )

            case .unavailableFeature(let feature):
                UnavailableFeatureView(
                    feature: feature,
                    controlsDisabled: flow.controlsDisabled,
                    onBack: flow.backFromSetup
                )

            case .experience(let selection):
                TrainingExperienceView(
                    selection: selection,
                    session: session,
                    presentationError: flow.presentationError,
                    controlsDisabled: flow.controlsDisabled,
                    onStart: { start(selection) },
                    onChangeSelection: { changeSelection(selection) }
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
        .onChange(of: flow.presentationError) { _, message in
            if let message { announce(message) }
        }
        .onChange(of: flow.route) {
            AccessibilityNotification.ScreenChanged().post()
        }
        .onAppear {
            flow.controlWindowDidAppear()
        }
        .task {
            if eventStore.loadState == .idle { await eventStore.bootstrap() }
            if case .failed = eventStore.loadState {
                flow.navigate(to: .welcome)
            } else {
                flow.installEventEditionStart(hasActiveEvent: eventStore.activeEvent != nil)
            }
        }
        .onDisappear {
            flow.controlWindowDidDisappear()
        }
    }

    private func start(_ selection: TrainingSelection) {
        Task {
            await flow.startExperience(
                selection,
                session: session,
                supportsMultipleScenes: supportsMultipleWindows,
                openImmersive: openImmersive,
                dismissImmersive: dismissImmersive,
                hideControlWindow: {
                    dismissWindow(id: BoxingCoachSceneID.controlWindow)
                }
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
        .environment(EventStore.preview())
}
