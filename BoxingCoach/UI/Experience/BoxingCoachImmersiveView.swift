import Accessibility
import RealityKit
import SwiftUI

/// Mixed immersive scene hosting spatial targets and Aura Punch silhouettes.
/// It owns the in-training stop control and restores the window before immersion closes.
struct BoxingCoachImmersiveView: View {
    @Environment(ReactiveStrikeSession.self) private var session
    @Environment(TrainingFlowCoordinator.self) private var flow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow

    private let controlsAttachmentID = "TrainingControls"
    private let voiceCoachAttachmentID = "VoiceCoachControl"
    private let instructionsAttachmentID = "TrainingInstructions"

    var body: some View {
        RealityView { content, attachments in
            let root = Entity()
            root.name = "BoxingCoachTrainingRoot"
            content.add(root)

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

            session.attachSceneRoot(root)
            flow.immersiveSceneDidBecomeReady(session: session)
        } attachments: {
            Attachment(id: instructionsAttachmentID) {
                ImmersiveInstructionBanner(
                    instruction: currentInstruction,
                    style: auraBannerStyle
                )
            }

            Attachment(id: voiceCoachAttachmentID) {
                if showsVoiceCoach {
                    CoachPushToTalkButton(
                        isListening: session.voiceCoach.isListening,
                        isCaptureReady: session.voiceCoach.isCaptureReady,
                        isRouting: session.voiceCoach.isRouting,
                        isGeneratingResponse: session.voiceCoach.isGeneratingResponse,
                        isDisabled: flow.controlsDisabled,
                        style: .compactSpatial,
                        onPress: { session.voiceCoach.beginPushToTalk() },
                        onRelease: { session.voiceCoach.endPushToTalk() }
                    )
                    .padding(10)
                    .glassBackgroundEffect()
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
                .disabled(flow.controlsDisabled)
                .accessibilityHint("Ends the current training session and returns to results")
                .padding(isAuraExperience ? 18 : 14)
                .glassBackgroundEffect()
            }
        }
        .onChange(of: session.phase) { _, phase in
            guard isReactiveEngineExperience, phase == .finished else { return }
            announce(isReachCalibrationExperience ? "Reach calibration complete" : "Reactive Strike complete")
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
            // Idempotent whether closure was requested by the coordinator or by the system.
            openWindow(id: BoxingCoachSceneID.controlWindow)
            flow.immersiveSceneDidClose(session: session)
        }
        .task {
            session.auraPunch.prepareCoachAudio()
            session.voiceCoach.prepare()
            refreshVoiceCoachContext()
            await session.liveVoicePrefetchIfNeeded()
        }
        .onChange(of: flow.route) { _, _ in refreshVoiceCoachContext() }
        .onChange(of: session.phase) { _, _ in refreshVoiceCoachContext() }
        .onChange(of: session.auraPunch.phase) { _, _ in refreshVoiceCoachContext() }
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

    private func refreshVoiceCoachContext() {
        switch flow.route {
        case .experience(.aura(let technique, let stance)):
            session.voiceCoach.updateContext(CoachVoiceContext(
                feature: .auraPunch,
                auraPhase: session.auraPunch.phase,
                drillPhase: nil,
                techniqueName: technique.name,
                stance: stance,
                reactiveMode: nil,
                combinationName: nil
            ))
        case .experience(.reactive(let mode, let combination, let stance)):
            session.voiceCoach.updateContext(CoachVoiceContext(
                feature: .reactiveStrike,
                auraPhase: nil,
                drillPhase: session.phase,
                techniqueName: nil,
                stance: stance,
                reactiveMode: mode,
                combinationName: combination?.name
            ))
        case .experience(.reachCalibration), .experience(.competitionCalibration), .experience(.competition):
            session.voiceCoach.updateContext(CoachVoiceContext(
                feature: .reactiveStrike,
                auraPhase: nil,
                drillPhase: session.phase,
                techniqueName: nil,
                stance: session.stance,
                reactiveMode: session.mode,
                combinationName: session.selectedCombination.name
            ))
        default:
            session.voiceCoach.updateContext(CoachVoiceContext.idle)
        }
    }

    private var isAuraExperience: Bool {
        if case .experience(.aura) = flow.route { return true }
        return false
    }

    private var isReachCalibrationExperience: Bool {
        switch flow.route {
        case .experience(.reachCalibration), .experience(.competitionCalibration):
            return true
        default:
            return false
        }
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
        switch session.auraPunch.phase {
        case .guiding, .countdown, .attempting:
            return .coaching
        default:
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
        case .experience(.aura(let technique, _)):
            let action = technique.name.lowercased()
            switch session.auraPunch.phase {
            case .idle:
                if session.auraPunch.statusMessage == "Stopped" {
                    return ImmersiveInstruction(
                        stage: "TRAINING STOPPED",
                        message: "Your training was stopped",
                        symbol: "stop.circle.fill"
                    )
                }
                return ImmersiveInstruction(
                    stage: "GET READY",
                    message: "Raise your guard — the hologram will show you the punch",
                    symbol: "figure.boxing"
                )
            case .acquiring:
                return ImmersiveInstruction(
                    stage: "GET READY",
                    message: "Raise your guard and keep both hands visible",
                    symbol: "hand.raised.fill"
                )
            case .guiding, .countdown, .attempting:
                return ImmersiveInstruction(
                    stage: session.auraPunch.coachingHeadline,
                    message: session.auraPunch.coachingDetail,
                    symbol: auraCoachingSymbol
                )
            case .scoring:
                return ImmersiveInstruction(
                    stage: "REP COMPLETE",
                    message: "Hold your guard while we score your \(action)",
                    symbol: "waveform.path.ecg"
                )
            case .results:
                return ImmersiveInstruction(
                    stage: "COMPLETE",
                    message: "Your results are ready",
                    symbol: "checkmark.circle.fill"
                )
            }

        case .experience(.reactive(_, let combination, _)):
            switch session.phase {
            case .idle:
                if session.lastFeedback == "Drill stopped" {
                    return ImmersiveInstruction(
                        stage: "TRAINING STOPPED",
                        message: "Your training was stopped",
                        symbol: "stop.circle.fill"
                    )
                }
                return ImmersiveInstruction(
                    stage: "GET READY",
                    message: "Raise your guard and watch for the target",
                    symbol: "scope"
                )
            case .calibrating:
                return ImmersiveInstruction(
                    stage: "CALIBRATING",
                    message: session.lastFeedback,
                    symbol: "ruler"
                )
            case .running:
                return ImmersiveInstruction(
                    stage: session.progressLabel.uppercased(),
                    message: session.lastFeedback,
                    symbol: combination == nil ? "bolt.fill" : "list.number"
                )
            case .finished:
                return ImmersiveInstruction(
                    stage: session.lastFeedback == "Drill stopped"
                        ? "TRAINING STOPPED"
                        : "ROUND COMPLETE",
                    message: session.lastFeedback,
                    symbol: session.lastFeedback == "Drill stopped"
                        ? "stop.circle.fill"
                        : "checkmark.circle.fill"
                )
            }

        default:
            return ImmersiveInstruction(
                stage: "BOXING COACH",
                message: "Preparing your training space",
                symbol: "figure.boxing"
            )
        }
    }

    private var auraCoachingSymbol: String {
        switch session.auraPunch.phase {
        case .guiding:
            return "eye.fill"
        case .countdown:
            return "timer"
        case .attempting:
            return "figure.boxing"
        default:
            return "figure.boxing"
        }
    }
}
