enum ImmersiveTrainingContext: Equatable {
    case aura
    case standard(isCombination: Bool)
    case reachCalibration
    case competitionCalibration
    case competition(isCombination: Bool)

    init(selection: TrainingSelection) {
        switch selection {
        case .aura:
            self = .aura
        case .reactive(_, let combination, _):
            self = .standard(isCombination: combination != nil)
        case .reachCalibration:
            self = .reachCalibration
        case .competitionCalibration:
            self = .competitionCalibration
        case .competition(_, let mode, _, _):
            self = .competition(isCombination: mode == .combination)
        }
    }
}

enum ImmersiveInstructionPolicy {
    static func completionAnnouncement(
        for context: ImmersiveTrainingContext,
        wasStoppedBeforeCompletion: Bool
    ) -> String? {
        guard !wasStoppedBeforeCompletion else { return nil }
        switch context {
        case .aura:
            return "Aura Punch complete"
        case .standard:
            return "Reactive Strike complete"
        case .reachCalibration:
            return "Reach calibration complete"
        case .competitionCalibration:
            return "Competition fit complete"
        case .competition:
            return "Ranked round complete"
        }
    }

    static func instruction(
        for context: ImmersiveTrainingContext,
        phase: DrillPhase,
        progressLabel: String,
        feedback: String,
        trackingPaused: Bool
    ) -> ImmersiveInstruction {
        if feedback == "Drill stopped" {
            return ImmersiveInstruction(
                stage: "TRAINING STOPPED",
                message: "Your training was stopped",
                symbol: "stop.circle.fill"
            )
        }

        switch context {
        case .aura:
            return ImmersiveInstruction(
                stage: "BOXING COACH",
                message: "Preparing your training space",
                symbol: "figure.boxing"
            )

        case .standard(let isCombination):
            if trackingPaused {
                return pausedInstruction(stage: "TRAINING PAUSED", message: feedback)
            }
            switch phase {
            case .idle:
                return ImmersiveInstruction(
                    stage: "GET READY",
                    message: "Raise your guard and watch for the target",
                    symbol: "scope"
                )
            case .calibrating:
                return ImmersiveInstruction(
                    stage: "CALIBRATING",
                    message: feedback,
                    symbol: "ruler"
                )
            case .running:
                return ImmersiveInstruction(
                    stage: progressLabel.uppercased(),
                    message: feedback,
                    symbol: isCombination ? "list.number" : "bolt.fill"
                )
            case .finished:
                return ImmersiveInstruction(
                    stage: "ROUND COMPLETE",
                    message: feedback,
                    symbol: "checkmark.circle.fill"
                )
            }

        case .reachCalibration:
            switch phase {
            case .idle:
                return ImmersiveInstruction(
                    stage: "REACH CALIBRATION",
                    message: "Stand naturally, keep the floor clear, and bring both fists into view.",
                    symbol: "ruler"
                )
            case .calibrating, .running:
                return ImmersiveInstruction(
                    stage: "MEASURING REACH",
                    message: feedback,
                    symbol: "ruler"
                )
            case .finished:
                return ImmersiveInstruction(
                    stage: "REACH READY",
                    message: feedback,
                    symbol: "checkmark.circle.fill"
                )
            }

        case .competitionCalibration:
            switch phase {
            case .idle:
                return ImmersiveInstruction(
                    stage: "COMPETITION FIT",
                    message: "This reach check keeps every ranked target inside your comfortable range.",
                    symbol: "figure.arms.open"
                )
            case .calibrating, .running:
                return ImmersiveInstruction(
                    stage: "COMPETITION FIT",
                    message: feedback,
                    symbol: "figure.arms.open"
                )
            case .finished:
                return ImmersiveInstruction(
                    stage: "COMPETITION FIT COMPLETE",
                    message: feedback,
                    symbol: "checkmark.circle.fill"
                )
            }

        case .competition:
            if trackingPaused {
                return pausedInstruction(stage: "ROUND PAUSED", message: feedback)
            }
            switch phase {
            case .idle:
                return ImmersiveInstruction(
                    stage: "RANKED ROUND READY",
                    message: "Raise your guard. The timer begins with your first target.",
                    symbol: "trophy.fill"
                )
            case .calibrating:
                return ImmersiveInstruction(
                    stage: "RANKED ROUND READY",
                    message: feedback,
                    symbol: "trophy.fill"
                )
            case .running:
                return ImmersiveInstruction(
                    stage: "RANKED · \(progressLabel.uppercased())",
                    message: feedback,
                    symbol: "trophy.fill"
                )
            case .finished:
                return ImmersiveInstruction(
                    stage: "RANKED ROUND COMPLETE",
                    message: feedback,
                    symbol: "checkmark.circle.fill"
                )
            }
        }
    }

    private static func pausedInstruction(stage: String, message: String) -> ImmersiveInstruction {
        ImmersiveInstruction(
            stage: stage,
            message: message,
            symbol: "pause.circle.fill"
        )
    }
}
