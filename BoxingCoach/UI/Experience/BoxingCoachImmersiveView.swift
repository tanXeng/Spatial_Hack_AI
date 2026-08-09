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

            Attachment(id: controlsAttachmentID) {
                Button("End Training", systemImage: "stop.circle") {
                    endTraining()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(isAuraExperience ? .large : .regular)
                .font(isAuraExperience ? .title3.weight(.semibold) : .body)
                .disabled(flow.controlsDisabled)
                .padding(isAuraExperience ? 18 : 14)
                .glassBackgroundEffect()
                .accessibilityHint("Ends the current training session and returns to results")
            }
        }
        .onChange(of: session.phase) { _, phase in
            guard phase == .finished else { return }
            switch flow.route {
            case .experience(.reactive):
                announce("Reactive Strike complete")
                finishTraining()
            case .experience(.calibration):
                announce("Calibration complete")
                finishTraining()
            default:
                return
            }
        }
        .onChange(of: session.auraPunch.phase) { _, phase in
            guard case .experience(.aura) = flow.route,
                  phase == .results else { return }
            announce("Aura Punch scoring complete")
            finishTraining()
        }
        .onChange(of: session.errorMessage) { _, message in
            guard let message else { return }
            switch flow.route {
            case .experience(.reactive), .experience(.calibration):
                announce(message)
                finishTraining()
            default:
                return
            }
        }
        .onChange(of: session.auraPunch.errorMessage) { _, message in
            guard case .experience(.aura) = flow.route,
                  let message else { return }
            announce(message)
            finishTraining()
        }
        .onChange(of: session.lastFeedback) { _, message in
            guard session.phase == .running || session.phase == .calibrating else { return }
            switch flow.route {
            case .experience(.reactive), .experience(.calibration):
                announce(message)
            default:
                return
            }
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
    }

    private var isAuraExperience: Bool {
        if case .experience(.aura) = flow.route { return true }
        return false
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
            case .coachDemo, .guiding, .countdown, .attempting:
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

        case .experience(.calibration):
            switch session.phase {
            case .idle:
                return ImmersiveInstruction(
                    stage: "ANTHROPOMETRY",
                    message: "Stand facing forward with room to punch",
                    symbol: "ruler"
                )
            case .calibrating, .running:
                return ImmersiveInstruction(
                    stage: "MEASURING",
                    message: session.lastFeedback,
                    symbol: "ruler"
                )
            case .finished:
                return ImmersiveInstruction(
                    stage: "MEASURED",
                    message: session.lastFeedback,
                    symbol: "checkmark.circle.fill"
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
        case .coachDemo:
            return "figure.boxing"
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
