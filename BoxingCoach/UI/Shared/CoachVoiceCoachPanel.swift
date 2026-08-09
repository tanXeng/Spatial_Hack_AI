import SwiftUI

/// Window-level push-to-talk coach for home, setup, and results screens.
struct CoachVoiceCoachPanel: View {
    @Environment(ReactiveStrikeSession.self) private var session

    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoachPushToTalkButton(
                isListening: session.voiceCoach.isListening,
                isCaptureReady: session.voiceCoach.isCaptureReady,
                isRouting: session.voiceCoach.isRouting,
                isGeneratingResponse: session.voiceCoach.isGeneratingResponse,
                isDisabled: isDisabled,
                onPress: { session.voiceCoach.beginPushToTalk() },
                onRelease: { session.voiceCoach.endPushToTalk() }
            )

            Text("Hold to ask · Try \"help\" or \"what should I fix?\"")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
