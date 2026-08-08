//
//  AuraPanel.swift
//  Test
//
//  Aura Punch lesson, controls, and summary presentation.
//

import SwiftUI

extension ContentView {
    var auraPunchPanel: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Technique lesson")
                    .font(.headline)

                Picker(
                    "Punch",
                    selection: Binding(
                        get: { auraPunch.selectedPunch },
                        set: { auraPunch.selectedPunch = $0 }
                    )
                ) {
                    Text("Jab").tag(PunchKind.jab)
                    Text("Cross").tag(PunchKind.cross)
                }
                .pickerStyle(.segmented)
                .disabled(appModel.immersiveSpaceState != .closed)

                HStack(spacing: 10) {
                    capabilityChip("Ghost glove", symbol: "hand.raised.fill", color: .cyan)
                    capabilityChip("Path markers", symbol: "point.topleft.down.to.point.bottomright.curvepath", color: .purple)
                    capabilityChip("3 repetitions", symbol: "repeat", color: .orange)
                }

                HStack(spacing: 10) {
                    Text("Hook — later")
                    Text("Uppercut — later")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .cardStyle()

            informationCard(
                title: "Observable coaching boundary",
                symbol: "scope",
                message: "This MVP evaluates the selected hand’s path, extension, other-hand guard, and return to guard. Pace is not rewarded. It does not measure shoulders, hips, knees, feet, force, or professional technique."
            )

            informationCard(
                title: "Learn, then react — one calibration",
                symbol: "arrow.triangle.branch",
                message: "After three guided repetitions, continue directly into the Punch Board from the in-space controls. Guard and reach stay valid because the mixed immersive session never closes."
            )

            trainingIntensityCard(for: .auraPunch)

            if let summary = auraPunch.summary {
                auraResults(summary)
            }

            safetyCard(for: .auraPunch)

            if appModel.immersiveSpaceState == .open,
               appModel.activeExperience == .auraPunch {
                trackingStatusCard
                if roundEngine.isCalibrated {
                    auraControls
                } else {
                    calibrationCard(includeRound: false)
                }
            }
        }
    }

    var auraControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(auraPhaseTitle)
                        .font(.headline)
                    Text(auraPunch.instruction)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(auraPunch.repetitionResults.count) / \(auraPunch.repetitionGoal)")
                    .font(.title3.bold().monospacedDigit())
            }

            if auraPunch.phase == .demonstrating {
                ProgressView(value: auraPunch.guideProgress) {
                    Text("Watch the translucent guide travel out and back")
                }
            }

            if let feedback = auraPunch.feedback {
                Label(feedback, systemImage: "waveform.path.ecg")
                    .foregroundStyle(.secondary)
            }

            switch auraPunch.phase {
            case .idle:
                Button("Watch Guide & Follow 3 Repetitions") {
                    guard let calibration = roundEngine.calibration,
                          handTracking.state.hasBothHands else {
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Both hands must be tracked before Aura Punch can start."
                        )
                        return
                    }
                    auraPunch.start(
                        using: calibration,
                        at: ProcessInfo.processInfo.systemUptime,
                        difficulty: trainingSettings.difficulty,
                        trackingReady: handTracking.state.hasBothHands
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!handTracking.state.hasBothHands)
                if !handTracking.state.hasBothHands {
                    Label(
                        "Return both hands to guard before starting.",
                        systemImage: "hand.raised.slash"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            case .paused:
                Button("Resume Aura Punch") {
                    auraPunch.resume(at: ProcessInfo.processInfo.systemUptime)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!handTracking.state.hasBothHands)
            case .demonstrating, .following, .completed:
                EmptyView()
            }
        }
        .cardStyle()
    }

    func auraResults(_ summary: AuraPunchSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aura Punch results")
                .font(.headline)
            metricLine("Punch", summary.punch.title)
            metricLine("Presentation level", "\(summary.difficulty.rawValue) · \(summary.difficulty.title)")
            metricLine(
                "Completed with guard return",
                "\(summary.completedRepetitions) / \(summary.repetitionGoal)"
            )
            metricLine("Overall guide score", percent(summary.averageScore))
            metricLine("Path adherence", percent(summary.averagePathScore))
            metricLine(
                "Extension control",
                percent(summary.averageExtensionScore)
            )
            metricLine(
                "Average peak extension",
                "\(Int((summary.averageExtensionRatio * 100).rounded()))% of guide"
            )
            metricLine("Other-hand guard", percent(summary.averageOtherHandGuardScore))
            if let trajectory = summary.averageTrajectoryShapeScore {
                metricLine("Trajectory shape · diagnostic", percent(trajectory))
            }
            metricLine("Tracking interruptions", "\(summary.trackingInterruptions)")
            if let lastResult = auraPunch.repetitionResults.last {
                let cue = AuraCoachingFeedback.cue(for: lastResult)
                Divider()
                Label(cue.positive, systemImage: "checkmark.circle")
                    .font(.footnote)
                Label(cue.focus, systemImage: "scope")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Trajectory shape is speed-invariant and fail-closed, but remains a hand-path diagnostic—not a full-body technique assessment.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    var auraPhaseTitle: String {
        switch auraPunch.phase {
        case .idle: "Ready for Aura Punch"
        case .demonstrating: "Watch the guide"
        case .following: "Follow the guide"
        case .paused: "Aura Punch paused"
        case .completed: "Aura Punch complete"
        }
    }
}
