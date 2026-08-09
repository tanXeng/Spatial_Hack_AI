import Foundation

/// Push-to-talk voice coach: STT on device → ChatGPT clip routing → pre-recorded audio playback.
@Observable
@MainActor
final class CoachVoiceCoach {
    private(set) var isListening = false
    private(set) var isCaptureReady = false
    private(set) var isRouting = false
    private(set) var isGeneratingResponse = false
    private(set) var lastTranscript: String?
    private(set) var lastRoutedClip: CoachClipID?
    private(set) var lastError: String?

    let audioCoordinator: TrainingAudioCoordinator
    private let speechClient: any SpeechRecognizing
    private var router = CoachClipRouter()
    private var context = CoachVoiceContext.idle
    private var lastRoutedAt: Date?
    private var setupTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var permissionsGranted = false
    private var interactionGeneration: UInt64 = 0

    init(
        audioCoordinator: TrainingAudioCoordinator,
        speechClient: (any SpeechRecognizing)? = nil
    ) {
        self.audioCoordinator = audioCoordinator
        self.speechClient = speechClient ?? SpeechRecognitionClient()
        audioCoordinator.setCaptureRevocationHandler { [weak self] in
            self?.revokeCaptureLocally()
        }
    }

    func updateContext(_ context: CoachVoiceContext) {
        self.context = context
    }

    /// Request mic and speech permissions. Does not switch the audio session away from playback.
    func prepare() {
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            guard let self else { return }
            permissionsGranted = await speechClient.requestPermissions()
        }
    }

    func beginPushToTalk() {
        guard !isListening, !isRouting, !isGeneratingResponse else { return }
        lastError = nil
        isListening = true
        isCaptureReady = false
        interactionGeneration &+= 1
        let generation = interactionGeneration

        setupTask = Task { [weak self] in
            guard let self else { return }

            if !permissionsGranted {
                permissionsGranted = await speechClient.requestPermissions()
            }
            guard !Task.isCancelled,
                  generation == interactionGeneration,
                  isListening else { return }
            guard permissionsGranted else {
                self.isListening = false
                self.lastError = "Microphone or speech recognition permission denied."
                return
            }

            do {
                let captureOutcome = await audioCoordinator.handle(.voiceCaptureDidBegin)
                guard captureOutcome == .captureReady else {
                    throw VoiceCoachError.captureUnavailable
                }
                guard !Task.isCancelled,
                      generation == interactionGeneration,
                      isListening else {
                    endCoordinatorCaptureIfNeeded()
                    return
                }
                try speechClient.start()
                self.isCaptureReady = true
            } catch {
                guard generation == interactionGeneration else { return }
                if audioCoordinator.presentation.status == .capturing
                    || audioCoordinator.presentation.status == .capturePreparing {
                    audioCoordinator.handleImmediately(.voiceCaptureDidEnd)
                }
                self.isListening = false
                self.lastError = error.localizedDescription
            }
        }
    }

    func endPushToTalk() {
        guard isListening else { return }
        isListening = false
        let generation = interactionGeneration

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }

            guard !Task.isCancelled, generation == interactionGeneration else { return }
            guard isCaptureReady else {
                interactionGeneration &+= 1
                setupTask?.cancel()
                speechClient.cancel()
                lastTranscript = nil
                lastRoutedClip = .didntCatch
                lastError = "Hold the button a moment longer before speaking."
                isGeneratingResponse = true
                finishVoiceResponse(with: .didntCatch)
                isGeneratingResponse = false
                return
            }

            isCaptureReady = false
            isRouting = true

            let result = await speechClient.stop()
            guard !Task.isCancelled, generation == interactionGeneration else {
                isRouting = false
                return
            }

            isRouting = false
            isGeneratingResponse = true
            defer { isGeneratingResponse = false }

            let transcript = result.transcript

            if transcript.isEmpty {
                lastTranscript = transcript
                lastRoutedClip = .didntCatch
                finishVoiceResponse(with: .didntCatch)
                return
            }

            lastTranscript = transcript

            let clipID = await router.resolve(transcript: transcript, context: context)
            guard !Task.isCancelled, generation == interactionGeneration else {
                return
            }
            lastRoutedClip = clipID
            lastRoutedAt = Date()
            finishVoiceResponse(with: clipID)
        }
    }

    func shutdown() {
        prepareTask?.cancel()
        prepareTask = nil
        revokeCaptureLocally()
        endCoordinatorCaptureIfNeeded()
    }

    private func revokeCaptureLocally() {
        interactionGeneration &+= 1
        setupTask?.cancel()
        setupTask = nil
        processingTask?.cancel()
        processingTask = nil
        speechClient.cancel()
        isListening = false
        isRouting = false
        isGeneratingResponse = false
        isCaptureReady = false
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
