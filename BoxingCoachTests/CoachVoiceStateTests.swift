import Testing
@testable import BoxingCoach

@Suite("Private voice capture lifecycle")
@MainActor
struct CoachVoiceStateTests {
    @Test("First use follows consent, model preparation, capture, response, and guard recovery")
    func completeFirstUseLifecycle() throws {
        var lifecycle = CoachVoiceLifecycle()

        #expect(lifecycle.state == .off)
        #expect(lifecycle.handle(.activate(origin: .controlWindow)) == .presentPrivacyNotice)
        let setupID = try #require(lifecycle.activeCaptureID)
        #expect(lifecycle.state == .needsPermission(id: setupID, origin: .controlWindow))

        #expect(lifecycle.handle(.privacyAccepted(id: setupID)) == .requestMicrophonePermission)
        #expect(lifecycle.handle(.permissionGranted(id: setupID)) == .prepareModel)
        #expect(lifecycle.state == .preparingModel(id: setupID, origin: .controlWindow))
        #expect(lifecycle.handle(.modelPrepared(id: setupID)) == .none)
        #expect(lifecycle.state == .ready)

        #expect(lifecycle.handle(.activate(origin: .controlWindow)) == .suspendTraining)
        let captureID = try #require(lifecycle.activeCaptureID)
        #expect(lifecycle.state == .suspendingTraining(id: captureID, origin: .controlWindow))
        #expect(lifecycle.handle(.captureReady(id: captureID)) == .startRecognition)
        #expect(lifecycle.state == .listening(id: captureID, origin: .controlWindow))
        #expect(lifecycle.handle(.stopRequested(id: captureID)) == .finalizeRecognition)
        #expect(lifecycle.state == .finalizing(id: captureID, origin: .controlWindow))
        #expect(lifecycle.handle(.recognitionFinalized(id: captureID)) == .executeCommand)
        #expect(lifecycle.state == .executing(id: captureID, origin: .controlWindow))
        #expect(lifecycle.handle(.commandExecuted(id: captureID)) == .playResponse)
        #expect(lifecycle.state == .responding(id: captureID, origin: .controlWindow))
        #expect(lifecycle.handle(.responseFinished(id: captureID)) == .none)
        #expect(lifecycle.state == .awaitingGuard)
        #expect(lifecycle.handle(.guardRestored) == .none)
        #expect(lifecycle.state == .ready)
    }

    @Test("Denied permission never asks the system again")
    func denialIsStableAndNonPrompting() throws {
        var lifecycle = CoachVoiceLifecycle()
        #expect(lifecycle.handle(.activate(origin: .immersiveSpace)) == .presentPrivacyNotice)
        let captureID = try #require(lifecycle.activeCaptureID)
        #expect(lifecycle.handle(.privacyAccepted(id: captureID)) == .requestMicrophonePermission)
        #expect(lifecycle.handle(.permissionDenied(id: captureID)) == .none)
        #expect(lifecycle.state == .denied)

        #expect(lifecycle.handle(.activate(origin: .immersiveSpace)) == .showPermissionDeniedHelp)
        #expect(lifecycle.state == .denied)
    }

    @Test("Unsupported locale or model fails closed with a visible state")
    func unsupportedModelFailsClosed() throws {
        var lifecycle = CoachVoiceLifecycle()
        #expect(lifecycle.handle(.activate(origin: .controlWindow)) == .presentPrivacyNotice)
        let captureID = try #require(lifecycle.activeCaptureID)
        _ = lifecycle.handle(.privacyAccepted(id: captureID))
        _ = lifecycle.handle(.permissionGranted(id: captureID))

        #expect(lifecycle.handle(.modelUnavailable(
            id: captureID,
            reason: .unsupportedLocale
        )) == .clearPrivateState)
        #expect(lifecycle.state == .unsupported(.unsupportedLocale))
    }

    @Test("Cancellation and interruption clear private state and restore a prepared client")
    func cancellationAndInterruptionArePrivateAndRecoverable() throws {
        var lifecycle = try preparedLifecycle()
        #expect(lifecycle.handle(.activate(origin: .controlWindow)) == .suspendTraining)
        let cancelledID = try #require(lifecycle.activeCaptureID)
        _ = lifecycle.handle(.captureReady(id: cancelledID))
        #expect(lifecycle.handle(.cancel(id: cancelledID)) == .cancelAndClearPrivateState)
        #expect(lifecycle.state == .ready)

        #expect(lifecycle.handle(.activate(origin: .immersiveSpace)) == .suspendTraining)
        let interruptedID = try #require(lifecycle.activeCaptureID)
        _ = lifecycle.handle(.captureReady(id: interruptedID))
        #expect(lifecycle.handle(.interrupted(id: interruptedID)) == .cancelAndClearPrivateState)
        #expect(lifecycle.state == .interrupted)
        #expect(lifecycle.handle(.guardRestored) == .none)
        #expect(lifecycle.state == .ready)
    }

    @Test("Callbacks from an old capture cannot mutate the current capture")
    func staleCaptureIDsAreIgnored() throws {
        var lifecycle = try preparedLifecycle()
        _ = lifecycle.handle(.activate(origin: .controlWindow))
        let staleID = try #require(lifecycle.activeCaptureID)
        _ = lifecycle.handle(.cancel(id: staleID))

        _ = lifecycle.handle(.activate(origin: .controlWindow))
        let currentID = try #require(lifecycle.activeCaptureID)
        #expect(currentID != staleID)
        #expect(lifecycle.handle(.captureReady(id: staleID)) == .stale)
        #expect(lifecycle.state == .suspendingTraining(id: currentID, origin: .controlWindow))
        #expect(lifecycle.handle(.recognitionFinalized(id: staleID)) == .stale)
        #expect(lifecycle.state == .suspendingTraining(id: currentID, origin: .controlWindow))
    }

    @Test("Voice control policy exposes both input modes and a sixty point accessible target")
    func controlPresentationIsAccessible() {
        let idle = CoachVoiceControlPresentation(state: .ready, transcript: nil)
        #expect(idle.minimumHitRegion >= 60)
        #expect(idle.supportsHoldToTalk)
        #expect(idle.supportsTapToggle)
        #expect(idle.accessibilityLabel == "Ask Coach")
        #expect(idle.accessibilityValue == "Ready")
        #expect(idle.accessibilityHint.isEmpty == false)
        #expect(idle.visibleCaption.isEmpty == false)

        let listening = CoachVoiceControlPresentation(
            state: .listening(id: .init(rawValue: 42), origin: .immersiveSpace),
            transcript: "keep my guard up"
        )
        #expect(listening.accessibilityValue == "Listening")
        #expect(listening.visibleTranscript == "keep my guard up")
    }

    private func preparedLifecycle() throws -> CoachVoiceLifecycle {
        var lifecycle = CoachVoiceLifecycle()
        _ = lifecycle.handle(.activate(origin: .controlWindow))
        let setupID = try #require(lifecycle.activeCaptureID)
        _ = lifecycle.handle(.privacyAccepted(id: setupID))
        _ = lifecycle.handle(.permissionGranted(id: setupID))
        _ = lifecycle.handle(.modelPrepared(id: setupID))
        return lifecycle
    }
}
