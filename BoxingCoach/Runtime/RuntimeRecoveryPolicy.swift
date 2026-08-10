import Foundation

/// The one recovery action the control window should offer for the highest-priority runtime fault.
nonisolated enum RuntimeRecoveryAction: Equatable, Sendable {
    case resumeAudio
    case reviewTrackingPermission
    case retryTracking
    case returnToSetup
    case waitForTracking
    case useVisibleControls
}

/// A composed, privacy-safe recovery state shared by the control window and immersive UI.
nonisolated struct RuntimeRecoveryPresentation: Equatable, Sendable {
    let title: String
    let message: String
    let action: RuntimeRecoveryAction
    let freezesScoring: Bool
    let countsAsMiss: Bool
    let retainsExitNavigation: Bool

    var primaryActionLabel: String? {
        switch action {
        case .resumeAudio:
            "Resume Audio"
        case .reviewTrackingPermission, .retryTracking:
            "Retry Tracking"
        case .returnToSetup:
            "Return to Setup"
        case .waitForTracking, .useVisibleControls:
            nil
        }
    }

    var replacesTrainingStartAction: Bool {
        switch action {
        case .resumeAudio, .reviewTrackingPermission, .retryTracking, .returnToSetup:
            true
        case .waitForTracking, .useVisibleControls:
            false
        }
    }
}

/// Resolves simultaneous tracking, audio, and voice failures to one deterministic presentation.
nonisolated enum RuntimeRecoveryPolicy {
    static func presentation(
        trackingState: TrackingRuntimeState,
        trackingReason: TrackingRuntimeRejectionReason?,
        trackingInstruction: TrackingRecoveryInstruction,
        audioRequiresExplicitRecovery: Bool,
        voiceState: CoachVoiceLifecycleState
    ) -> RuntimeRecoveryPresentation? {
        if audioRequiresExplicitRecovery {
            return RuntimeRecoveryPresentation(
                title: "Audio paused",
                message: "Resume audio before continuing. Scoring remains frozen.",
                action: .resumeAudio,
                freezesScoring: true,
                countsAsMiss: false,
                retainsExitNavigation: true
            )
        }

        if let tracking = trackingPresentation(
            state: trackingState,
            reason: trackingReason,
            instruction: trackingInstruction
        ) {
            return tracking
        }

        switch voiceState {
        case .denied:
            return voiceFallback(
                message: "Microphone access is off. Use the visible training controls."
            )
        case .unsupported:
            return voiceFallback(
                message: "On-device speech is unavailable. Use the visible training controls."
            )
        case .interrupted:
            return voiceFallback(
                message: "Ask Coach was interrupted. Use the visible training controls to continue."
            )
        default:
            return nil
        }
    }

    private static func trackingPresentation(
        state: TrackingRuntimeState,
        reason: TrackingRuntimeRejectionReason?,
        instruction: TrackingRecoveryInstruction
    ) -> RuntimeRecoveryPresentation? {
        let action: RuntimeRecoveryAction
        let title: String

        switch reason {
        case .authorizationDenied, .authorizationRevoked:
            action = .reviewTrackingPermission
            title = "Hand tracking permission needed"
        case .unsupported, .worldTrackingUnavailable:
            action = .returnToSetup
            title = "Tracking unavailable"
        case .providerStopped, .providerFailed, .sessionFailed:
            action = .retryTracking
            title = "Tracking stopped"
        case .providerPaused, .reacquiring, .anchorRemoved, .untracked,
             .missingSkeleton, .missingRequiredJoint, .missingDevicePose,
             .nonFiniteSample, .invalidTimestamp, .nonMonotonicSample,
             .staleSample, .sampleGap:
            action = .waitForTracking
            title = "Tracking paused"
        case nil:
            switch state {
            case .degraded, .paused:
                action = .waitForTracking
                title = "Tracking paused"
            case .failed:
                action = .retryTracking
                title = "Tracking stopped"
            case .stopped:
                return nil
            default:
                return nil
            }
        }

        let fallbackMessage: String
        switch action {
        case .reviewTrackingPermission:
            fallbackMessage = "Allow hand tracking in Settings, then retry."
        case .returnToSetup:
            fallbackMessage = "Return to setup and choose another experience."
        case .retryTracking:
            fallbackMessage = "Retry hand tracking when you are ready."
        case .waitForTracking:
            fallbackMessage = "Keep both hands visible while tracking stabilizes."
        case .resumeAudio, .useVisibleControls:
            fallbackMessage = ""
        }

        let compatibleInstruction: String?
        switch (action, instruction) {
        case (.reviewTrackingPermission, .reviewAuthorization),
             (.retryTracking, .retryTracking),
             (.waitForTracking, .keepHandsVisible),
             (.waitForTracking, .waitForProvider):
            compatibleInstruction = instruction.rawValue
        default:
            compatibleInstruction = nil
        }

        return RuntimeRecoveryPresentation(
            title: title,
            message: compatibleInstruction ?? fallbackMessage,
            action: action,
            freezesScoring: true,
            countsAsMiss: false,
            retainsExitNavigation: true
        )
    }

    private static func voiceFallback(message: String) -> RuntimeRecoveryPresentation {
        RuntimeRecoveryPresentation(
            title: "Visible controls available",
            message: message,
            action: .useVisibleControls,
            freezesScoring: false,
            countsAsMiss: false,
            retainsExitNavigation: true
        )
    }
}

/// Tracking-only recovery projected into the immersive controls. Audio owns its dedicated
/// Resume Audio control, and voice failures retain the visible controls without a blocking card.
nonisolated enum ImmersiveRuntimeRecoveryPolicy {
    static func presentation(
        trackingState: TrackingRuntimeState,
        trackingReason: TrackingRuntimeRejectionReason?,
        trackingInstruction: TrackingRecoveryInstruction,
        audioRequiresExplicitRecovery: Bool
    ) -> RuntimeRecoveryPresentation? {
        guard !audioRequiresExplicitRecovery else { return nil }
        return RuntimeRecoveryPolicy.presentation(
            trackingState: trackingState,
            trackingReason: trackingReason,
            trackingInstruction: trackingInstruction,
            audioRequiresExplicitRecovery: audioRequiresExplicitRecovery,
            voiceState: .ready
        )
    }
}
