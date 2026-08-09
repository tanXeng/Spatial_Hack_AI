import Accessibility
import RealityKit
import SwiftUI

enum ImmersiveTrainingControlsLayout {
    /// Keep the safety control in one predictable place for every immersive experience.
    /// This matches the established Reactive Strike placement and avoids Aura Punch putting
    /// the same control near the floor.
    static let worldPosition = SIMD3<Float>(0, 0.78, -0.9)
}

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

            if let instructions = attachments.entity(for: instructionsAttachmentID) {
                instructions.name = "TrainingInstructions"
                // The calibrated session moves this once into the user's body-relative world
                // frame. It intentionally does not follow the head continuously.
                instructions.position = SIMD3<Float>(0, 1.55, -1.10)
                root.addChild(instructions)
            }

            if let controls = attachments.entity(for: controlsAttachmentID) {
                controls.name = "TrainingControls"
                controls.position = ImmersiveTrainingControlsLayout.worldPosition
                root.addChild(controls)
            }

            session.attachSceneRoot(root)
            flow.immersiveSceneDidBecomeReady(session: session)
        } update: { content, _ in
            guard let position = session.instructionPanelWorldPosition,
                  let instructions = content.entities.first?.findEntity(named: "TrainingInstructions")
            else { return }
            instructions.position = position
        } attachments: {
            Attachment(id: instructionsAttachmentID) {
                ImmersiveInstructionBanner(
                    instruction: currentInstruction,
                    style: auraBannerStyle
                )
            }

            Attachment(id: controlsAttachmentID) {
                VStack(spacing: 10) {
                    if session.isTrackingPaused {
                        if isCompetitionExperience {
                            Label("Tracking paused · Return to guard", systemImage: "hand.raised.fill")
                                .accessibilityLabel("Tracking paused. Hold both fists in guard to resume automatically.")
                        } else {
                            Button("Resume Training", systemImage: "play.circle.fill") {
                                session.requestTrackingResume()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!session.trackingReadyToResume)
                            .accessibilityHint("Available after both hands return to guard with stable tracking")
                        }
                    }
                    Button("End Training", systemImage: "stop.circle") {
                        endTraining()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(flow.controlsDisabled)
                    .accessibilityHint("Ends the current training session and returns to results")
                }
                .controlSize(isAuraExperience ? .large : .regular)
                .font(isAuraExperience ? .title3.weight(.semibold) : .body)
                .padding(isAuraExperience ? 18 : 14)
                .glassBackgroundEffect()
            }
        }
        .onChange(of: session.phase) { _, phase in
            guard isReactiveExperience, phase == .finished else { return }
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
            guard isReactiveExperience, let message else { return }
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
            guard isReactiveExperience,
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
    }

    private var isAuraExperience: Bool {
        if case .experience(.aura) = flow.route { return true }
        return false
    }

    private var isReactiveExperience: Bool {
        switch flow.route {
        case .experience(.reactive),
             .experience(.competitionCalibration),
             .experience(.competition):
            return true
        default:
            return false
        }
    }

    private var isCompetitionExperience: Bool {
        if case .experience(.competition) = flow.route { return true }
        return false
    }

    private var auraBannerStyle: ImmersiveInstructionBannerStyle {
        guard isAuraExperience else { return .compact }
        return AuraBannerPresentation.style(for: session.auraPunch.phase)
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

        case .experience(.competitionCalibration):
            switch session.phase {
            case .idle:
                return ImmersiveInstruction(
                    stage: "REACH CALIBRATION",
                    message: session.lastFeedback,
                    symbol: "ruler"
                )
            case .calibrating:
                return ImmersiveInstruction(
                    stage: "CALIBRATING",
                    message: session.lastFeedback,
                    symbol: "ruler"
                )
            case .running:
                return ImmersiveInstruction(stage: "CALIBRATING", message: session.lastFeedback, symbol: "ruler")
            case .finished:
                return ImmersiveInstruction(
                    stage: "CALIBRATION SAVED",
                    message: "Return to choose a competition mode",
                    symbol: "checkmark.circle.fill"
                )
            }

        case .experience(.competition(_, let mode, _, _)):
            switch session.phase {
            case .idle:
                return ImmersiveInstruction(
                    stage: "COMPETITION",
                    message: session.lastFeedback,
                    symbol: "trophy.fill"
                )
            case .calibrating:
                return ImmersiveInstruction(
                    stage: "CAPTURING GUARD",
                    message: session.lastFeedback,
                    symbol: "hand.raised.fill"
                )
            case .running:
                return ImmersiveInstruction(
                    stage: session.progressLabel.uppercased(),
                    message: session.lastFeedback,
                    symbol: mode == .combination ? "list.number" : "scope"
                )
            case .finished:
                return ImmersiveInstruction(
                    stage: "ROUND COMPLETE",
                    message: "Your result is ready",
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
