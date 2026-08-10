import SwiftUI

nonisolated struct CoachPushToTalkInteractionPolicy: Sendable {
    nonisolated enum Action: Equatable, Sendable {
        case beginCapture
        case endCapture
        case none
    }

    private var pointerIsDown = false
    private var holdIsActive = false
    private var suppressNextActivation = false

    mutating func pointerDidBegin() {
        // A new physical interaction cannot be the delayed Button activation from the prior hold.
        suppressNextActivation = false
        pointerIsDown = true
        holdIsActive = false
    }

    mutating func holdThresholdDidElapse(isVoiceActive: Bool) -> Action {
        guard pointerIsDown, !holdIsActive, !isVoiceActive else { return .none }
        holdIsActive = true
        return .beginCapture
    }

    mutating func pointerDidEnd(isVoiceActive: Bool) -> Action {
        pointerIsDown = false
        guard holdIsActive else { return .none }
        holdIsActive = false
        suppressNextActivation = true
        return isVoiceActive ? .endCapture : .none
    }

    mutating func accessibilityActivate(isVoiceActive: Bool) -> Action {
        if suppressNextActivation {
            suppressNextActivation = false
            return .none
        }
        guard !holdIsActive else { return .none }
        return isVoiceActive ? .endCapture : .beginCapture
    }
}

/// Tap to toggle capture, or hold while speaking and release to submit.
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
    let onToggle: () -> Void
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false
    @State private var interaction = CoachPushToTalkInteractionPolicy()
    @State private var holdTask: Task<Void, Never>?

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
        .frame(minWidth: 60, minHeight: 60)
        .contentShape(Rectangle())
        .disabled(isDisabled || isBusy)
        .simultaneousGesture(pressGesture)
        .hoverEffect(.highlight)
        .focusable()
        .accessibilityLabel("Ask Coach")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Tap to start or stop, or hold while speaking and release to hear a coaching response")
        .accessibilityInputLabels(["Ask Coach", "Hold to Ask Coach", "Voice command"])
        .accessibilityAction(named: isListening ? "Stop Listening" : "Start Listening") {
            onToggle()
        }
    }

    private var standardButton: some View {
        Button(action: activate) {
            Label(label, systemImage: micSymbol)
                .font(.body.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(buttonTint)
    }

    private var compactButton: some View {
        Button(action: activate) {
            VStack(spacing: 6) {
                Image(systemName: micSymbol)
                    .font(.title2.weight(.semibold))
                    .frame(width: 60, height: 60)
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
        if isListening || isPressed { return TrainingPalette.activeAmber }
        return .blue
    }

    private var accessibilityValue: String {
        if isGeneratingResponse || isRouting { return "Response in progress" }
        if isListening { return isCaptureReady ? "Listening" : "Preparing microphone" }
        return "Not listening"
    }

    private func activate() {
        guard !isDisabled, !isBusy else { return }
        perform(interaction.accessibilityActivate(isVoiceActive: isListening))
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isDisabled, !isBusy else { return }
                if !isPressed {
                    isPressed = true
                    interaction.pointerDidBegin()
                    holdTask?.cancel()
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, isPressed else { return }
                        perform(interaction.holdThresholdDidElapse(
                            isVoiceActive: isListening
                        ))
                    }
                }
            }
            .onEnded { _ in
                guard isPressed else { return }
                holdTask?.cancel()
                holdTask = nil
                isPressed = false
                perform(interaction.pointerDidEnd(isVoiceActive: isListening))
            }
    }

    private func perform(_ action: CoachPushToTalkInteractionPolicy.Action) {
        switch action {
        case .beginCapture: onPress()
        case .endCapture: onRelease()
        case .none: break
        }
    }
}
