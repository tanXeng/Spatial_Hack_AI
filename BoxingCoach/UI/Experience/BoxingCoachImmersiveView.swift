import Accessibility
import RealityKit
import SwiftUI

nonisolated struct ImmersiveAudioControlVisibility: Equatable, Sendable {
    let showsPushToTalk: Bool
    let showsRecoveryAction: Bool

    init(allowsVoiceCoaching: Bool, requiresExplicitRecovery: Bool) {
        showsPushToTalk = allowsVoiceCoaching && !requiresExplicitRecovery
        showsRecoveryAction = requiresExplicitRecovery
    }
}

/// Mixed immersive scene hosting spatial targets and Aura Punch silhouettes.
/// It owns the in-training stop control and restores the window before immersion closes.
struct BoxingCoachImmersiveView: View {
    @Environment(ReactiveStrikeSession.self) private var session
    @Environment(TrainingFlowCoordinator.self) private var flow
    @Environment(CompetitionStore.self) private var competitionStore
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var voiceCommandRegistrationID: UUID?
    @State private var thermalProfile = ThermalPerformancePolicy.profile(for: .nominal)
    @State private var announcementGate = TrainingAccessibilityAnnouncementGate()
    @AccessibilityFocusState private var voiceFocusDestination: TrainingAccessibilityFocusDestination?
    @AppStorage("BoxingCoach.prefersHeadAnchoredGuidance")
    private var prefersHeadAnchoredGuidance = true

    private let controlsAttachmentID = "TrainingControls"
    private let voiceCoachAttachmentID = "VoiceCoachControl"
    private let instructionsAttachmentID = "TrainingInstructions"

    var body: some View {
        RealityView { content, attachments in
            let root = Entity()
            root.name = "BoxingCoachTrainingRoot"
            content.add(root)

            // Body-relative audio follows current head orientation in mixed immersion while target
            // impacts remain world-positioned on the reusable scene root.
            let audioBodyAnchor = Entity()
            audioBodyAnchor.name = "BoxingCoachBodyAudioAnchor"
            content.add(audioBodyAnchor)

            // Keep coaching just above the user's neutral gaze instead of at a fixed room height.
            // At 1.15 m forward and 18 cm up this is roughly nine degrees above line of sight.
            let instructionAnchor = AnchorEntity(.head, trackingMode: .continuous)
            instructionAnchor.name = "TrainingInstructionAnchor"
            content.add(instructionAnchor)

            if let instructions = attachments.entity(for: instructionsAttachmentID) {
                instructions.name = "TrainingInstructions"
                instructions.position = SIMD3<Float>(0, 0.18, -1.15)
                switch TrainingAccessibility.anchor(
                    prefersHeadAnchoredGuidance: prefersHeadAnchoredGuidance
                ) {
                case .headAnchored:
                    instructionAnchor.addChild(instructions)
                case .bodyRelative:
                    audioBodyAnchor.addChild(instructions)
                }
            }

            if let voiceCoach = attachments.entity(for: voiceCoachAttachmentID) {
                voiceCoach.name = "VoiceCoachControl"
                voiceCoach.position = SIMD3<Float>(-0.38, -0.12, -1.05)
                instructionAnchor.addChild(voiceCoach)
            }

            if let controls = attachments.entity(for: controlsAttachmentID) {
                controls.name = "TrainingControls"
                if isAuraExperience {
                    controls.position = SIMD3<Float>(0, -0.32, -1.05)
                    instructionAnchor.addChild(controls)
                } else {
                    controls.position = SIMD3<Float>(0, 0.78, -0.9)
                    root.addChild(controls)
                }
            }

            session.attachSceneRoot(root, audioBodyAnchor: audioBodyAnchor)
            flow.immersiveSceneDidBecomeReady(session: session)
        } update: { content, attachments in
            session.updateAudioBodyOrientation()
            if let instructions = attachments.entity(for: instructionsAttachmentID) {
                let destinationName: String
                switch TrainingAccessibility.anchor(
                    prefersHeadAnchoredGuidance: prefersHeadAnchoredGuidance
                ) {
                case .headAnchored:
                    destinationName = "TrainingInstructionAnchor"
                case .bodyRelative:
                    destinationName = "BoxingCoachBodyAudioAnchor"
                }
                if let destination = content.entities.first(where: {
                    $0.name == destinationName
                }), instructions.parent !== destination {
                    instructions.removeFromParent()
                    destination.addChild(instructions)
                    instructions.position = SIMD3<Float>(0, 0.18, -1.15)
                }
            }
        } attachments: {
            Attachment(id: instructionsAttachmentID) {
                ImmersiveInstructionBanner(
                    instruction: sharedPresentationInstruction,
                    style: auraBannerStyle
                )
            }

            Attachment(id: voiceCoachAttachmentID) {
                VStack(spacing: 8) {
                    if audioControlVisibility.showsPushToTalk {
                        CoachPushToTalkButton(
                            isListening: session.voiceCoach.isListening,
                            isCaptureReady: session.voiceCoach.isCaptureReady,
                            isRouting: session.voiceCoach.isRouting,
                            isGeneratingResponse: session.voiceCoach.isGeneratingResponse,
                            isDisabled: flow.controlsDisabled,
                            style: .compactSpatial,
                            onToggle: {
                                session.voiceCoach.toggleCapture(origin: .immersiveSpace)
                            },
                            onPress: {
                                session.beginCoachPushToTalk(origin: .immersiveSpace)
                            },
                            onRelease: { session.endCoachPushToTalk() }
                        )
                        .accessibilityFocused(
                            $voiceFocusDestination,
                            equals: immersiveVoiceControlFocusDestination
                        )
                    }
                    if audioControlVisibility.showsRecoveryAction {
                        TrainingAudioRecoveryButton {
                            session.resumeAudio()
                        }
                    }
                    if let immersiveRecoveryPresentation {
                        RuntimeRecoveryCard(
                            presentation: immersiveRecoveryPresentation,
                            controlsDisabled: flow.controlsDisabled,
                            action: immersiveRecoveryAction(
                                for: immersiveRecoveryPresentation.action
                            )
                        )
                        .frame(maxWidth: 320)
                    }
                    audioPresetMenu
                    guidanceAnchorMenu
                    Text(session.voiceCoach.controlPresentation.visibleCaption)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                        .accessibilityLabel(
                            "Ask Coach status: \(session.voiceCoach.controlPresentation.visibleCaption)"
                        )
                    if let transcript = session.voiceCoach.controlPresentation.visibleTranscript,
                       !transcript.isEmpty {
                        Text("You said: \(transcript)")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 280)
                            .accessibilityLabel("Voice transcript: \(transcript)")
                    }
                    if let caption = session.audioCoordinator.presentation.caption {
                        Label(
                            caption,
                            systemImage: session.audioCoordinator.presentation.symbolName
                        )
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Training status: \(caption)")
                    }
                    if let caption = thermalProfile.caption {
                        Label(caption, systemImage: "gauge.with.dots.needle.33percent")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 280)
                            .accessibilityLabel(caption)
                    }
                }
                .padding(10)
                .glassBackgroundEffect()
                .confirmationDialog(
                    "Private voice capture",
                    isPresented: immersivePrivacyNoticeBinding,
                    titleVisibility: .visible
                ) {
                    Button("Continue") { session.voiceCoach.acceptPrivacyNotice() }
                    Button("Not Now", role: .cancel) {
                        session.voiceCoach.declinePrivacyNotice()
                    }
                } message: {
                    Text("Your voice is transcribed on this device and is never saved.")
                }
            }

            Attachment(id: controlsAttachmentID) {
                Button("End Training", systemImage: "stop.circle") {
                    endTraining()
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(isAuraExperience ? .large : .regular)
                .font(isAuraExperience ? .title3.weight(.semibold) : .body)
                .frame(minWidth: 60, minHeight: 60)
                .disabled(flow.controlsDisabled)
                .accessibilityHint("Ends the current training session and returns to results")
                .accessibilityInputLabels(["End Training", "Stop Training"])
                .padding(isAuraExperience ? 18 : 14)
                .glassBackgroundEffect()
            }
        }
        .onChange(of: session.phase) { _, phase in
            guard isReactiveEngineExperience, phase == .finished else { return }
            if case .experience(let selection) = flow.route {
                let announcement = ImmersiveInstructionPolicy.completionAnnouncement(
                    for: ImmersiveTrainingContext(selection: selection),
                    wasStoppedBeforeCompletion: session.wasStoppedBeforeCompletion
                )
                if let announcement {
                    announceSemantic(.result(announcement))
                }
            }
            finishTraining()
        }
        .onChange(of: session.auraPunch.phase) { _, phase in
            guard case .experience(.aura) = flow.route,
                  phase == .results else { return }
            announceSemantic(.result("Aura Punch scoring complete"))
            finishTraining()
        }
        .onChange(of: session.errorMessage) { _, message in
            guard isReactiveEngineExperience, let message else { return }
            announce(message)
            finishTraining()
        }
        .onChange(of: session.auraPunch.errorMessage) { _, message in
            guard case .experience(.aura) = flow.route,
                  let message else { return }
            announce(message)
            finishTraining()
        }
        .onChange(of: sharedPresentationInstruction.stage) { _, stage in
            announceSemantic(.stage(stage))
        }
        .onChange(of: session.isTrackingPaused) { wasPaused, isPaused in
            guard wasPaused != isPaused else { return }
            announceSemantic(isPaused ? .trackingPaused : .trackingRecovered)
        }
        .onChange(of: session.auraPunch.isTrackingPaused) { wasPaused, isPaused in
            guard wasPaused != isPaused else { return }
            announceSemantic(isPaused ? .trackingPaused : .trackingRecovered)
        }
        .onChange(of: session.auraPunch.correctionFocus) { oldFocus, newFocus in
            guard oldFocus != newFocus, newFocus != nil else { return }
            announceSemantic(.correction(session.auraPunch.cyclePresentation.instruction))
        }
        .onChange(of: session.auraPunch.proofMetric) { oldProof, newProof in
            guard oldProof != newProof, let newProof else { return }
            announceSemantic(.proof(TrainingAccessibility.proofAnnouncement(for: newProof)))
        }
        .onChange(of: session.voiceCoach.state) { oldState, newState in
            if let destination = TrainingAccessibility.focusAfterVoiceTransition(
                from: oldState,
                to: newState
            ) {
                voiceFocusDestination = destination
            }
        }
        .onChange(of: immersiveRecoveryPresentation?.action) { oldAction, newAction in
            guard oldAction != newAction,
                  let presentation = immersiveRecoveryPresentation else { return }
            announce("\(presentation.title). \(presentation.message)")
        }
        .onDisappear {
            session.auraPunch.cycleDidComplete = nil
            if let voiceCommandRegistrationID {
                session.voiceCoach.unregisterCommandHandler(voiceCommandRegistrationID)
                self.voiceCommandRegistrationID = nil
            }
            // Idempotent whether closure was requested by the coordinator or by the system.
            session.detachSceneRoot()
            openWindow(id: BoxingCoachSceneID.controlWindow)
            flow.immersiveSceneDidClose(session: session)
        }
        .task {
            refreshThermalProfile()
            bindVoiceCommands()
            session.auraPunch.cycleDidComplete = { result, reach in
                try await competitionStore.persistStandaloneCoachingCycle(
                    result,
                    fittedReach: reach
                )
            }
            refreshVoiceCoachContext()
        }
        .onChange(of: flow.route) { _, _ in refreshVoiceCoachContext() }
        .onChange(of: session.phase) { _, _ in refreshVoiceCoachContext() }
        .onChange(of: session.auraPunch.phase) { _, _ in refreshVoiceCoachContext() }
        .onReceive(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification
        )) { _ in
            refreshThermalProfile()
        }
    }

    private func bindVoiceCommands() {
        voiceCommandRegistrationID = session.voiceCoach.registerCommandHandler(
            issuanceProvider: { [session, flow] in
                CoachVoiceCoach.CommandIssuance(
                    context: flow.voiceCommandContext(session: session),
                    generation: flow.commandGeneration
                )
            }
        ) { [session, flow] transcript, issuance in
            let target = TrainingSessionCommandTarget(
                flow: flow,
                session: session,
                showControlWindow: showControlWindow,
                dismissImmersive: dismissImmersive
            )
            return await CoachVoiceCommandRouter().resolve(
                transcript: transcript,
                issuedFor: issuance?.generation ?? flow.commandGeneration,
                issuedContext: issuance?.context,
                on: target
            )
        }
    }

    private func refreshThermalProfile() {
        let level = ThermalPerformanceLevel(ProcessInfo.processInfo.thermalState)
        thermalProfile = ThermalPerformancePolicy.profile(for: level)
        session.setThermalPerformanceProfile(thermalProfile)
    }

    private var immersivePrivacyNoticeBinding: Binding<Bool> {
        Binding(
            get: {
                if case .needsPermission = session.voiceCoach.state { true } else { false }
            },
            set: { isPresented in
                if !isPresented, case .needsPermission = session.voiceCoach.state {
                    session.voiceCoach.declinePrivacyNotice()
                }
            }
        )
    }

    private var showsVoiceCoach: Bool {
        guard !flow.controlsDisabled else { return false }
        switch flow.route {
        case .experience(.reachCalibration), .experience(.competitionCalibration),
             .experience(.competition):
            return false
        case .experience:
            return true
        default:
            return false
        }
    }

    private var audioControlVisibility: ImmersiveAudioControlVisibility {
        ImmersiveAudioControlVisibility(
            allowsVoiceCoaching: showsVoiceCoach && immersiveRecoveryPresentation == nil,
            requiresExplicitRecovery: session.audioCoordinator.presentation.requiresExplicitRecovery
        )
    }

    private var immersiveVoiceControlFocusDestination: TrainingAccessibilityFocusDestination {
        session.voiceCoach.state == .denied ? .permissionRecovery : .askCoach
    }

    private var immersiveRecoveryPresentation: RuntimeRecoveryPresentation? {
        ImmersiveRuntimeRecoveryPolicy.presentation(
            trackingState: session.hands.runtimeState,
            trackingReason: session.hands.rejectionReason,
            trackingInstruction: session.hands.recoveryInstruction,
            audioRequiresExplicitRecovery: session.audioCoordinator.presentation.requiresExplicitRecovery
        )
    }

    private func immersiveRecoveryAction(
        for action: RuntimeRecoveryAction
    ) -> (() -> Void)? {
        switch action {
        case .reviewTrackingPermission, .retryTracking:
            return {
                Task { await session.hands.retry() }
            }
        case .returnToSetup:
            return endTraining
        case .resumeAudio, .waitForTracking, .useVisibleControls:
            return nil
        }
    }

    private var audioPresetMenu: some View {
        let preset = session.audioCoordinator.presentation.preset
        return Menu("Audio: \(preset.title)", systemImage: preset.symbolName) {
            Picker("Training audio preset", selection: Binding(
                get: { session.audioCoordinator.presentation.preset },
                set: { session.setAudioPreset($0) }
            )) {
                ForEach(TrainingAudioPreset.allCases) { option in
                    Label(option.title, systemImage: option.symbolName).tag(option)
                }
            }
        }
        .disabled(flow.controlsDisabled)
        .accessibilityLabel("Training audio preset")
        .accessibilityValue(preset.title)
        .accessibilityHint(preset.accessibilityDescription)
    }

    private var guidanceAnchorMenu: some View {
        Toggle(
            "Keep guidance in view",
            isOn: $prefersHeadAnchoredGuidance
        )
        .disabled(flow.controlsDisabled)
        .accessibilityHint(
            prefersHeadAnchoredGuidance
                ? "Guidance follows your gaze. Turn this off for body-relative guidance."
                : "Guidance stays aligned to your fitted body frame. Turn this on to follow your gaze."
        )
        .accessibilityInputLabels(["Keep guidance in view", "Guidance anchor"])
    }

    private func refreshVoiceCoachContext() {
        switch flow.route {
        case .experience(.aura(_, let technique, _)):
            session.voiceCoach.updateContext(CoachVoiceContext(
                feature: .auraPunch,
                auraPhase: session.auraPunch.phase,
                drillPhase: nil,
                techniqueName: technique.name
            ))
        case .experience(.reactive):
            session.voiceCoach.updateContext(CoachVoiceContext(
                feature: .reactiveStrike,
                auraPhase: nil,
                drillPhase: session.phase,
                techniqueName: nil
            ))
        case .experience(.reachCalibration), .experience(.competitionCalibration),
             .experience(.competition):
            session.voiceCoach.updateContext(CoachVoiceContext(
                feature: .reactiveStrike,
                auraPhase: nil,
                drillPhase: session.phase,
                techniqueName: nil
            ))
        default:
            session.voiceCoach.updateContext(CoachVoiceContext.idle)
        }
    }

    private var isAuraExperience: Bool {
        if case .experience(.aura) = flow.route { return true }
        return false
    }

    private var isReactiveEngineExperience: Bool {
        switch flow.route {
        case .experience(.reactive), .experience(.reachCalibration),
             .experience(.competitionCalibration), .experience(.competition):
            return true
        default:
            return false
        }
    }

    private var auraBannerStyle: ImmersiveInstructionBannerStyle {
        guard isAuraExperience else { return .compact }
        switch session.auraPunch.learningStage {
        case .learnWatch, .learnOutbound, .learnLanding, .learnReturn,
             .guidedRehearsal, .baseline, .correctiveDrill, .retest, .transfer:
            return .coaching
        case .fit, .correction, .proof, .complete:
            return .prominent
        }
    }

    private var sharedPresentationInstruction: ImmersiveInstruction {
        let publicState = TrainingPresentationPolicy.liveState(
            flow: flow,
            session: session,
            competitionStore: competitionStore
        )
        let detailed = currentInstruction
        return ImmersiveInstruction(
            stage: publicState.stage.rawValue,
            message: publicState.instruction.text,
            symbol: detailed.symbol,
            action: detailed.action,
            progress: publicState.progress?.text,
            metric: publicState.proof?.text,
            source: publicState.coachingSource?.text
        )
    }

    private func endTraining() {
        Task {
            await flow.endExperience(
                session: session,
                showControlWindow: showControlWindow,
                dismissImmersive: dismissImmersive
            )
        }
    }

    private func finishTraining() {
        Task {
            // Let an engine's synchronous phase/error mutation finish before asking the
            // coordinator to close a space that may still be completing its open transition.
            await Task.yield()
            await flow.finishExperience(
                session: session,
                showControlWindow: showControlWindow,
                dismissImmersive: dismissImmersive
            )
        }
    }

    private func showControlWindow() {
        openWindow(id: BoxingCoachSceneID.controlWindow)
    }

    private func dismissImmersive() async {
        await dismissImmersiveSpace()
    }

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    private func announceSemantic(_ event: TrainingAccessibilityEvent) {
        var gate = announcementGate
        guard let message = gate.announcement(
            for: event,
            at: ProcessInfo.processInfo.systemUptime
        ) else { return }
        announcementGate = gate
        announce(message)
    }

    private var currentInstruction: ImmersiveInstruction {
        switch flow.route {
        case .experience(.aura):
            let aura = session.auraPunch
            return AuraImmersiveInstructionPolicy.instruction(
                phase: aura.phase,
                coachingHeadline: aura.coachingHeadline,
                coachingDetail: aura.coachingDetail,
                cyclePresentation: aura.cyclePresentation,
                trackingPaused: aura.isTrackingPaused,
                trainingPaused: aura.isTrainingPaused,
                statusMessage: aura.statusMessage
            )

        case .experience(let selection):
            return ImmersiveInstructionPolicy.instruction(
                for: ImmersiveTrainingContext(selection: selection),
                phase: session.phase,
                progressLabel: session.progressLabel,
                feedback: session.lastFeedback,
                trackingPaused: session.isTrackingPaused
            )

        default:
            return ImmersiveInstruction(
                stage: "TRAINING SPACE READY",
                message: "Choose a training experience in the control window.",
                symbol: "figure.boxing"
            )
        }
    }

}
