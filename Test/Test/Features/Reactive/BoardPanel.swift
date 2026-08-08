//
//  BoardPanel.swift
//  Test
//
//  Virtual punch-board setup and result presentation.
//

import SwiftUI

extension ContentView {
    var virtualBoardPanel: some View {
        VStack(spacing: 16) {
            informationCard(
                title: "Six-pad virtual board",
                symbol: "circle.grid.2x2.fill",
                message: "One pad lights at a time. Jab/cross labels supplement color, and logical cue timing remains the scoring truth."
            )

            trainingIntensityCard(for: .reactiveBoard)

            if roundEngine.phase == .finished {
                roundResults
            }

            safetyCard(for: .reactiveBoard)

            if appModel.immersiveSpaceState == .open,
               appModel.activeExperience == .reactiveBoard {
                trackingStatusCard
                calibrationCard(includeRound: true)
            }
        }
    }

    var roundResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = roundEngine.summary {
                Text("Punch Board results")
                    .font(.headline)
                metricLine("Presentation level", "\(summary.difficulty.rawValue) · \(summary.difficulty.title)")
                metricLine("Hit rate", percent(summary.hitRate))
                metricLine("Hits / attempts", "\(summary.hits) / \(summary.completedAttempts)")
                metricLine("Spatial misses", "\(summary.spatialMisses)")
                metricLine("Timeouts", "\(summary.timeouts)")
                metricLine("Wrong hand", "\(summary.wrongPunches)")
                metricLine("Tracking interruptions", "\(summary.trackingInterruptions)")
                metricLine("Average hit response", milliseconds(summary.averageResponseTime))
                metricLine("Guard return", optionalPercent(summary.guardReturnConsistency))
                metricLine("Guard return not observed", "\(summary.guardReturnsCensored)")
                Text("Hit, response, and guard feedback only — pace is not rewarded and this is not force, power, protection, or a medical measurement.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }
}
