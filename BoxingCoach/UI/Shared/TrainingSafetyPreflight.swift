import SwiftUI

nonisolated struct TrainingSafetyPreflightPresentation: Equatable, Sendable {
    let stage: String
    let message: String
    let primaryActionLabel: String

    var primaryActionCount: Int { 1 }
}

nonisolated enum TrainingSafetyPreflightPolicy {
    static let safetyMessage = "Clear people and objects beyond arm’s reach, stay aware through passthrough, and stop anytime you feel uncomfortable."

    static func presentation(for selection: TrainingSelection) -> TrainingSafetyPreflightPresentation {
        let actionLabel: String
        switch selection {
        case .aura:
            actionLabel = "Start Rep"
        case .reactive:
            actionLabel = "Start Drill"
        case .reachCalibration, .competitionCalibration:
            actionLabel = "Start Calibration"
        case .competition:
            actionLabel = "Start Ranked Round"
        }

        return TrainingSafetyPreflightPresentation(
            stage: "SAFETY CHECK",
            message: safetyMessage,
            primaryActionLabel: actionLabel
        )
    }
}

struct TrainingSafetyPreflightCard: View {
    let message: String

    init(message: String = TrainingSafetyPreflightPolicy.safetyMessage) {
        self.message = message
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clear your training space")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "figure.mind.and.body")
                .foregroundStyle(TrainingPalette.activeAmber)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Safety check")
        .accessibilityValue(message)
    }
}
