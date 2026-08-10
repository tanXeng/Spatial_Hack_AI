import Accessibility
import SwiftUI

/// Window-level composition root for selection, ready, error, and results screens.
/// The window hides once an engine starts; the immersive host restores it when training ends.
struct BoxingCoachRootView: View {
    @Environment(ReactiveStrikeSession.self) private var session
    @Environment(TrainingFlowCoordinator.self) private var flow
    @Environment(CompetitionStore.self) private var competitionStore
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.dismissWindow) private var dismissWindow
    @AccessibilityFocusState private var landingActionFocused: LandingAction?

    private enum LandingAction: Hashable {
        case calibration
        case competition
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                switch flow.route {
                case .features:
                    featureSelection

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

                case .competitionSetup:
                    CompetitionSetupView(
                        playerName: competitionStore.currentPlayer?.name ?? "Boxer",
                        errorMessage: competitionStore.errorMessage,
                        controlsDisabled: competitionControlsDisabled,
                        onSelect: chooseCompetitionMode,
                        onLeaderboard: { competitionStore.showLeaderboard(.reactiveStrike) },
                        onRecalibrate: prepareCompetitionCalibration,
                        onChangePlayer: competitionStore.showNameEntry,
                        onBack: { flow.navigate(to: .features) }
                    )

                case .competitionCombinationSetup:
                    CompetitionCombinationSetupView(
                        stance: flow.draftStance,
                        controlsDisabled: competitionControlsDisabled,
                        onStanceChange: flow.setDraftStance,
                        onStartSetup: prepareCompetitionCombination,
                        onBack: flow.backFromSetup
                    )

                case .competitionResult:
                    if let submission = competitionStore.latestSubmission {
                        CompetitionResultView(
                            submission: submission,
                            controlsDisabled: competitionControlsDisabled,
                            onLeaderboard: { competitionStore.showLeaderboard(submission.mode) },
                            onCompeteAgain: enterCompetitionSetup,
                            onHome: { flow.navigate(to: .features) }
                        )
                    } else {
                        ContentUnavailableView(
                            "Result Unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text("Return to Competition and try another complete run.")
                        )
                    }

                case .auraSetup:
                    AuraSetupView(
                        stance: flow.draftStance,
                        controlsDisabled: flow.controlsDisabled,
                        onStanceChange: flow.setDraftStance,
                        onSelect: flow.chooseAuraTechnique,
                        onBack: flow.backFromSetup
                    )

                case .experience(let selection):
                    TrainingExperienceView(
                        selection: selection,
                        session: session,
                        calibration: flow.calibration,
                        presentationError: flow.presentationError,
                        controlsDisabled: flow.controlsDisabled,
                        onStart: { start(selection) },
                        onChangeSelection: { changeSelection(selection) },
                        onFinishCalibration: flow.finishCalibration
                    )
                }
            }

            CoachVoiceCoachPanel(isDisabled: flow.controlsDisabled)
                .padding(.bottom, 8)
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
            refreshWindowVoiceContext()
        }
        .onChange(of: competitionStore.currentPlayer) { oldPlayer, newPlayer in
            guard oldPlayer?.id != newPlayer?.id
                    || oldPlayer?.reach != newPlayer?.reach
                    || oldPlayer?.calibrationVersion != newPlayer?.calibrationVersion
            else { return }
            syncPlayerCalibration(
                newPlayer,
                clearingGuards: oldPlayer?.id != newPlayer?.id
            )
        }
        .onAppear {
            flow.controlWindowDidAppear()
            session.voiceCoach.prepare()
            refreshWindowVoiceContext()
        }
        .task {
            async let coachPreload: Void = session.auraPunch.preloadCoach()
            await competitionStore.bootstrap()
            await completeCompetitionRunIfNeeded()
            // A standalone calibration belongs to the training session. Reopening the control
            // window must not replace it with whichever competition player happened to be used
            // previously.
            if !session.hasCalibratedReach, let player = competitionStore.currentPlayer {
                syncPlayerCalibration(player, clearingGuards: true)
            }
            _ = await coachPreload
        }
        .onDisappear {
            flow.controlWindowDidDisappear()
        }
        .sheet(item: Binding(
            get: { competitionStore.sheetRoute },
            set: { route in
                if route == nil { competitionStore.dismiss() }
            }
        ), onDismiss: {
            // Starting a run dismisses this window immediately. Moving VoiceOver to a control
            // that is about to disappear creates a misleading focus jump into hidden UI.
            if competitionStore.activeRun == nil, flow.route == .features {
                landingActionFocused = .competition
            }
        }) { _ in
            CompetitionSheetView(
                onPrepare: prepareCompetitionSelection,
                onEnterSetup: enterCompetitionSetup
            )
                .environment(competitionStore)
        }
    }

    private var featureSelection: some View {
        ZStack(alignment: .topTrailing) {
            FeatureSelectionView(
                controlsDisabled: flow.controlsDisabled,
                onSelect: flow.chooseFeature
            )
            .padding(.top, 64)

            HStack(spacing: 12) {
                Button(action: openLandingCalibration) {
                    Label(
                        session.hasCalibratedReach
                            ? "Recalibrate"
                            : "Calibrate",
                        systemImage: "ruler"
                    )
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(
                    flow.controlsDisabled
                        || competitionStore.activeRun != nil
                        || competitionStore.isLoading
                        || competitionStore.isSaving
                )
                .accessibilityLabel(
                    session.hasCalibratedReach
                        ? "Recalibrate reach"
                        : "Calibrate reach"
                )
                .accessibilityHint("Measures comfortable reach for Reactive Strike and Combo without joining the competition")
                .accessibilityInputLabels(["Calibrate", "Recalibrate reach", "Reach settings"])
                .accessibilityFocused($landingActionFocused, equals: .calibration)

                Button {
                    competitionStore.open()
                } label: {
                    Label("Join Competition", systemImage: "trophy.fill")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(
                    flow.controlsDisabled
                        || competitionStore.activeRun != nil
                        || competitionStore.isLoading
                        || competitionStore.isSaving
                )
                .accessibilityLabel("Join Competition")
                .accessibilityHint("Enter a player name, calibrate reach, and compete on two leaderboards")
                .accessibilityInputLabels(["Join Competition", "Competition", "Leaderboard"])
                .accessibilityFocused($landingActionFocused, equals: .competition)
            }
        }
    }

    private func openLandingCalibration() {
        let selection = TrainingSelection.calibration
        flow.navigate(to: .experience(selection))
        start(selection)
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

    private var competitionControlsDisabled: Bool {
        flow.controlsDisabled || competitionStore.isLoading || competitionStore.isSaving
    }

    private func changeSelection(_ selection: TrainingSelection) {
        Task {
            await flow.returnToSetup(
                from: selection,
                session: session,
                dismissImmersive: dismissImmersive
            )
            switch selection {
            case .competition:
                competitionStore.discardPreparedRun()
            case .competitionCalibration:
                competitionStore.discardPreparedRun()
                competitionStore.open()
            default:
                break
            }
        }
    }

    private func prepareCompetitionSelection(_ selection: TrainingSelection) {
        flow.navigate(to: .experience(selection))
    }

    private func enterCompetitionSetup() {
        competitionStore.closeSheetForNavigation()
        flow.enterCompetitionSetup(
            stance: competitionStore.currentPlayer?.rememberedStance ?? .orthodox
        )
    }

    private func chooseCompetitionMode(_ mode: CompetitionMode) {
        if mode == .combination {
            flow.enterCompetitionCombinationSetup()
            return
        }

        Task {
            if let selection = await competitionStore.startReactiveStrike() {
                prepareCompetitionSelection(selection)
            }
        }
    }

    private func prepareCompetitionCombination() {
        Task {
            if let selection = await competitionStore.startCombination(stance: flow.draftStance) {
                prepareCompetitionSelection(selection)
            }
        }
    }

    private func prepareCompetitionCalibration() {
        if let selection = competitionStore.prepareCalibration() {
            prepareCompetitionSelection(selection)
        }
    }

    private func completeCompetitionRunIfNeeded() async {
        guard let completedRun = competitionStore.activeRun else { return }
        await competitionStore.reconcileCompletedRun(session: session)
        if competitionStore.activeRun == nil {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            while flow.controlsDisabled, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            switch completedRun.kind {
            case .calibration:
                if competitionStore.currentPlayer?.hasCurrentCalibration == true {
                    enterCompetitionSetup()
                } else {
                    flow.navigate(to: .features)
                }
            case .ranked:
                if competitionStore.latestSubmission?.id == completedRun.id {
                    competitionStore.closeSheetForNavigation()
                    flow.enterCompetitionResult()
                } else if competitionStore.currentPlayer?.hasCurrentCalibration == true {
                    enterCompetitionSetup()
                } else {
                    flow.navigate(to: .features)
                }
            }
        }
    }

    private func syncPlayerCalibration(
        _ player: CompetitionPlayer?,
        clearingGuards: Bool = false
    ) {
        let reach = player?.hasCurrentCalibration == true ? player?.reach : nil
        session.applyPersistedCompetitionReach(reach, clearingGuards: clearingGuards)
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

    private func refreshWindowVoiceContext() {
        switch flow.route {
        case .features:
            session.voiceCoach.updateContext(.idle)
        case .reactiveSetup, .combinationSetup, .competitionSetup, .competitionCombinationSetup:
            session.voiceCoach.updateContext(CoachVoiceContext(
                feature: .reactiveStrike,
                auraPhase: nil,
                drillPhase: .idle,
                techniqueName: nil
            ))
        case .competitionResult:
            session.voiceCoach.updateContext(.idle)
        case .auraSetup:
            session.voiceCoach.updateContext(CoachVoiceContext(
                feature: .auraPunch,
                auraPhase: .idle,
                drillPhase: nil,
                techniqueName: nil
            ))
        case .experience(let selection):
            switch selection {
            case .aura(let technique, _):
                session.voiceCoach.updateContext(CoachVoiceContext(
                    feature: .auraPunch,
                    auraPhase: session.auraPunch.phase,
                    drillPhase: nil,
                    techniqueName: technique.name
                ))
            case .reactive, .competitionCalibration, .competition:
                session.voiceCoach.updateContext(CoachVoiceContext(
                    feature: .reactiveStrike,
                    auraPhase: nil,
                    drillPhase: session.phase,
                    techniqueName: nil
                ))
            case .calibration:
                session.voiceCoach.updateContext(CoachVoiceContext(
                    feature: .anthropometry,
                    auraPhase: nil,
                    drillPhase: session.phase,
                    techniqueName: nil
                ))
            }
        }
    }
}

#Preview {
    BoxingCoachRootView()
        .environment(ReactiveStrikeSession())
        .environment(TrainingFlowCoordinator())
        .environment(CompetitionStore.preview())
}
