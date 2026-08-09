import SwiftUI

/// Hold to capture speech; release to route and play a coach clip.
struct CoachPushToTalkButton: View {
    let isListening: Bool
    let isCaptureReady: Bool
    let isRouting: Bool
    let isDisabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false

    private var label: String {
        if isRouting { return "Thinking…" }
        if isListening || isPressed {
            return isCaptureReady ? "Listening…" : "Getting ready…"
        }
        return "Hold to Ask Coach"
    }

    var body: some View {
        Button(action: {}) {
            Label(label, systemImage: isListening || isPressed ? "mic.fill" : "mic")
                .font(.body.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(isListening || isPressed ? .orange : .blue)
        .disabled(isDisabled || isRouting)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isDisabled, !isRouting else { return }
                    if !isPressed {
                        isPressed = true
                        onPress()
                    }
                }
                .onEnded { _ in
                    guard isPressed else { return }
                    isPressed = false
                    onRelease()
                }
        )
        .accessibilityLabel("Ask Coach")
        .accessibilityHint("Hold while speaking, then release to hear a coaching response")
        .accessibilityInputLabels(["Ask Coach", "Hold to Ask Coach", "Voice command"])
    }
}
