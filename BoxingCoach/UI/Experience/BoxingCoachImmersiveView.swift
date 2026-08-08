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
                controls.position = SIMD3<Float>(0, 0.78, -0.9)
                root.addChild(controls)
            }

            session.attachSceneRoot(root)
            flow.immersiveSceneDidBecomeReady(session: session)
        } attachments: {
            Attachment(id: instructionsAttachmentID) {
                ImmersiveInstructionBanner(instruction: currentInstruction)
            }

            Attachment(id: controlsAttachmentID) {
                Button("End Training", systemImage: "stop.circle") {
                    endTraining()
                }
                .buttonStyle(.borderedProminent)
                .disabled(flow.controlsDisabled)
                .padding(14)
                .glassBackgroundEffect()
                .accessibilityHint("Ends the current training session and returns to results")
            }
        }
        .onChange(of: session.phase) { _, phase in
            guard case .experience(.reactive) = flow.route,
                  phase == .finished else { return }
            announce("Reactive Strike complete")
            finishTraining()
        }
        .onChange(of: session.auraPunch.phase) { _, phase in
            guard case .experience(.aura) = flow.route,
                  phase == .results else { return }
            announce("Aura Punch scoring complete")
            finishTraining()
        }
        .onChange(of: session.errorMessage) { _, message in
            guard case .experience(.reactive) = flow.route,
                  let message else { return }
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
            guard case .experience(.reactive) = flow.route,
                  session.phase == .running else { return }
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
                return ImmersiveInstruction(
                    stage: "GET READY",
                    message: "Raise your guard to begin the \(action) training",
                    symbol: "figure.boxing"
                )
            case .acquiring:
                return ImmersiveInstruction(
                    stage: "GET READY",
                    message: "Raise your guard and keep both hands visible",
                    symbol: "hand.raised.fill"
                )
            case .guiding:
                return ImmersiveInstruction(
                    stage: "FOLLOW THE SAMPLE",
                    message: session.auraPunch.statusMessage,
                    symbol: "eye.fill"
                )
            case .countdown:
                return ImmersiveInstruction(
                    stage: "YOUR TURN",
                    message: session.auraPunch.statusMessage,
                    symbol: "timer"
                )
            case .attempting:
                return ImmersiveInstruction(
                    stage: "YOUR TURN",
                    message: "Try the \(action) on your own",
                    symbol: "figure.boxing"
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

        case .experience(.reactive):
            switch session.phase {
            case .idle:
                return ImmersiveInstruction(
                    stage: "GET READY",
                    message: "Raise your guard and watch for the target",
                    symbol: "scope"
                )
            case .running:
                return ImmersiveInstruction(
                    stage: session.progressLabel.uppercased(),
                    message: session.lastFeedback,
                    symbol: "bolt.fill"
                )
            case .finished:
                return ImmersiveInstruction(
                    stage: "ROUND COMPLETE",
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
}
