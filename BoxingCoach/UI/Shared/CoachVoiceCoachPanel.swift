import SwiftUI

/// Window-level push-to-talk coach for home, setup, and results screens.
struct CoachVoiceCoachPanel: View {
    @Environment(ReactiveStrikeSession.self) private var session
    @AccessibilityFocusState private var focusedControl: TrainingAccessibilityFocusDestination?

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
                onToggle: {
                    session.voiceCoach.toggleCapture(origin: .controlWindow)
                },
                onPress: {
                    session.beginCoachPushToTalk(origin: .controlWindow)
                },
                onRelease: { session.endCoachPushToTalk() }
            )
            .accessibilityFocused($focusedControl, equals: voiceControlFocusDestination)

            if requiresRecovery {
                TrainingAudioRecoveryButton {
                    session.resumeAudio()
                }
            }

            Text(session.voiceCoach.controlPresentation.visibleCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    "Ask Coach status: \(session.voiceCoach.controlPresentation.visibleCaption)"
                )

            if let transcript = session.voiceCoach.controlPresentation.visibleTranscript,
               !transcript.isEmpty {
                Text("You said: \(transcript)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Voice transcript: \(transcript)")
            }

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
        .confirmationDialog(
            "Private voice capture",
            isPresented: privacyNoticeBinding,
            titleVisibility: .visible
        ) {
            Button("Continue") { session.voiceCoach.acceptPrivacyNotice() }
            Button("Not Now", role: .cancel) { session.voiceCoach.declinePrivacyNotice() }
        } message: {
            Text("Your voice is transcribed on this device and is never saved.")
        }
        .onChange(of: session.voiceCoach.state) { oldState, newState in
            if let destination = TrainingAccessibility.focusAfterVoiceTransition(
                from: oldState,
                to: newState
            ) {
                focusedControl = destination
            }
        }
    }

    private var voiceControlFocusDestination: TrainingAccessibilityFocusDestination {
        session.voiceCoach.state == .denied ? .permissionRecovery : .askCoach
    }

    private var privacyNoticeBinding: Binding<Bool> {
        Binding(
            get: {
                if case .needsPermission = session.voiceCoach.state { true } else { false }
            },
            set: { isPresented in
                if !isPresented, case .needsPermission = session.voiceCoach.state {
                    session.voiceCoach.declinePrivacyNotice()
                }
            }
        )
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
