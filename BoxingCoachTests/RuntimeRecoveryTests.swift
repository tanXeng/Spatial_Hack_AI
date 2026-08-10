import Foundation
import Testing
@testable import BoxingCoach

@Suite("Composed runtime recovery")
struct RuntimeRecoveryTests {
    struct Case: Sendable {
        let reason: TrackingRuntimeRejectionReason
        let expected: RuntimeRecoveryAction
    }

    @Test("Tracking failures always freeze scoring and expose one truthful action", arguments: [
        Case(reason: .authorizationDenied, expected: .reviewTrackingPermission),
        Case(reason: .authorizationRevoked, expected: .reviewTrackingPermission),
        Case(reason: .unsupported, expected: .returnToSetup),
        Case(reason: .worldTrackingUnavailable, expected: .returnToSetup),
        Case(reason: .providerStopped, expected: .retryTracking),
        Case(reason: .providerFailed(message: "failed"), expected: .retryTracking),
        Case(reason: .sessionFailed(message: "failed"), expected: .retryTracking),
    ])
    func trackingFailureContract(testCase: Case) throws {
        let presentation = try #require(RuntimeRecoveryPolicy.presentation(
            trackingState: .failed,
            trackingReason: testCase.reason,
            trackingInstruction: .retryTracking,
            audioRequiresExplicitRecovery: false,
            voiceState: .ready
        ))

        #expect(presentation.action == testCase.expected)
        #expect(presentation.freezesScoring)
        #expect(!presentation.countsAsMiss)
        #expect(presentation.retainsExitNavigation)

        switch testCase.expected {
        case .reviewTrackingPermission:
            #expect(presentation.message.contains("Settings"))
        case .returnToSetup:
            #expect(presentation.message.contains("setup"))
            #expect(!presentation.message.contains("Retry hand tracking"))
        case .retryTracking:
            #expect(presentation.message.contains("Retry"))
        case .resumeAudio, .waitForTracking, .useVisibleControls:
            break
        }
    }

    @Test("Explicit audio recovery has safety precedence")
    func audioRecoveryPrecedence() throws {
        let presentation = try #require(RuntimeRecoveryPolicy.presentation(
            trackingState: .failed,
            trackingReason: .providerStopped,
            trackingInstruction: .retryTracking,
            audioRequiresExplicitRecovery: true,
            voiceState: .denied
        ))

        #expect(presentation.action == .resumeAudio)
        #expect(presentation.title == "Audio paused")
        #expect(presentation.replacesTrainingStartAction)
    }

    @Test("Voice denial retains visible controls instead of blocking training")
    func voiceFailureFallsBackLocally() throws {
        let presentation = try #require(RuntimeRecoveryPolicy.presentation(
            trackingState: .running,
            trackingReason: nil,
            trackingInstruction: .none,
            audioRequiresExplicitRecovery: false,
            voiceState: .denied
        ))

        #expect(presentation.action == .useVisibleControls)
        #expect(!presentation.freezesScoring)
        #expect(presentation.retainsExitNavigation)
        #expect(presentation.primaryActionLabel == nil)
        #expect(!presentation.replacesTrainingStartAction)
    }

    @Test("Transient tracking loss waits without offering a destructive retry", arguments: [
        TrackingRuntimeState.degraded,
        TrackingRuntimeState.paused,
    ])
    func transientTrackingWaits(state: TrackingRuntimeState) throws {
        let presentation = try #require(RuntimeRecoveryPolicy.presentation(
            trackingState: state,
            trackingReason: .reacquiring,
            trackingInstruction: .keepHandsVisible,
            audioRequiresExplicitRecovery: false,
            voiceState: .ready
        ))

        #expect(presentation.action == .waitForTracking)
        #expect(presentation.primaryActionLabel == nil)
        #expect(presentation.freezesScoring)
        #expect(!presentation.countsAsMiss)
        #expect(!presentation.replacesTrainingStartAction)
    }

    @Test("Only actionable terminal recovery states expose one truthful label", arguments: [
        Case(reason: .authorizationDenied, expected: .reviewTrackingPermission),
        Case(reason: .unsupported, expected: .returnToSetup),
        Case(reason: .providerStopped, expected: .retryTracking),
    ])
    func terminalRecoveryLabels(testCase: Case) throws {
        let presentation = try #require(RuntimeRecoveryPolicy.presentation(
            trackingState: .failed,
            trackingReason: testCase.reason,
            trackingInstruction: .none,
            audioRequiresExplicitRecovery: false,
            voiceState: .ready
        ))

        #expect(presentation.primaryActionLabel != nil)
        #expect(presentation.replacesTrainingStartAction)
    }

    @Test("Healthy runtime has no recovery presentation")
    func healthyRuntimeHasNoRecovery() {
        #expect(RuntimeRecoveryPolicy.presentation(
            trackingState: .running,
            trackingReason: nil,
            trackingInstruction: .none,
            audioRequiresExplicitRecovery: false,
            voiceState: .ready
        ) == nil)
    }

    @Test("Interrupted voice coaching does not promise an unavailable retry")
    func interruptedVoiceUsesVisibleControls() throws {
        let presentation = try #require(RuntimeRecoveryPolicy.presentation(
            trackingState: .running,
            trackingReason: nil,
            trackingInstruction: .none,
            audioRequiresExplicitRecovery: false,
            voiceState: .interrupted
        ))

        #expect(presentation.action == .useVisibleControls)
        #expect(!presentation.message.localizedCaseInsensitiveContains("try again"))
    }

    @Test("Intentional tracking stop after a completed round does not replace results")
    func intentionalStopHasNoRecovery() {
        #expect(RuntimeRecoveryPolicy.presentation(
            trackingState: .stopped,
            trackingReason: nil,
            trackingInstruction: .none,
            audioRequiresExplicitRecovery: false,
            voiceState: .ready
        ) == nil)
    }
}
