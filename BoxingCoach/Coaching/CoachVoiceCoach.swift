import Foundation

nonisolated struct CoachVoiceCaptureID: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

nonisolated enum CoachVoiceModelUnavailableReason: Equatable, Sendable {
    case unsupportedLocale
    case unavailableModel
}

nonisolated enum CoachVoiceLifecycleState: Equatable, Sendable {
    case off
    case needsPermission(id: CoachVoiceCaptureID, origin: TrainingAudioSceneOwner)
    case preparingModel(id: CoachVoiceCaptureID, origin: TrainingAudioSceneOwner)
    case ready
    case suspendingTraining(id: CoachVoiceCaptureID, origin: TrainingAudioSceneOwner)
    case listening(id: CoachVoiceCaptureID, origin: TrainingAudioSceneOwner)
    case finalizing(id: CoachVoiceCaptureID, origin: TrainingAudioSceneOwner)
    case executing(id: CoachVoiceCaptureID, origin: TrainingAudioSceneOwner)
    case responding(id: CoachVoiceCaptureID, origin: TrainingAudioSceneOwner)
    case awaitingGuard
    case denied
    case unsupported(CoachVoiceModelUnavailableReason)
    case interrupted
}

nonisolated enum CoachVoiceLifecycleEvent: Equatable, Sendable {
    case activate(origin: TrainingAudioSceneOwner)
    case privacyAccepted(id: CoachVoiceCaptureID)
    case permissionGranted(id: CoachVoiceCaptureID)
    case permissionDenied(id: CoachVoiceCaptureID)
    case modelPrepared(id: CoachVoiceCaptureID)
    case modelUnavailable(id: CoachVoiceCaptureID, reason: CoachVoiceModelUnavailableReason)
    case captureReady(id: CoachVoiceCaptureID)
    case stopRequested(id: CoachVoiceCaptureID)
    case recognitionFinalized(id: CoachVoiceCaptureID)
    case commandExecuted(id: CoachVoiceCaptureID)
    case responseFinished(id: CoachVoiceCaptureID)
    case cancel(id: CoachVoiceCaptureID)
    case interrupted(id: CoachVoiceCaptureID)
    case guardRestored
}

nonisolated enum CoachVoiceLifecycleEffect: Equatable, Sendable {
    case none
    case stale
    case presentPrivacyNotice
    case requestMicrophonePermission
    case prepareModel
    case suspendTraining
    case startRecognition
    case finalizeRecognition
    case executeCommand
    case playResponse
    case showPermissionDeniedHelp
    case clearPrivateState
    case cancelAndClearPrivateState
}

nonisolated struct CoachVoiceLifecycle: Sendable {
    private(set) var state: CoachVoiceLifecycleState = .off
    private(set) var activeCaptureID: CoachVoiceCaptureID?
    private var nextCaptureID: UInt64 = 0
    private var modelIsPrepared = false

    mutating func handle(_ event: CoachVoiceLifecycleEvent) -> CoachVoiceLifecycleEffect {
        switch event {
        case let .activate(origin):
            switch state {
            case .off:
                let id = makeCaptureID()
                state = .needsPermission(id: id, origin: origin)
                return .presentPrivacyNotice
            case .ready:
                let id = makeCaptureID()
                state = .suspendingTraining(id: id, origin: origin)
                return .suspendTraining
            case .denied:
                return .showPermissionDeniedHelp
            default:
                return .none
            }

        case let .privacyAccepted(id):
            guard case let .needsPermission(activeID, _) = state, activeID == id else {
                return .stale
            }
            return .requestMicrophonePermission

        case let .permissionGranted(id):
            guard case let .needsPermission(activeID, origin) = state, activeID == id else {
                return .stale
            }
            state = .preparingModel(id: id, origin: origin)
            return .prepareModel

        case let .permissionDenied(id):
            guard activeCaptureID == id else { return .stale }
            activeCaptureID = nil
            state = .denied
            return .none

        case let .modelPrepared(id):
            guard case let .preparingModel(activeID, _) = state, activeID == id else {
                return .stale
            }
            activeCaptureID = nil
            modelIsPrepared = true
            state = .ready
            return .none

        case let .modelUnavailable(id, reason):
            guard activeCaptureID == id else { return .stale }
            activeCaptureID = nil
            modelIsPrepared = false
            state = .unsupported(reason)
            return .clearPrivateState

        case let .captureReady(id):
            guard case let .suspendingTraining(activeID, origin) = state, activeID == id else {
                return .stale
            }
            state = .listening(id: id, origin: origin)
            return .startRecognition

        case let .stopRequested(id):
            guard case let .listening(activeID, origin) = state, activeID == id else {
                return .stale
            }
            state = .finalizing(id: id, origin: origin)
            return .finalizeRecognition

        case let .recognitionFinalized(id):
            guard case let .finalizing(activeID, origin) = state, activeID == id else {
                return .stale
            }
            state = .executing(id: id, origin: origin)
            return .executeCommand

        case let .commandExecuted(id):
            guard case let .executing(activeID, origin) = state, activeID == id else {
                return .stale
            }
            state = .responding(id: id, origin: origin)
            return .playResponse

        case let .responseFinished(id):
            guard case let .responding(activeID, _) = state, activeID == id else {
                return .stale
            }
            activeCaptureID = nil
            state = .awaitingGuard
            return .none

        case let .cancel(id):
            guard activeCaptureID == id else { return .stale }
            activeCaptureID = nil
            state = modelIsPrepared ? .ready : .off
            return .cancelAndClearPrivateState

        case let .interrupted(id):
            guard activeCaptureID == id else { return .stale }
            activeCaptureID = nil
            state = .interrupted
            return .cancelAndClearPrivateState

        case .guardRestored:
            guard state == .awaitingGuard || state == .interrupted else { return .none }
            state = modelIsPrepared ? .ready : .off
            return .none
        }
    }

    private mutating func makeCaptureID() -> CoachVoiceCaptureID {
        nextCaptureID &+= 1
        let id = CoachVoiceCaptureID(rawValue: nextCaptureID)
        activeCaptureID = id
        return id
    }
}

nonisolated struct CoachVoiceControlPresentation: Equatable, Sendable {
    let minimumHitRegion: Double = 60
    let supportsHoldToTalk = true
    let supportsTapToggle = true
    let accessibilityLabel = "Ask Coach"
    let accessibilityValue: String
    let accessibilityHint = "Tap to start or stop listening, or hold while speaking and release"
    let visibleCaption: String
    let visibleTranscript: String?

    init(state: CoachVoiceLifecycleState, transcript: String?) {
        visibleTranscript = transcript
        switch state {
        case .off:
            accessibilityValue = "Off"
            visibleCaption = "Ask Coach is off"
        case .needsPermission:
            accessibilityValue = "Permission required"
            visibleCaption = "Review private voice capture"
        case .preparingModel:
            accessibilityValue = "Preparing on-device model"
            visibleCaption = "Preparing private speech model…"
        case .ready:
            accessibilityValue = "Ready"
            visibleCaption = "Tap or hold to ask the coach"
        case .suspendingTraining:
            accessibilityValue = "Getting ready"
            visibleCaption = "Pausing training audio…"
        case .listening:
            accessibilityValue = "Listening"
            visibleCaption = "Listening on device…"
        case .finalizing:
            accessibilityValue = "Finalizing"
            visibleCaption = "Finishing transcript…"
        case .executing:
            accessibilityValue = "Executing"
            visibleCaption = "Applying command…"
        case .responding:
            accessibilityValue = "Responding"
            visibleCaption = "Coach is responding…"
        case .awaitingGuard:
            accessibilityValue = "Waiting for guard"
            visibleCaption = "Return both hands to guard"
        case .denied:
            accessibilityValue = "Microphone denied"
            visibleCaption = "Enable Microphone in Settings to use Ask Coach"
        case .unsupported:
            accessibilityValue = "Unavailable"
            visibleCaption = "On-device speech is unavailable for this language"
        case .interrupted:
            accessibilityValue = "Interrupted"
            visibleCaption = "Voice capture stopped. Return to guard"
        }
    }
}

/// Push-to-talk voice coach: STT on device → ChatGPT clip routing → pre-recorded audio playback.
@Observable
@MainActor
final class CoachVoiceCoach {
    private(set) var state: CoachVoiceLifecycleState = .off
    private(set) var lastTranscript: String?
    private(set) var lastRoutedClip: CoachClipID?
    private(set) var lastError: String?

    var isListening: Bool {
        switch state {
        case .suspendingTraining, .listening, .finalizing: true
        default: false
        }
    }

    var isCaptureReady: Bool {
        if case .listening = state { true } else { false }
    }

    var isRouting: Bool {
        if case .executing = state { true } else { false }
    }

    var isGeneratingResponse: Bool {
        if case .responding = state { true } else { false }
    }

    var controlPresentation: CoachVoiceControlPresentation {
        CoachVoiceControlPresentation(state: state, transcript: lastTranscript)
    }

    let audioCoordinator: TrainingAudioCoordinator
    private let speechClient: any SpeechRecognizing
    private var router = CoachClipRouter()
    private var context = CoachVoiceContext.idle
    private var lastRoutedAt: Date?
    private var setupTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var lifecycle = CoachVoiceLifecycle()
    private var trainingPauseEventIDs: [CoachVoiceCaptureID: UUID] = [:]
    var onCaptureCycleEvent: ((CoachVoiceCyclePauseOwner.Event) -> Void)?

    init(
        audioCoordinator: TrainingAudioCoordinator,
        speechClient: (any SpeechRecognizing)? = nil
    ) {
        self.audioCoordinator = audioCoordinator
        self.speechClient = speechClient ?? SpeechRecognitionClient()
        audioCoordinator.setCaptureRevocationHandler { [weak self] in
            self?.revokeCaptureLocally(interrupted: true)
        }
        self.speechClient.setTranscriptUpdateHandler { [weak self] transcript in
            guard let self, case .listening = self.state else { return }
            self.lastTranscript = transcript
        }
    }

    func updateContext(_ context: CoachVoiceContext) {
        if self.context != context {
            clearPrivateSessionState()
        }
        self.context = context
    }

    @discardableResult
    func beginPushToTalk(origin: TrainingAudioSceneOwner = .controlWindow) -> Bool {
        guard !isListening, !isRouting, !isGeneratingResponse else { return false }
        if state == .interrupted || state == .awaitingGuard,
           !audioCoordinator.presentation.requiresExplicitRecovery {
            _ = reduce(.guardRestored)
        }
        lastError = nil
        switch reduce(.activate(origin: origin)) {
        case .suspendTraining:
            guard let captureID = lifecycle.activeCaptureID else { return false }
            suspendTrainingAndStartCapture(id: captureID, origin: origin)
            return true
        case .showPermissionDeniedHelp:
            lastError = "Microphone access was denied. Enable Microphone in Settings to use Ask Coach."
            return false
        case .presentPrivacyNotice, .none:
            return true
        default:
            return false
        }
    }

    func toggleCapture(origin: TrainingAudioSceneOwner) {
        if isListening {
            endPushToTalk()
        } else {
            _ = beginPushToTalk(origin: origin)
        }
    }

    func acceptPrivacyNotice() {
        guard case let .needsPermission(id, origin) = state,
              reduce(.privacyAccepted(id: id)) == .requestMicrophonePermission else { return }

        setupTask?.cancel()
        setupTask = Task { [weak self] in
            guard let self else { return }
            let granted = await speechClient.requestPermissions()
            guard !Task.isCancelled, lifecycle.activeCaptureID == id else { return }
            guard granted else {
                _ = reduce(.permissionDenied(id: id))
                lastError = "Microphone access was denied. Enable Microphone in Settings to use Ask Coach."
                clearPrivateState()
                return
            }

            guard reduce(.permissionGranted(id: id)) == .prepareModel else { return }
            do {
                try await speechClient.prepareModel()
                guard !Task.isCancelled,
                      reduce(.modelPrepared(id: id)) != .stale else { return }
                beginPushToTalk(origin: origin)
            } catch {
                let reason: CoachVoiceModelUnavailableReason =
                    error as? SpeechRecognitionClient.SpeechError == .unsupportedLocale
                        ? .unsupportedLocale
                        : .unavailableModel
                _ = reduce(.modelUnavailable(id: id, reason: reason))
                lastError = error.localizedDescription
                clearPrivateState()
            }
        }
    }

    func declinePrivacyNotice() {
        guard let id = lifecycle.activeCaptureID else { return }
        _ = reduce(.cancel(id: id))
        clearPrivateState()
    }

    func endPushToTalk() {
        guard let captureID = lifecycle.activeCaptureID else { return }
        if case .suspendingTraining = state {
            _ = reduce(.cancel(id: captureID))
            finishTrainingPause(for: captureID, completed: false)
            setupTask?.cancel()
            speechClient.cancel()
            endCoordinatorCaptureIfNeeded()
            clearPrivateState()
            lastRoutedClip = .didntCatch
            lastError = "Hold the button a moment longer before speaking."
            return
        }
        guard reduce(.stopRequested(id: captureID)) == .finalizeRecognition else { return }
        releaseTrainingPause(for: captureID)

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            let result = await speechClient.stop()
            guard !Task.isCancelled,
                  reduce(.recognitionFinalized(id: captureID)) == .executeCommand else { return }

            let transcript = result.transcript

            if transcript.isEmpty {
                lastTranscript = transcript
                lastRoutedClip = .didntCatch
                _ = reduce(.commandExecuted(id: captureID))
                finishVoiceResponse(with: .didntCatch)
                completeResponse(id: captureID)
                return
            }

            lastTranscript = transcript

            let clipID = await router.resolve(transcript: transcript, context: context)
            guard !Task.isCancelled, lifecycle.activeCaptureID == captureID else {
                return
            }
            lastRoutedClip = clipID
            lastRoutedAt = Date()
            _ = reduce(.commandExecuted(id: captureID))
            finishVoiceResponse(with: clipID)
            completeResponse(id: captureID)
        }
    }

    func shutdown() {
        revokeCaptureLocally(interrupted: false)
        endCoordinatorCaptureIfNeeded()
        lifecycle = CoachVoiceLifecycle()
        state = .off
    }

    /// Clears ephemeral capture data at a route or participant handoff without making an
    /// accepted privacy notice appear again or discarding a prepared on-device model.
    func clearPrivateSessionState() {
        revokeCaptureLocally(interrupted: false)
        endCoordinatorCaptureIfNeeded()
        lastTranscript = nil
        lastRoutedClip = nil
        lastError = nil
        lastRoutedAt = nil
        context = .idle
        router = CoachClipRouter()
    }

    private func revokeCaptureLocally(interrupted: Bool) {
        if let captureID = lifecycle.activeCaptureID {
            _ = reduce(interrupted ? .interrupted(id: captureID) : .cancel(id: captureID))
            finishTrainingPause(for: captureID, completed: false)
        }
        setupTask?.cancel()
        setupTask = nil
        processingTask?.cancel()
        processingTask = nil
        speechClient.cancel()
        clearPrivateState()
    }

    private func suspendTrainingAndStartCapture(
        id: CoachVoiceCaptureID,
        origin: TrainingAudioSceneOwner
    ) {
        lastTranscript = nil
        beginTrainingPause(for: id)
        setupTask?.cancel()
        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = await audioCoordinator.handle(.voiceCaptureDidBegin(origin: origin))
                guard outcome == .captureReady else { throw VoiceCoachError.captureUnavailable }
                guard !Task.isCancelled,
                      reduce(.captureReady(id: id)) == .startRecognition else {
                    endCoordinatorCaptureIfNeeded()
                    return
                }
                try speechClient.start()
            } catch {
                guard lifecycle.activeCaptureID == id else { return }
                _ = reduce(.cancel(id: id))
                finishTrainingPause(for: id, completed: false)
                endCoordinatorCaptureIfNeeded()
                clearPrivateState()
                lastError = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func reduce(_ event: CoachVoiceLifecycleEvent) -> CoachVoiceLifecycleEffect {
        let effect = lifecycle.handle(event)
        state = lifecycle.state
        return effect
    }

    private func clearPrivateState() {
        lastTranscript = nil
        speechClient.setTranscriptUpdateHandler { [weak self] transcript in
            guard let self, case .listening = self.state else { return }
            self.lastTranscript = transcript
        }
    }

    private func completeResponse(id: CoachVoiceCaptureID) {
        _ = reduce(.responseFinished(id: id))
        clearPrivateState()
        finishTrainingPause(for: id, completed: true)
    }

    func confirmGuardRestored() {
        _ = reduce(.guardRestored)
    }

    private func beginTrainingPause(for id: CoachVoiceCaptureID) {
        let eventID = UUID()
        trainingPauseEventIDs[id] = eventID
        onCaptureCycleEvent?(.captureBegan(eventID))
    }

    private func releaseTrainingPause(for id: CoachVoiceCaptureID) {
        guard let eventID = trainingPauseEventIDs[id] else { return }
        onCaptureCycleEvent?(.captureReleased(eventID))
    }

    private func finishTrainingPause(for id: CoachVoiceCaptureID, completed: Bool) {
        guard let eventID = trainingPauseEventIDs.removeValue(forKey: id) else { return }
        onCaptureCycleEvent?(
            completed ? .responseCompleted(eventID) : .responseCancelled(eventID)
        )
    }

    private func endCoordinatorCaptureIfNeeded() {
        if audioCoordinator.presentation.status == .capturing
            || audioCoordinator.presentation.status == .capturePreparing {
            audioCoordinator.handleImmediately(.voiceCaptureDidEnd)
        }
    }

    private func finishVoiceResponse(with clip: CoachClipID) {
        let captureNeedsEnding = audioCoordinator.presentation.status == .capturing
            || audioCoordinator.presentation.status == .capturePreparing
        audioCoordinator.handleImmediately(.coachCue(TrainingCoachCue(
            kind: .voiceResponse,
            clip: clip,
            caption: Self.caption(for: clip)
        )))
        if captureNeedsEnding {
            audioCoordinator.handleImmediately(.voiceCaptureDidEnd)
        }
    }

    private static func caption(for clip: CoachClipID) -> String {
        switch clip {
        case .qaWhatFix:
            "Focus on the correction shown in your result."
        case .qaWhyGuard:
            "Keep your guard close so you stay protected and ready to return."
        case .qaHitTarget:
            "Return to guard, then strike through the visible target."
        case .qaThreePunches:
            "Complete all three clean punches before reviewing the result."
        case .helpCommands:
            "Ask what to fix, why guard matters, how to hit the target, or your progress."
        case .didntCatch:
            "I didn't catch that. Hold the button and try again."
        default:
            "Coach response."
        }
    }

    private enum VoiceCoachError: LocalizedError {
        case captureUnavailable

        var errorDescription: String? {
            "Microphone audio is unavailable. Use the visible controls."
        }
    }

}
