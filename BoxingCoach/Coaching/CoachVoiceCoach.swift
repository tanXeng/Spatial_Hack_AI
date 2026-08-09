import Foundation

/// Push-to-talk voice coach: STT on device → ChatGPT clip routing → pre-recorded audio playback.
@Observable
@MainActor
final class CoachVoiceCoach {
    private(set) var isListening = false
    private(set) var isCaptureReady = false
    private(set) var isRouting = false
    private(set) var lastTranscript: String?
    private(set) var lastRoutedClip: CoachClipID?
    private(set) var lastError: String?

    private let audioPlayer: CoachAudioPlayer
    private let speechClient = SpeechRecognitionClient()
    private var router = CoachClipRouter()
    private var context = CoachVoiceContext.idle
    private var lastRoutedAt: Date?
    private var setupTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var permissionsGranted = false
    private var isSessionWarm = false

    init(audioPlayer: CoachAudioPlayer) {
        self.audioPlayer = audioPlayer
    }

    func updateContext(_ context: CoachVoiceContext) {
        self.context = context
    }

    /// Request permissions and pre-warm the capture audio session when immersion opens.
    func prepare() {
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            guard let self else { return }
            permissionsGranted = await speechClient.requestPermissions()
            guard permissionsGranted, !Task.isCancelled else { return }
            do {
                try audioPlayer.prepareForVoiceCapture()
                isSessionWarm = true
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func beginPushToTalk() {
        guard !isListening, !isRouting else { return }
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

            do {
                if !isSessionWarm {
                    try audioPlayer.prepareForVoiceCapture()
                    isSessionWarm = true
                }
                try speechClient.start()
                self.isCaptureReady = true
            } catch {
                self.isListening = false
                self.lastError = error.localizedDescription
            }
        }
    }

    func endPushToTalk() {
        guard isListening else { return }
        isListening = false

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }

            if !isCaptureReady, let setupTask {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await setupTask.value }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(2))
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
            }

            guard isCaptureReady else {
                lastTranscript = nil
                lastRoutedClip = .didntCatch
                lastError = "Hold the button a moment longer before speaking."
                audioPlayer.play(id: .didntCatch)
                return
            }

            isCaptureReady = false
            isRouting = true
            defer { isRouting = false }

            let result = await speechClient.stop()
            guard !Task.isCancelled else { return }

            let transcript = result.transcript

            if transcript.isEmpty {
                lastTranscript = transcript
                lastRoutedClip = .didntCatch
                audioPlayer.play(id: .didntCatch)
                return
            }

            if let previous = lastTranscript,
               let lastRoutedAt,
               Date().timeIntervalSince(lastRoutedAt) < 3,
               transcript.caseInsensitiveCompare(previous) == .orderedSame {
                lastTranscript = transcript
                return
            }

            lastTranscript = transcript

            let clipID = await router.resolve(transcript: result.transcript, context: context)
            lastRoutedClip = clipID
            lastRoutedAt = Date()
            audioPlayer.play(id: clipID)
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
        isCaptureReady = false
        isSessionWarm = false
        audioPlayer.restorePlaybackMode()
    }
}
