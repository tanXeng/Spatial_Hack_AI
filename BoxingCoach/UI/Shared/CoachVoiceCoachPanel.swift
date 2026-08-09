import SwiftUI

/// Window-level push-to-talk coach for home, setup, and results screens.
struct CoachVoiceCoachPanel: View {
    @Environment(ReactiveStrikeSession.self) private var session

    let isDisabled: Bool

    var body: some View {
        let requiresRecovery = session.audioCoordinator.presentation.requiresExplicitRecovery

        VStack(alignment: .leading, spacing: 8) {
            CoachPushToTalkButton(
                isListening: session.voiceCoach.isListening,
                isCaptureReady: session.voiceCoach.isCaptureReady,
                isRouting: session.voiceCoach.isRouting,
                isGeneratingResponse: session.voiceCoach.isGeneratingResponse,
                isDisabled: isDisabled || requiresRecovery,
                onPress: {
                    session.beginCoachPushToTalk(origin: .controlWindow)
                },
                onRelease: { session.endCoachPushToTalk() }
            )

            if requiresRecovery {
                TrainingAudioRecoveryButton {
                    session.resumeAudio()
                }
            }

            Text("Hold to ask · Try \"help\" or \"what should I fix?\"")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let caption = session.audioCoordinator.presentation.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Coach caption: \(caption)")
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TrainingAudioRecoveryButton: View {
    let action: () -> Void

    var body: some View {
        Button("Resume Audio", systemImage: "speaker.wave.2.fill", action: action)
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Resume Audio")
            .accessibilityHint(
                "Restores training audio after an interruption or audio route change"
            )
    }
}
