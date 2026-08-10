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
            reactiveExperience(
                mode: mode,
                combination: combination,
                stance: stance,
                competitionMode: nil
            )
        case .aura(let technique, let stance):
            auraExperience(technique: technique, stance: stance)
        case .calibration:
            calibrationExperience(context: .gate)
        case .competitionCalibration:
            calibrationExperience(context: .competition)
        case .competition(_, let mode, let stance, _):
            reactiveExperience(
                mode: mode == .combination ? .combination : .air,
                combination: mode == .combination ? .jabCrossHookCross : nil,
                stance: stance,
                competitionMode: mode
            )
        }
    }

    /// Where a calibration run was entered from. The measurement itself is identical either way —
    /// only the chrome and the follow-on action differ, which is why there is one screen and not
    /// two. Competition previously had its own copy that reported no result at all.
    private enum CalibrationContext {
        /// The mandatory Anthropometry gate at launch.
        case gate
        /// Measuring on behalf of a Competition player.
        case competition

        var backLabel: String { self == .gate ? "Back to Features" : "Competition" }
        var title: String { self == .gate ? "Anthropometry" : "Reach Calibration" }
        var subtitle: String {
            self == .gate
                ? "Measure your reach and guard once for this session"
                : "Measure both comfortable reaches for this player"
        }
    }

    private func calibrationExperience(context: CalibrationContext) -> some View {
        TrainingDetailScaffold(
            backLabel: context.backLabel,
            title: context.title,
            subtitle: context.subtitle,
            controlsDisabled: controlsDisabled,
            // The first calibration of a launch is mandatory — there is nothing behind it to
            // return to, and the feature menu is unusable without a measurement. Competition is
            // always entered from somewhere, so its Back is never hidden.
            showsBack: context == .competition || calibration.isCalibrated,
            onBack: onChangeSelection
        ) {
            VStack(spacing: 16) {
                TrainingStatusCard(message: calibrationStatusLine)

                if session.phase == .calibrating {
                    calibrationProgressCard
                }

                if calibration.isCalibrated, let reach = calibration.measuredReach {
                    calibrationResultsCard(reach: reach)
                }

                errorCards(engineError: session.errorMessage)

                calibrationActions(context: context)
            }
        }
    }

    @ViewBuilder
    private func calibrationActions(context: CalibrationContext) -> some View {
        let isMeasuring = session.phase == .calibrating

        if calibration.isCalibrated {
            Button("Measure Again") { onStart() }
                .disabled(isMeasuring || controlsDisabled)
                .buttonStyle(.bordered)

            // The gate owns the "you are done, move on" step. From Competition the caller already
            // knows where the player goes next, so Back is the only exit and adding a second
            // forward button here would give two answers to the same question.
            if context == .gate {
                Button("Continue to Training") { onFinishCalibration() }
                    .disabled(controlsDisabled)
                    .buttonStyle(.borderedProminent)
            }
        } else {
            Button("Start Calibration") { onStart() }
                .disabled(isMeasuring || controlsDisabled)
                .buttonStyle(.borderedProminent)
        }
    }

    /// Live per-arm progress while measuring.
    ///
    /// `OrderedReachCalibration` measures the left arm to completion before it will accept a single
    /// right-arm sample. Showing that ordering is the point: without it, a user whose right arm is
    /// being deliberately ignored has no way to tell that from tracking having failed.
    private var calibrationProgressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach([BodySide.left, .right], id: \.rawValue) { side in
                calibrationArmRow(side: side)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func calibrationArmRow(side: BodySide) -> some View {
        let stage = session.calibrationStage
        let measured = calibration.reaches[side]
        let isActive = stage?.activeSide == side
        let state: String
        if let measured {
            state = String(format: "%.0f cm", measured * 100)
        } else if isActive {
            state = stage?.isMeasuring == true ? "Hold full extension" : "Return to guard"
        } else {
            state = "Waiting"
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    "\(side.rawValue.capitalized) arm",
                    systemImage: measured != nil
                        ? "checkmark.circle.fill"
                        : (isActive ? "circle.dotted" : "circle")
                )
                .foregroundStyle(measured != nil ? .primary : (isActive ? .primary : .secondary))
                Spacer()
                Text(state)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Only the arm actually being measured gets a live meter; a static bar on the waiting
            // arm would read as that arm having been measured at zero.
            if isActive, measured == nil {
                PunchExtensionMeter(value: session.calibrationLiveExtension)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(side.rawValue.capitalized) arm")
        .accessibilityValue(state)
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
        stance: Stance,
        competitionMode: CompetitionMode?
    ) -> some View {
        let subtitle: String
        if let combination {
            subtitle = "\(stance.title) · \(combination.numberNotation) · \(combination.name)"
        } else if let competitionMode {
            subtitle = competitionMode.subtitle
        } else {
            subtitle = mode.title
        }

        let backLabel = competitionMode == nil
            ? (combination == nil ? "Change Mode" : "Change Combination")
            : (competitionMode == .combination ? "Change Stance" : "Competition")
        let title = competitionMode.map { "\($0.title) Competition" } ?? "Reactive Strike"

        return TrainingDetailScaffold(
            backLabel: backLabel,
            title: title,
            subtitle: subtitle,
            controlsDisabled: controlsDisabled,
            onBack: onChangeSelection
        ) {
            VStack(spacing: 16) {
                TrainingStatusCard(message: reactiveStatusLine(competitionMode: competitionMode))

                if session.phase == .finished {
                    reactiveResultsCard
                }

                errorCards(engineError: session.errorMessage)

                Button(session.phase == .finished
                       ? "Try Again"
                       : (competitionMode == nil ? "Start Drill" : "Start Ranked Round")) {
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

    private func reactiveStatusLine(competitionMode: CompetitionMode? = nil) -> String {
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
        return competitionMode == nil
            ? "Tap Start Drill to begin"
            : "Tap Start Ranked Round when you're ready"
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
