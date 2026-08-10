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
                instructionAnchor.addChild(instructions)
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
        } update: { _, _ in
            session.updateAudioBodyOrientation()
        } attachments: {
            Attachment(id: instructionsAttachmentID) {
                ImmersiveInstructionBanner(
                    instruction: currentInstruction,
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
                    }
                    if audioControlVisibility.showsRecoveryAction {
                        TrainingAudioRecoveryButton {
                            session.resumeAudio()
                        }
                    }
                    audioPresetMenu
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
                    announce(announcement)
                }
            }
            finishTraining()
        }
        .onChange(of: session.auraPunch.phase) { _, phase in
            guard case .experience(.aura) = flow.route,
                  phase == .results else { return }
            announce("Aura Punch scoring complete")
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
        .onChange(of: session.lastFeedback) { _, message in
            guard isReactiveEngineExperience,
                  session.phase == .running || session.phase == .calibrating else { return }
            announce(message)
        }
        .onChange(of: session.auraPunch.statusMessage) { _, message in
            guard case .experience(.aura) = flow.route,
                  session.auraPunch.isRunning else { return }
            announce(message)
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
    }

    private func bindVoiceCommands() {
        voiceCommandRegistrationID = session.voiceCoach.registerCommandHandler(
            contextProvider: { [session, flow] in
                flow.voiceCommandContext(session: session)
            }
        ) { [session, flow] transcript, issuedContext in
            let generation = flow.commandGeneration
            let target = TrainingSessionCommandTarget(
                flow: flow,
                session: session,
                showControlWindow: showControlWindow,
                dismissImmersive: dismissImmersive
            )
            return await CoachVoiceCommandRouter().resolve(
                transcript: transcript,
                issuedFor: generation,
                issuedContext: issuedContext,
                on: target
            )
        }
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
            allowsVoiceCoaching: showsVoiceCoach,
            requiresExplicitRecovery: session.audioCoordinator.presentation.requiresExplicitRecovery
        )
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
                stage: "BOXING COACH",
                message: "Preparing your training space",
                symbol: "figure.boxing"
            )
        }
    }

}
