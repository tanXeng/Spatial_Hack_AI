import SwiftUI

/// Hold to capture speech; release to route and play a coach clip.
struct CoachPushToTalkButton: View {
    enum Style {
        case standard
        case compactSpatial
    }

    let isListening: Bool
    let isCaptureReady: Bool
    let isRouting: Bool
    let isGeneratingResponse: Bool
    let isDisabled: Bool
    var style: Style = .standard
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false

    private var isBusy: Bool { isRouting || isGeneratingResponse }

    private var label: String {
        if isGeneratingResponse || isRouting { return "Generating response…" }
        if isListening || isPressed {
            return isCaptureReady ? "Listening…" : "Getting ready…"
        }
        return "Hold to Ask Coach"
    }

    var body: some View {
        Group {
            switch style {
            case .standard:
                standardButton
            case .compactSpatial:
                compactButton
            }
        }
        .disabled(isDisabled || isBusy)
        .simultaneousGesture(pressGesture)
        .accessibilityLabel("Ask Coach")
        .accessibilityHint("Hold while speaking, then release to hear a coaching response")
        .accessibilityInputLabels(["Ask Coach", "Hold to Ask Coach", "Voice command"])
    }

    private var standardButton: some View {
        Button(action: {}) {
            Label(label, systemImage: micSymbol)
                .font(.body.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(buttonTint)
    }

    private var compactButton: some View {
        Button(action: {}) {
            VStack(spacing: 6) {
                Image(systemName: micSymbol)
                    .font(.title2.weight(.semibold))
                    .frame(width: 52, height: 52)
                Text(shortLabel)
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 88)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(buttonTint)
        .controlSize(.large)
    }

    private var shortLabel: String {
        if isGeneratingResponse || isRouting { return "Thinking…" }
        if isListening || isPressed {
            return isCaptureReady ? "Listening" : "Ready…"
        }
        return "Ask Coach"
    }

    private var micSymbol: String {
        isListening || isPressed || isBusy ? "mic.fill" : "mic"
    }

    private var buttonTint: Color {
        if isGeneratingResponse || isRouting { return .purple }
        if isListening || isPressed { return .orange }
        return .blue
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isDisabled, !isBusy else { return }
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
    }
}
