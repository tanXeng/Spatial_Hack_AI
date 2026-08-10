import SwiftUI

/// Pure policy separating trusted score presentation from evidence-recovery presentation.
nonisolated enum AuraResultPresentation: Equatable, Sendable {
    case score
    case evidenceRecovery(title: String, message: String)

    init(feedback: CoachingFeedback) {
        if feedback.correctionCode == .trackingRecovery {
            self = .evidenceRecovery(
                title: "Score withheld",
                message: "Tracking coverage was incomplete, so this rep has no numeric grade or metric result. Return to guard and keep both fists visible for the full rep."
            )
        } else {
            self = .score
        }
    }
}

struct TrainingExperienceView: View {
    @AccessibilityFocusState private var resultPrimaryActionFocused: Bool

    let selection: TrainingSelection
    let session: ReactiveStrikeSession
    let presentationError: String?
    let controlsDisabled: Bool
    let onStart: () -> Void
    let onChangeSelection: () -> Void

    var body: some View {
        Group {
            switch selection {
            case .reactive(let mode, let combination, let stance):
                reactiveExperience(mode: mode, combination: combination, stance: stance)
            case .aura(let track, let technique, let stance):
                auraExperience(track: track, technique: technique, stance: stance)
            case .reachCalibration:
                reachCalibrationExperience(backLabel: "Home")
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
        .onChange(of: session.phase) { _, phase in
            if phase == .finished { resultPrimaryActionFocused = true }
        }
        .onChange(of: session.auraPunch.phase) { _, phase in
            if phase == .results { resultPrimaryActionFocused = true }
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
                recoveryCard
                errorCards(engineError: session.errorMessage)
                if !recoveryReplacesStartAction {
                    Button(session.phase == .finished ? "Calibrate Again" : "Start Calibration") {
                        onStart()
                    }
                    .disabled(session.phase == .running || session.phase == .calibrating || controlsDisabled)
                    .buttonStyle(.borderedProminent)
                    .accessibilityFocused($resultPrimaryActionFocused)
                }
            }
        }
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
                recoveryCard

                if session.phase == .finished {
                    reactiveResultsCard
                }

                errorCards(engineError: session.errorMessage)

                if !recoveryReplacesStartAction {
                    Button(session.phase == .finished ? "Try Again" : "Start Drill") {
                        onStart()
                    }
                    .disabled(
                        session.phase == .running || session.phase == .calibrating || controlsDisabled
                    )
                    .buttonStyle(.borderedProminent)
                    .accessibilityFocused($resultPrimaryActionFocused)
                }
            }
        }
    }

    private func auraExperience(
        track: TrainingTrack,
        technique: Technique,
        stance: Stance
    ) -> some View {
        let aura = session.auraPunch

        return TrainingDetailScaffold(
            backLabel: "Change Technique",
            title: technique.name,
            subtitle: "\(track.title) · \(stance.title) · \(technique.hand.requirementDescription(for: stance))",
            controlsDisabled: controlsDisabled,
            onBack: onChangeSelection
        ) {
            VStack(spacing: 16) {
                TrainingStatusCard(message: auraStatusLine)
                recoveryCard

                if aura.phase == .attempting || aura.phase == .guiding {
                    PunchExtensionMeter(value: aura.liveReach)
                }

                if aura.phase == .results, let proof = aura.proofMetric {
                    auraProofCard(proof)
                    if let feedback = aura.feedback {
                        auraFeedbackCard(feedback)
                    }
                } else if aura.phase == .results, let score = aura.score {
                    if let feedback = aura.feedback {
                        switch AuraResultPresentation(feedback: feedback) {
                        case .score:
                            if let note = score.wrongHandNote {
                                Label(note, systemImage: "hand.raised.slash")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                                    .background(
                                        .regularMaterial,
                                        in: RoundedRectangle(cornerRadius: 16)
                                    )
                            }
                            auraScoreCard(score)
                        case let .evidenceRecovery(title, message):
                            auraEvidenceRecoveryCard(title: title, message: message)
                        }

                        auraFeedbackCard(feedback)
                    }
                }

                errorCards(engineError: aura.errorMessage)

                if !recoveryReplacesStartAction {
                    Button(aura.phase == .results ? "Try Again" : "Start Rep") {
                        onStart()
                    }
                    .disabled(aura.isRunning || controlsDisabled)
                    .buttonStyle(.borderedProminent)
                    .accessibilityFocused($resultPrimaryActionFocused)
                }
            }
        }
    }

    @ViewBuilder
    private var recoveryCard: some View {
        if let recoveryPresentation {
            RuntimeRecoveryCard(
                presentation: recoveryPresentation,
                controlsDisabled: controlsDisabled,
                action: recoveryAction(for: recoveryPresentation.action)
            )
        }
    }

    private var recoveryPresentation: RuntimeRecoveryPresentation? {
        RuntimeRecoveryPolicy.presentation(
            trackingState: session.hands.runtimeState,
            trackingReason: session.hands.rejectionReason,
            trackingInstruction: session.hands.recoveryInstruction,
            audioRequiresExplicitRecovery: session.audioCoordinator.presentation.requiresExplicitRecovery,
            voiceState: session.voiceCoach.state
        )
    }

    private var recoveryReplacesStartAction: Bool {
        recoveryPresentation?.replacesTrainingStartAction == true
    }

    private func recoveryAction(for action: RuntimeRecoveryAction) -> (() -> Void)? {
        switch action {
        case .resumeAudio:
            // The global Ask Coach panel already owns the single window-level Resume Audio button.
            nil
        case .reviewTrackingPermission, .retryTracking:
            onStart
        case .returnToSetup:
            onChangeSelection
        case .waitForTracking, .useVisibleControls:
            nil
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
            return [aura.cyclePresentation.progress, aura.cyclePresentation.instruction]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        if aura.phase == .idle, aura.errorMessage == nil {
            if aura.statusMessage == "Stopped" {
                return "Training stopped · Start again when you're ready"
            }
            return "Tap Start Rep when you're in guard"
        }
        return aura.statusMessage
    }

    private func auraProofCard(_ proof: CoachingProofMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Like-for-like proof")
                .font(.headline)

            LabeledMetricRow(
                title: proof.kind.title,
                value: "\(Int(proof.baseline.rounded())) → \(Int(proof.retest.rounded()))"
            )
            LabeledMetricRow(
                title: "Change",
                value: proof.delta > 0
                    ? "+\(Int(proof.delta.rounded()))"
                    : "\(Int(proof.delta.rounded()))"
            )
            LabeledMetricRow(
                title: "Tracking",
                value: "\(Int((proof.trackedFraction * 100).rounded()))%"
            )
            Text("Evidence: \(proof.evidenceLabel.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(proof.sourceBadge)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(proof.kind.title) proof")
        .accessibilityValue(
            "Baseline \(Int(proof.baseline.rounded())), retest \(Int(proof.retest.rounded())), change \(Int(proof.delta.rounded())), \(Int((proof.trackedFraction * 100).rounded())) percent tracked, \(proof.evidenceLabel.rawValue)"
        )
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
                value: auraOverallDisplay(score)
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
                    value: auraMetricDisplay(metric.score)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func auraEvidenceRecoveryCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "viewfinder.trianglebadge.exclamationmark")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
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
                Text(feedback.isOffline ? "Offline" : "AI supplement")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
            }

            Text(feedback.headline)
                .font(.body.weight(.medium))
            Text(feedback.primaryFix)
                .font(.body)
                .foregroundStyle(.secondary)
            Text(feedback.encouragement)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Why it matters")
                .font(.caption.weight(.semibold))
            Text(feedback.whyItMatters)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Evidence: \(feedback.decision.evidenceLabel.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let explanation = feedback.supplementalExplanation,
               let supplementalEncouragement = feedback.supplementalEncouragement {
                Divider()
                Text("AI perspective")
                    .font(.caption.weight(.semibold))
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(supplementalEncouragement)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func auraOverallDisplay(_ score: TechniqueScore) -> String {
        guard score.overall.isFinite, (0...100).contains(score.overall) else {
            return "Not scored"
        }
        return "\(Int(score.overall.rounded())) · \(score.grade)"
    }

    private func auraMetricDisplay(_ value: Float?) -> String {
        guard let value, value.isFinite, (0...100).contains(value) else {
            return "Not tracked"
        }
        return "\(Int(value.rounded()))"
    }
}
