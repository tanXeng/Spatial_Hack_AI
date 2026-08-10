import Foundation
import os

/// Push-to-talk voice coach: on-device STT → OpenAI chat answer → OpenAI TTS playback.
@Observable
@MainActor
final class CoachVoiceCoach {
    private static let logger = Logger(subsystem: "com.josephkwokpersonalteam.BoxingCoach", category: "CoachVoice")
    private static let captureSetupTimeout: Duration = .seconds(4)

    private(set) var isListening = false
    private(set) var isCaptureReady = false
    private(set) var isRouting = false
    private(set) var isGeneratingResponse = false
    private(set) var lastTranscript: String?
    private(set) var lastSpokenText: String?
    private(set) var lastError: String?

    var hasLiveVoice: Bool { CoachSecrets.hasOpenAIKey }

    private let liveVoice: CoachLiveVoiceService
    private let speechClient = SpeechRecognitionClient()
    private var chatClient = OpenAICoachChatClient()
    private var context = CoachVoiceContext.idle
    private var setupTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var permissionsGranted = false
    private var setupGeneration = 0

    init(liveVoice: CoachLiveVoiceService) {
        self.liveVoice = liveVoice
    }

    func updateContext(_ context: CoachVoiceContext) {
        self.context = context
    }

    /// Request permissions when immersion opens. Voice capture session is configured
    /// on-demand in beginPushToTalk to avoid interrupting background music playback.
    func prepare() {
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            guard let self else { return }
            permissionsGranted = await speechClient.requestPermissions()
        }
    }

    func beginPushToTalk() {
        guard !isRouting, !isGeneratingResponse else { return }

        if isListening, !isCaptureReady {
            cancelActiveCapture()
        }
        guard !isListening else { return }

        setupTask?.cancel()
        setupTask = nil
        lastError = nil

        setupGeneration += 1
        let generation = setupGeneration
        isListening = true
        isCaptureReady = false

        setupTask = Task { [weak self] in
            await self?.runCaptureSetup(generation: generation)
        }
    }

    func endPushToTalk() {
        setupTask?.cancel()
        setupTask = nil

        let wasReady = isCaptureReady
        let hadBegunCapture = isListening || isCaptureReady
        isListening = false

        guard hadBegunCapture else { return }

        if !wasReady {
            invalidateCaptureSetup()
            return
        }

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            await self?.processCapturedSpeech()
        }
    }

    func cancelActiveCapture() {
        setupTask?.cancel()
        setupTask = nil
        processingTask?.cancel()
        processingTask = nil
        invalidateCaptureSetup()
    }

    func shutdown() {
        prepareTask?.cancel()
        prepareTask = nil
        cancelActiveCapture()
        speechClient.cancel()
        isRouting = false
        isGeneratingResponse = false
        liveVoice.shutdown()
    }

    // MARK: - Capture setup

    private func runCaptureSetup(generation: Int) async {
        guard isListening, generation == setupGeneration else { return }

        if !permissionsGranted {
            permissionsGranted = await speechClient.requestPermissions()
        }
        guard isListening, generation == setupGeneration else { return }

        guard permissionsGranted else {
            failCaptureSetup(
                generation: generation,
                message: "Microphone or speech recognition permission denied."
            )
            return
        }
        guard CoachSecrets.hasOpenAIKey else {
            failCaptureSetup(
                generation: generation,
                message: "OpenAI API key is missing. Add it to Secrets.xcconfig and rebuild."
            )
            return
        }

        let setupResult: Result<Void, Error> = await withTaskGroup(of: Result<Void, Error>.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return .failure(CaptureSetupError.cancelled) }
                do {
                    liveVoice.beginUserInteraction()
                    try speechClient.prepareForCapture()
                    guard isListening, generation == setupGeneration else {
                        throw CaptureSetupError.cancelled
                    }
                    try speechClient.start()
                    guard isListening, generation == setupGeneration else {
                        throw CaptureSetupError.cancelled
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.captureSetupTimeout)
                return .failure(CaptureSetupError.timedOut)
            }

            let first = await group.next() ?? .failure(CaptureSetupError.cancelled)
            group.cancelAll()
            return first
        }

        guard isListening, generation == setupGeneration else {
            if case .failure(CaptureSetupError.cancelled) = setupResult {
                return
            }
            invalidateCaptureSetup()
            return
        }

        switch setupResult {
        case .success:
            isCaptureReady = true
        case .failure(let error as CaptureSetupError):
            switch error {
            case .cancelled:
                invalidateCaptureSetup()
            case .timedOut:
                failCaptureSetup(
                    generation: generation,
                    message: "Microphone took too long to start. Release and try again."
                )
            }
        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            failCaptureSetup(generation: generation, message: message)
        }
    }

    private func failCaptureSetup(generation: Int, message: String) {
        guard generation == setupGeneration else { return }
        lastError = message
        invalidateCaptureSetup()
    }

    private func invalidateCaptureSetup() {
        setupGeneration += 1
        isListening = false
        isCaptureReady = false
        speechClient.cancel()
        liveVoice.endUserInteraction()
    }

    // MARK: - Processing

    private func processCapturedSpeech() async {
        defer {
            speechClient.restorePlaybackSession()
            liveVoice.endUserInteraction()
        }

        isGeneratingResponse = true
        defer { isGeneratingResponse = false }

        isCaptureReady = false
        isRouting = true
        let result = await speechClient.stop()
        guard !Task.isCancelled else {
            isRouting = false
            return
        }
        isRouting = false

        let transcript = result.transcript
        lastTranscript = transcript

        if transcript.isEmpty {
            lastSpokenText = nil
            lastError = "No speech detected."
            _ = await liveVoice.speakText(
                CoachMilestoneScripts.text(for: .didntCatch) ?? "Sorry, I didn't catch that."
            )
            return
        }

        do {
            let answer = try await chatClient.answer(transcript: transcript, context: context)
            lastSpokenText = answer
            lastError = await liveVoice.speakText(answer)
            if let lastError {
                Self.logger.error("PTT playback failed: \(lastError, privacy: .public)")
            }
        } catch {
            lastSpokenText = nil
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = message
            Self.logger.error("Chat answer failed: \(message, privacy: .public)")
            _ = await liveVoice.speakText("Sorry, I couldn't get an answer. \(message)")
        }
    }

    private enum CaptureSetupError: Error {
        case cancelled
        case timedOut
    }
}
