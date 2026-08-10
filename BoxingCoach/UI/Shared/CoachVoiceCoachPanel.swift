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

            Text("Hold to ask · Wait for Listening… · Speak naturally")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            CoachVoiceCoachStatus(voiceCoach: session.voiceCoach)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Shows live-voice API status and the last PTT exchange.
struct CoachVoiceCoachStatus: View {
    let voiceCoach: CoachVoiceCoach

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(voiceCoach.hasLiveVoice ? "Live voice: on" : "Live voice: off — add API key")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(voiceCoach.hasLiveVoice ? .green : .secondary)

            if let transcript = voiceCoach.lastTranscript, !transcript.isEmpty {
                Text("You: \"\(transcript)\"")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let spoken = voiceCoach.lastSpokenText, !spoken.isEmpty {
                Text("Coach: \(spoken)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if let error = voiceCoach.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }
}
