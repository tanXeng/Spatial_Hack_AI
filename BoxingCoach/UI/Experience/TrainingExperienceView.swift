import SwiftUI

struct TrainingExperienceView: View {
    let selection: TrainingSelection
    let session: ReactiveStrikeSession
    let calibration: BodyCalibration
    let presentationError: String?
    let controlsDisabled: Bool
    let onStart: () -> Void
    let onChangeSelection: () -> Void
    let onFinishCalibration: () -> Void

    var body: some View {
        switch selection {
        case .reactive(let mode, let combination, let stance):
            reactiveExperience(mode: mode, combination: combination, stance: stance)
        case .aura(let technique, let stance):
            auraExperience(technique: technique, stance: stance)
        case .calibration:
            calibrationExperience
        case .competitionCalibration:
            reachCalibrationExperience(backLabel: "Competition")
        case .competition(_, let mode, let stance, _):
            reactiveExperience(
                mode: mode == .combination ? .combination : .air,
                combination: mode == .combination ? .jabCrossHookCross : nil,
                stance: stance
            )
        }
    }

    private func reachCalibrationExperience(backLabel: String) -> some View {
        TrainingDetailScaffold(
            backLabel: backLabel,
            title: "Reach Calibration",
            subtitle: "Measure both comfortable reaches",
            controlsDisabled: controlsDisabled,
            onBack: onChangeSelection
        ) {
            VStack(spacing: 16) {
                TrainingStatusCard(message: reactiveStatusLine)
                errorCards(engineError: session.errorMessage)
                Button(session.phase == .finished ? "Calibrate Again" : "Start Calibration") {
                    onStart()
                }
                .disabled(session.phase == .running || session.phase == .calibrating || controlsDisabled)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var calibrationExperience: some View {
        TrainingDetailScaffold(
            backLabel: "Back to Features",
            title: "Anthropometry",
            subtitle: "Measure your reach and guard once for this session",
            controlsDisabled: controlsDisabled,
            // The first calibration of a launch is mandatory — there is nothing behind it to
            // return to, and the feature menu is unusable without a measurement.
            showsBack: calibration.isCalibrated,
            onBack: onChangeSelection
        ) {
            VStack(spacing: 16) {
                TrainingStatusCard(message: calibrationStatusLine)

                if calibration.isCalibrated, let reach = calibration.measuredReach {
                    calibrationResultsCard(reach: reach)
                }

                errorCards(engineError: session.errorMessage)

                if calibration.isCalibrated {
                    Button("Measure Again") {
                        onStart()
                    }
                    .disabled(session.phase == .calibrating || controlsDisabled)
                    .buttonStyle(.bordered)

                    Button("Continue to Training") {
                        onFinishCalibration()
                    }
                    .disabled(controlsDisabled)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Start Calibration") {
                        onStart()
                    }
                    .disabled(session.phase == .calibrating || controlsDisabled)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func calibrationResultsCard(reach: Float) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Measured")
                .font(.headline)

            LabeledMetricRow(
                title: "Forward reach",
                value: String(format: "%.0f cm", reach * 100),
                spokenValue: String(format: "%.0f centimeters", reach * 100)
            )

            ForEach([BodySide.left, .right], id: \.rawValue) { side in
                if let sideReach = calibration.reaches[side] {
                    LabeledMetricRow(
                        title: "\(side.rawValue.capitalized) arm",
                        value: String(format: "%.0f cm", sideReach * 100),
                        spokenValue: String(format: "%.0f centimeters", sideReach * 100)
                    )
                }
            }

            Text("Targets are placed from the shorter arm so both hands can reach every one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var calibrationStatusLine: String {
        if session.phase == .calibrating {
            return session.lastFeedback
        }
        if calibration.isCalibrated {
            return session.lastFeedback
        }
        return "Stand facing forward with room to punch, then tap Start Calibration"
    }

    private func reactiveExperience(
        mode: ReactiveStrikeMode,
        combination: Combination?,
        stance: Stance
    ) -> some View {
        let subtitle: String
        if let combination {
            subtitle = "\(stance.title) · \(combination.numberNotation) · \(combination.name)"
        } else {
            subtitle = mode.title
        }

        return TrainingDetailScaffold(
            backLabel: combination == nil ? "Change Mode" : "Change Combination",
            title: "Reactive Strike",
            subtitle: subtitle,
            controlsDisabled: controlsDisabled,
            onBack: onChangeSelection
        ) {
            VStack(spacing: 16) {
                TrainingStatusCard(message: reactiveStatusLine)

                if session.phase == .finished {
                    reactiveResultsCard
                }

                errorCards(engineError: session.errorMessage)

                Button(session.phase == .finished ? "Try Again" : "Start Drill") {
                    onStart()
                }
                .disabled(
                    session.phase == .running || session.phase == .calibrating || controlsDisabled
                )
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func auraExperience(technique: Technique, stance: Stance) -> some View {
        let aura = session.auraPunch

        return TrainingDetailScaffold(
            backLabel: "Change Technique",
            title: technique.name,
            subtitle: "\(stance.title) · \(technique.hand.requirementDescription(for: stance))",
            controlsDisabled: controlsDisabled,
            onBack: onChangeSelection
        ) {
            VStack(spacing: 16) {
                TrainingStatusCard(message: auraStatusLine)

                if aura.phase == .attempting || aura.phase == .guiding {
                    PunchExtensionMeter(value: aura.liveReach)
                }

                if aura.phase == .results, let score = aura.score {
                    if let note = score.wrongHandNote {
                        Label(note, systemImage: "hand.raised.slash")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }

                    auraScoreCard(score)
                    if let feedback = aura.feedback {
                        auraFeedbackCard(feedback)
                    }
                }

                errorCards(engineError: aura.errorMessage)

                Button(aura.phase == .results ? "Try Again" : "Start Rep") {
                    onStart()
                }
                .disabled(aura.isRunning || controlsDisabled)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func errorCards(engineError: String?) -> some View {
        if let presentationError {
            TrainingErrorCard(message: presentationError)
        }
        if let engineError, engineError != presentationError {
            TrainingErrorCard(message: engineError)
        }
    }

    private var reactiveStatusLine: String {
        if session.phase == .calibrating {
            return session.lastFeedback
        }
        if session.phase == .running {
            return "\(session.progressLabel) · \(session.lastFeedback)"
        }
        if session.phase == .finished {
            return session.lastFeedback == "Drill stopped"
                ? "Training stopped · Partial results"
                : "Round complete"
        }
        if session.lastFeedback == "Drill stopped" {
            return "Training stopped · Start again when you're ready"
        }
        return "Tap Start Drill to begin"
    }

    private var auraStatusLine: String {
        let aura = session.auraPunch
        if aura.phase == .attempting, aura.currentScoredPunch > 0 {
            return "Punch \(aura.currentScoredPunch) of \(aura.scoredPunchCount) — hit the target!"
        }
        if aura.phase == .idle, aura.errorMessage == nil {
            if aura.statusMessage == "Stopped" {
                return "Training stopped · Start again when you're ready"
            }
            return "Tap Start Rep when you're in guard"
        }
        return aura.statusMessage
    }

    private var reactiveResultsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Results")
                .font(.headline)

            LabeledMetricRow(title: "Hits", value: "\(session.metrics.hitCount)")
            LabeledMetricRow(title: "Misses", value: "\(session.metrics.missCount)")
            if session.mode == .combination {
                LabeledMetricRow(
                    title: "Combinations completed",
                    value: "\(session.comboRepsCompleted) / \(session.comboRepeatCount)"
                )
            }
            LabeledMetricRow(
                title: "Accuracy",
                value: String(format: "%.0f%%", session.metrics.accuracy * 100)
            )

            if let average = session.metrics.averageReactionTime {
                LabeledMetricRow(
                    title: "Average reaction",
                    value: String(format: "%.0f ms", average * 1000),
                    spokenValue: String(format: "%.0f milliseconds", average * 1000)
                )
            }

            if let speed = session.metrics.averageEstimatedSpeed {
                LabeledMetricRow(
                    title: "Average estimated speed",
                    value: String(format: "%.2f m/s", speed),
                    spokenValue: String(format: "%.2f meters per second", speed)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func auraScoreCard(_ score: TechniqueScore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Score")
                .font(.headline)

            LabeledMetricRow(
                title: "Overall",
                value: "\(Int(score.overall.rounded())) · \(score.grade)"
            )

            if score.wrongHand {
                Text("Reduced: thrown with the \(score.thrownHandName) hand instead of the \(score.requiredHandName).")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Divider()

            ForEach(score.metrics) { metric in
                LabeledMetricRow(
                    title: metric.kind.title,
                    value: metric.score.map { "\(Int($0.rounded()))" } ?? "Not tracked"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func auraFeedbackCard(_ feedback: CoachingFeedback) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Coach")
                    .font(.headline)
                Spacer()
                if feedback.isOffline {
                    Text("Offline")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                }
            }

            Text(feedback.headline)
                .font(.body.weight(.medium))
            Text(feedback.primaryFix)
                .font(.body)
                .foregroundStyle(.secondary)
            Text(feedback.encouragement)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
