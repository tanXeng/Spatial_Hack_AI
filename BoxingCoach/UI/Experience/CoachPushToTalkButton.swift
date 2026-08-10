import SwiftUI

/// Hold to capture speech; release to ask ChatGPT and hear a live TTS reply.
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
    private var isEngaged: Bool { isListening || isPressed }

    private var label: String {
        if isGeneratingResponse || isRouting { return "Generating response…" }
        if isEngaged {
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
        .onChange(of: isListening) { _, listening in
            if !listening, !isBusy {
                isPressed = false
            }
        }
        .onChange(of: isBusy) { _, busy in
            if !busy, !isListening {
                isPressed = false
            }
        }
        .accessibilityLabel("Ask Coach")
        .accessibilityHint("Hold while speaking, then release to hear a ChatGPT answer")
        .accessibilityInputLabels(["Ask Coach", "Hold to Ask Coach", "Voice command"])
    }

    private var standardButton: some View {
        Label(label, systemImage: micSymbol)
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(buttonTint.opacity(0.2), in: Capsule())
            .overlay(Capsule().stroke(buttonTint, lineWidth: 1.5))
            .foregroundStyle(buttonTint)
            .contentShape(Capsule())
            .modifier(PressAndHoldModifier(isDisabled: isDisabled || isBusy, onPress: handlePress, onRelease: handleRelease))
    }

    private var compactButton: some View {
        VStack(spacing: 6) {
            Image(systemName: micSymbol)
                .font(.title2.weight(.semibold))
                .frame(width: 52, height: 52)
            Text(shortLabel)
                .font(.caption2.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 88)
        }
        .padding(8)
        .background(buttonTint.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(buttonTint, lineWidth: 1.5))
        .foregroundStyle(buttonTint)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .modifier(PressAndHoldModifier(isDisabled: isDisabled || isBusy, onPress: handlePress, onRelease: handleRelease))
    }

    private var shortLabel: String {
        if isGeneratingResponse || isRouting { return "Thinking…" }
        if isEngaged {
            return isCaptureReady ? "Listening" : "Ready…"
        }
        return "Ask Coach"
    }

    private var micSymbol: String {
        isEngaged || isBusy ? "mic.fill" : "mic"
    }

    private var buttonTint: Color {
        if isGeneratingResponse || isRouting { return .purple }
        if isEngaged { return .orange }
        return .blue
    }

    private func handlePress() {
        guard !isPressed else { return }
        isPressed = true
        onPress()
    }

    private func handleRelease() {
        guard isPressed else { return }
        isPressed = false
        onRelease()
    }
}

/// Reliable press-and-hold for visionOS window and spatial attachments.
private struct PressAndHoldModifier: ViewModifier {
    let isDisabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isHolding = false

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { _ in
                        guard !isDisabled else { return }
                        if !isHolding {
                            isHolding = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        guard isHolding else { return }
                        isHolding = false
                        onRelease()
                    }
            )
    }
}
