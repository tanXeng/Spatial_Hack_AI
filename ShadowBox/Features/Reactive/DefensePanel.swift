//
//  DefensePanel.swift
//  Test
//
//  Head-movement defense setup, controls, and result presentation.
//

import SwiftUI

extension ContentView {
    var defensePanel: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Head-movement drill")
                    .font(.headline)
                Picker(
                    "Pattern",
                    selection: Binding(
                        get: { defense.selectedDrill },
                        set: { defense.selectDrill($0) }
                    )
                ) {
                    ForEach(DefenseDrill.allCases, id: \.self) { drill in
                        Text(drill.title).tag(drill)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(appModel.immersiveSpaceState != .closed)

                Text("Vision Pro device position is used only as a head-motion proxy. Feet, hips, knees, balance, and professional dodge technique are not scored.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .cardStyle()

            trainingIntensityCard(for: .defense)

            if let summary = defense.summary {
                defenseResults(summary)
            }

            safetyCard(for: .defense)

            if appModel.immersiveSpaceState == .open,
               appModel.activeExperience == .defense {
                deviceTrackingCard
                defenseControls
            }
        }
    }

    var defenseControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(defensePhaseTitle)
                        .font(.headline)
                    Text(defense.instruction)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(defense.attempts.count) / \(DefenseEngine.cueGoal)")
                    .font(.title3.bold().monospacedDigit())
            }

            if case .calibratingNeutral(let progress) = defense.phase {
                ProgressView(value: progress) {
                    Text("Hold your head comfortably still")
                }
            }

            if case .countdown(let seconds) = defense.phase {
                Text(seconds == 0 ? "GO" : "\(seconds)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
            }

            if let text = defense.feedback.text {
                Label(text, systemImage: "move.3d")
                    .foregroundStyle(.secondary)
            }

            switch defense.phase {
            case .idle:
                Button("Calibrate Neutral Head Position") {
                    defense.beginNeutralCalibration(
                        at: defenseTimelineTimestamp
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!handTracking.isHeadTrackingReady)
            case .ready:
                Button("Start 6-Cue Defense Set") {
                    defense.start(
                        at: defenseTimelineTimestamp,
                        difficulty: trainingSettings.difficulty
                    )
                }
                .buttonStyle(.borderedProminent)
            case .paused:
                Button("Resume at Neutral") {
                    defense.resume(at: defenseTimelineTimestamp)
                }
                .buttonStyle(.borderedProminent)
            case .calibratingNeutral, .countdown, .active, .completed:
                EmptyView()
            }
        }
        .cardStyle()
    }

    var deviceTrackingCard: some View {
        HStack(spacing: 12) {
            Image(systemName: handTracking.latestDevicePose == nil ? "viewfinder.circle" : "viewfinder.circle.fill")
                .font(.title2)
                .foregroundStyle(deviceTrackingColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(deviceTrackingTitle)
                    .font(.headline)
                Text(deviceTrackingDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    func defenseResults(_ summary: DefenseSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Defense results")
                .font(.headline)
            metricLine("Scope", summary.metricScopeLabel)
            metricLine("Presentation level", "\(summary.difficulty.rawValue) · \(summary.difficulty.title)")
            metricLine("Completed head motions", "\(summary.successfulAvoidances) / \(summary.completedAttempts)")
            metricLine("Wrong direction", "\(summary.wrongDirections)")
            metricLine("Late neutral return", "\(summary.missedReturns)")
            metricLine("Timeouts", "\(summary.timeouts)")
            metricLine("Cancelled cues", "\(summary.cancelledCues)")
            metricLine(
                "Tracking/system interruptions",
                "\(summary.trackingInterruptions)"
            )
            metricLine(
                "Safety-range pauses",
                "\(summary.safetyBoundaryInterruptions)"
            )
            metricLine(
                "Average successful response",
                milliseconds(summary.averageSuccessfulResponseTime)
            )
            Text("No footwork, hip, leg, balance, force, or medical metric is inferred.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    var defensePhaseTitle: String {
        switch defense.phase {
        case .idle: "Calibrate neutral"
        case .calibratingNeutral: "Calibrating head position"
        case .ready: "Defense set ready"
        case .countdown: "Get ready"
        case .active: defense.currentCue?.expectedMovement.title ?? "Stay neutral"
        case .paused: "Defense paused"
        case .completed: "Defense set complete"
        }
    }

    var defenseTimelineTimestamp: TimeInterval {
        handTracking.latestDevicePose?.capturedAt
            ?? ProcessInfo.processInfo.systemUptime
    }

    private var deviceTrackingTitle: String {
        if DeveloperConfig.isOfflineModeEnabled,
           let _ = handTracking.latestDevicePose {
            return "Offline head-tracking simulation active"
        }
        switch handTracking.state {
        case .simulatorUnavailable, .worldTrackingUnavailable, .worldTrackingLost, .failed:
            return handTracking.state.title
        default:
            return handTracking.latestDevicePose == nil
                ? "Waiting for device position"
                : "Head proxy available"
        }
    }

    private var deviceTrackingDetail: String {
        if DeveloperConfig.isOfflineModeEnabled,
           let _ = handTracking.latestDevicePose {
            return "Head position is generated locally for local defense testing."
        }
        switch handTracking.state {
        case .simulatorUnavailable, .worldTrackingUnavailable, .worldTrackingLost, .failed:
            return handTracking.state.detail
        default:
            return "Processed device position remains in memory for this session only."
        }
    }

    private var deviceTrackingColor: Color {
        switch handTracking.state {
        case .worldTrackingUnavailable, .failed:
            .red
        default:
            handTracking.isHeadTrackingReady ? .green : .orange
        }
    }
}
