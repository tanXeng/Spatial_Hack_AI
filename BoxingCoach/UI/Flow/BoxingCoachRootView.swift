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
                    presentationError: flow.presentationError,
                    controlsDisabled: flow.controlsDisabled,
                    onStart: { start(selection) },
                    onChangeSelection: { changeSelection(selection) }
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            CoachVoiceCoachPanel(
                isDisabled: flow.controlsDisabled,
                snapshotContext: voiceContextSnapshot
            )
        }
        .padding(32)
        .frame(
            minWidth: 480,
            maxWidth: .infinity,
            minHeight: 520,
            maxHeight: .infinity
        )
        .task {
            session.musicPlayer.prepare()
            session.musicPlayer.play()
        }
        .onChange(of: flow.presentationError) { _, message in
            if let message { announce(message) }
        }
        .onChange(of: flow.route) {
            AccessibilityNotification.ScreenChanged().post()
            refreshWindowVoiceContext()
            session.musicPlayer.resumePlaybackIfNeeded()
        }
        .onChange(of: flow.controlsDisabled) { _, disabled in
            guard !disabled else { return }
            session.musicPlayer.resumeAfterVoice()
            session.musicPlayer.resumePlaybackIfNeeded()
        }
        .onChange(of: session.auraPunch.score?.overall) { _, _ in refreshWindowVoiceContext() }
        .onChange(of: session.auraPunch.feedback) { _, _ in refreshWindowVoiceContext() }
        .onChange(of: session.metrics.hitCount) { _, _ in refreshWindowVoiceContext() }
        .onChange(of: session.metrics.missCount) { _, _ in refreshWindowVoiceContext() }
        .onChange(of: session.phase) { _, _ in refreshWindowVoiceContext() }
        .onChange(of: competitionStore.currentPlayer) { oldPlayer, newPlayer in
            guard oldPlayer?.id != newPlayer?.id
                    || oldPlayer?.reach != newPlayer?.reach
                    || oldPlayer?.calibrationVersion != newPlayer?.calibrationVersion
            else { return }
            syncPlayerCalibration(newPlayer)
        }
        .onAppear {
            flow.controlWindowDidAppear()
            session.auraPunch.prepareCoachAudio()
            session.voiceCoach.prepare()
            refreshWindowVoiceContext()
            session.musicPlayer.resumePlaybackIfNeeded()
            Task {
                await session.liveVoicePrefetchIfNeeded()
            }
        }
        .task {
            await competitionStore.bootstrap()
            await completeCompetitionRunIfNeeded()
            // A standalone calibration belongs to the training session. Reopening the control
            // window must not replace it with whichever competition player happened to be used
            // previously.
            if !session.hasCalibratedReach, let player = competitionStore.currentPlayer {
                syncPlayerCalibration(player)
            }
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
            if competitionStore.activeRun == nil {
                landingActionFocused = .competition
            }
        }) { _ in
            CompetitionSheetView(onStart: startCompetition)
                .environment(competitionStore)
        }
    }

    private var featureSelection: some View {
        VStack(spacing: 16) {
            MusicControlBar(music: session.musicPlayer)

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

                Spacer()

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

            FeatureSelectionView(
                controlsDisabled: flow.controlsDisabled,
                onSelect: flow.chooseFeature
            )
            .frame(maxHeight: .infinity)
        }
    }

    private func openLandingCalibration() {
        let selection = TrainingSelection.reachCalibration
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

    private func changeSelection(_ selection: TrainingSelection) {
        Task {
            await flow.returnToSetup(
                from: selection,
                session: session,
                dismissImmersive: dismissImmersive
            )
        }
    }

    private func startCompetition(_ selection: TrainingSelection) {
        flow.navigate(to: .experience(selection))
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
            if let message = flow.presentationError {
                competitionStore.cancelActiveRun(message: message)
                flow.navigate(to: .features)
            }
        }
    }

    private func completeCompetitionRunIfNeeded() async {
        guard competitionStore.activeRun != nil else { return }
        await competitionStore.reconcileCompletedRun(session: session)
        if competitionStore.activeRun == nil {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            while flow.controlsDisabled, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            flow.navigate(to: .features)
        }
    }

    private func syncPlayerCalibration(_ player: CompetitionPlayer?) {
        let reach = player?.hasCurrentCalibration == true ? player?.reach : nil
        session.applyPersistedCompetitionReach(reach)
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
        case .reactiveSetup:
            session.voiceCoach.updateContext(
                CoachVoiceContextBuilder.makeSetup(
                    feature: .reactiveStrike,
                    stance: flow.draftStance,
                    reactiveMode: .air
                )
            )
        case .combinationSetup:
            session.voiceCoach.updateContext(
                CoachVoiceContextBuilder.makeSetup(
                    feature: .reactiveStrike,
                    stance: flow.draftStance,
                    reactiveMode: .combination
                )
            )
        case .auraSetup:
            session.voiceCoach.updateContext(
                CoachVoiceContextBuilder.makeSetup(feature: .auraPunch, stance: flow.draftStance)
            )
        case .experience(let selection):
            session.voiceCoach.updateContext(
                CoachVoiceContextBuilder.make(session: session, selection: selection)
            )
        }
    }

    private func voiceContextSnapshot() -> CoachVoiceContext? {
        switch flow.route {
        case .experience(let selection):
            return CoachVoiceContextBuilder.make(session: session, selection: selection)
        case .auraSetup:
            return CoachVoiceContextBuilder.makeSetup(feature: .auraPunch, stance: flow.draftStance)
        case .reactiveSetup:
            return CoachVoiceContextBuilder.makeSetup(
                feature: .reactiveStrike,
                stance: flow.draftStance,
                reactiveMode: .air
            )
        case .combinationSetup:
            return CoachVoiceContextBuilder.makeSetup(
                feature: .reactiveStrike,
                stance: flow.draftStance,
                reactiveMode: .combination
            )
        default:
            return nil
        }
    }
}

#Preview {
    BoxingCoachRootView()
        .environment(ReactiveStrikeSession())
        .environment(TrainingFlowCoordinator())
        .environment(CompetitionStore.preview())
}
