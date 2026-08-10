import Foundation
import os

/// Push-to-talk voice coach: on-device STT → OpenAI chat answer → OpenAI TTS playback.
@Observable
@MainActor
final class CoachVoiceCoach {
    private static let logger = Logger(subsystem: "com.josephkwokpersonalteam.BoxingCoach", category: "CoachVoice")

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
        guard !isListening, !isRouting, !isGeneratingResponse else { return }
        lastError = nil
        isListening = true
        isCaptureReady = false

        setupTask = Task { [weak self] in
            guard let self else { return }

            if !permissionsGranted {
                permissionsGranted = await speechClient.requestPermissions()
            }
            guard !Task.isCancelled else { return }
            guard permissionsGranted else {
                self.isListening = false
                self.lastError = "Microphone or speech recognition permission denied."
                return
            }
            guard CoachSecrets.hasOpenAIKey else {
                self.isListening = false
                self.lastError = "OpenAI API key is missing. Add it to Secrets.xcconfig and rebuild."
                return
            }

            do {
                liveVoice.beginUserInteraction()
                try speechClient.prepareForCapture()
                try speechClient.start()
                self.isCaptureReady = true
            } catch {
                self.isListening = false
                speechClient.cancel()
                liveVoice.endUserInteraction()
                self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func endPushToTalk() {
        guard isListening else { return }
        isListening = false

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { liveVoice.endUserInteraction() }

            if !isCaptureReady, let setupTask {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await setupTask.value }
                    group.addTask { try? await Task.sleep(for: .seconds(2)) }
                    _ = await group.next()
                    group.cancelAll()
                }
            }

            isGeneratingResponse = true
            defer { isGeneratingResponse = false }

            guard isCaptureReady else {
                lastTranscript = nil
                lastSpokenText = nil
                lastError = "Hold the button until you see Listening…, then speak."
                _ = await liveVoice.speakText(
                    CoachMilestoneScripts.text(for: .didntCatch) ?? "Sorry, I didn't catch that."
                )
                return
            }

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
    }

    func shutdown() {
        prepareTask?.cancel()
        prepareTask = nil
        setupTask?.cancel()
        setupTask = nil
        processingTask?.cancel()
        processingTask = nil
        speechClient.cancel()
        isListening = false
        isRouting = false
        isGeneratingResponse = false
        isCaptureReady = false
        liveVoice.shutdown()
    }
}
