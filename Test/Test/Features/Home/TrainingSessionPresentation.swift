//
//  TrainingSessionPresentation.swift
//  Test
//
//  Shared hand-calibration, round-state, and safety presentation.
//

import SwiftUI

extension ContentView {
    var trackingStatusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: trackingSymbol)
                .font(.title2)
                .foregroundStyle(trackingColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(handTracking.state.title)
                    .font(.headline)
                Text(handTracking.state.detail)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    func calibrationCard(includeRound: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(roundEngine.phase.title)
                        .font(.headline)
                    Text(roundEngine.instruction)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if roundEngine.isRoundActive {
                    Text("\(Int(ceil(roundEngine.remainingTime)))s")
                        .font(.title2.bold().monospacedDigit())
                }
            }

            if let validation = roundEngine.validationMessage {
                Label(validation, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }

            roundPhaseControls(includeRound: includeRound)
        }
        .cardStyle()
    }

    @ViewBuilder
    private func roundPhaseControls(includeRound: Bool) -> some View {
        switch roundEngine.phase {
        case .setup:
            Button("Calibrate Guard — 2 seconds") {
                roundEngine.startGuardCalibration()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!roundEngine.canCalibrateGuard)

        case .calibratingGuard(let progress):
            ProgressView(value: progress) {
                Text("Keep both fists still in guard")
            }

        case .awaitingReach:
            functionalCalibrationReportsView

            Button("Capture Bilateral Reach — 4 repetitions") {
                roundEngine.startReachCalibration()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!roundEngine.trackingAvailable)

        case .calibratingReach(let progress):
            ProgressView(value: progress) {
                Text(
                    "Left \(roundEngine.completedReachRepetitionCount(for: .left)) / 2  •  Right \(roundEngine.completedReachRepetitionCount(for: .right)) / 2"
                )
            }

            functionalCalibrationReportsView

        case .ready:
            functionalCalibrationReportsView

            if includeRound {
                Button("Start 60-second Board Round") {
                    roundEngine.startRound(
                        difficulty: trainingSettings.difficulty
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!roundEngine.canStartRound)
            } else {
                Label("Live guard and reach are calibrated for this immersive session.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

        case .countdown(let seconds):
            Text(seconds == 0 ? "GO" : "\(seconds)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)

        case .running:
            HStack {
                if let cue = roundEngine.activeCue {
                    Label(cue.expectedPunch.title, systemImage: "scope")
                        .font(.title2.bold())
                }
                Spacer()
                if let feedback = roundEngine.feedback.text {
                    Text(feedback).fontWeight(.semibold)
                }
            }

        case .pausedForTracking:
            Label("Scoring and active time are frozen.", systemImage: "pause.circle.fill")
                .foregroundStyle(.orange)

        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)

        case .finished:
            if includeRound {
                roundResults
            }
        }
    }

    @ViewBuilder
    var functionalCalibrationReportsView: some View {
        ForEach(HandSide.allCases, id: \.self) { hand in
            if let report = roundEngine.functionalCalibrationReport(for: hand) {
                functionalCalibrationReportView(report, hand: hand)
            }
        }

        if let bilateralReach = roundEngine.conservativeBilateralProfileReachMeters {
            VStack(alignment: .leading, spacing: 3) {
                Text("Conservative bilateral profile value: \(centimeters(bilateralReach))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text("This is the minimum uncapped accepted left/right reach and the only live-reach scalar saved to the local profile. Per-hand target-placement caps remain separate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    func functionalCalibrationReportView(
        _ report: FunctionalCalibrationReport,
        hand: HandSide
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label(
                    "\(hand.rawValue.capitalized): \(report.grade.title)",
                    systemImage: report.grade.symbol
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(report.grade.color)

                Spacer()

                Text("\(report.captureCount) / \(report.requiredCaptureCount) reps")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let spread = report.absoluteSpreadMeters,
               let relativeSpread = report.relativeSpread,
               let permitted = report.permittedSpreadMeters {
                HStack(spacing: 12) {
                    Text("Spread \(centimeters(spread))")
                    Text("\(Int((relativeSpread * 100).rounded()))%")
                    Spacer()
                    Text("Limit \(centimeters(permitted))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if let captured = report.conservativeReachMeters {
                Text("Accepted live reach: \(centimeters(captured))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                if let applied = roundEngine.calibration?.targetPlacementReach(
                    for: hand
                ),
                   applied + 0.000_5 < captured {
                    Text("This hand's target placement is safety-capped at \(centimeters(applied)); the accepted session reach remains uncapped in the report.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(report.reasons, id: \.self) { reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Provisional session repeatability check; not an anatomy, clinical, or device-accuracy result.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func centimeters(_ meters: Float) -> String {
        String(format: "%.1f cm", Double(meters) * 100)
    }

    func safetyCard(for experience: ImmersiveExperience) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Mode-specific safety", systemImage: "checkmark.shield")
                .font(.headline)
            Label("Clear an arm-swing area and check floor and overhead hazards.", systemImage: "figure.boxing")
            Label("Mixed passthrough stays visible; Stop & Exit remains available.", systemImage: "vision.pro")

            switch experience {
            case .defense:
                Label("Keep both feet planted. Do not step, spin, jump, or move backward.", systemImage: "figure.stand")
                Label("Cues are slow visual prompts and dissolve before reaching the headset.", systemImage: "move.3d")
            case .bagPreview:
                Label("Preview only. Do not punch or touch a physical bag while wearing Vision Pro.", systemImage: "hand.raised.slash")
            case .anthropometryCalibration, .auraPunch, .reactiveBoard:
                Label("Stay in place. Never use a bag or partner in this mode.", systemImage: "figure.stand")
                Label("Use controlled, submaximal extensions. Do not throw full-speed or maximum-effort punches while wearing Vision Pro.", systemImage: "speedometer")
                Label("Choose one forward direction before calibration and keep facing it for the session.", systemImage: "location.north.line")
            }

            Label("The app and headset are not protective equipment.", systemImage: "shield.slash")

            Toggle(safetyAcknowledgementLabel(experience), isOn: $safetyAcknowledged)
                .disabled(appModel.immersiveSpaceState != .closed)
                .fontWeight(.semibold)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var trackingSymbol: String {
        handTracking.state.hasBothHands
            ? "hand.raised.fingers.spread.fill"
            : "hand.raised.slash"
    }

    private var trackingColor: Color {
        handTracking.state.hasBothHands ? .green : .orange
    }

    private func safetyAcknowledgementLabel(_ experience: ImmersiveExperience) -> String {
        experience == .bagPreview
            ? "I understand this is a non-contact, static preview and will not strike a real bag."
            : "I cleared the area, checked hazards, and will remain stationary with controlled, submaximal movement."
    }
}

private extension FunctionalCalibrationGrade {
    var symbol: String {
        switch self {
        case .collecting: "repeat.circle"
        case .consistent: "checkmark.circle.fill"
        case .freshCaptureNeeded: "arrow.clockwise.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .collecting: .secondary
        case .consistent: .green
        case .freshCaptureNeeded: .orange
        }
    }
}
