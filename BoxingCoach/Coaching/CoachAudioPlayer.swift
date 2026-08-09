import AVFoundation
import Foundation
import os

/// Plays pre-recorded coach clips from the app bundle. Clips queue and play to completion.
@MainActor
final class CoachAudioPlayer {
    private static let logger = Logger(subsystem: "com.josephkwokpersonalteam.BoxingCoach", category: "CoachAudio")
    private static let maxQueueLength = 3

    private var player: AVAudioPlayer?
    private var playbackDelegate = PlaybackDelegate()
    private var queue: [CoachClipID] = []
    private var isPlaying = false
    private var sessionConfigured = false
    private var voiceCaptureActive = false
    private var interruptionObserver: NSObjectProtocol?

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// Call as soon as the immersive space is ready — before the user starts a drill.
    /// visionOS can fail to route audio if the session is first configured after a button tap.
    func prepare() {
        configureSessionIfNeeded()
        registerForInterruptionsIfNeeded()

        if CoachClipLibrary.url(for: .welcome) == nil {
            Self.logger.error("welcome.mp3 not found in app bundle — check CoachAudio target membership")
        }
    }

    func play(id: CoachClipID) {
        if isPlaying {
            enqueue(id)
        } else {
            startPlaying(id)
        }
    }

    func play(named name: String) {
        if let id = CoachClipID(rawValue: name) {
            play(id: id)
        } else {
            Self.logger.error("Unknown coach clip id: \(name, privacy: .public)")
        }
    }

    func stop() {
        queue.removeAll()
        isPlaying = false
        player?.stop()
        player = nil
    }

    var isClipPlaying: Bool { isPlaying }

    /// Switches the audio session for push-to-talk capture while keeping coach playback available.
    func prepareForVoiceCapture() throws {
        registerForInterruptionsIfNeeded()
        playbackDelegate.onFinish = { [weak self] in
            Task { @MainActor in
                self?.playNextFromQueue()
            }
        }

        let session = AVAudioSession.sharedInstance()
        if voiceCaptureActive, session.category == .playAndRecord, session.mode == .voiceChat {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            sessionConfigured = true
            return
        }

        try session.setActive(false, options: .notifyOthersOnDeactivation)
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.mixWithOthers, .duckOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        voiceCaptureActive = true
        sessionConfigured = true
    }

    func restorePlaybackMode() {
        voiceCaptureActive = false
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
        } catch {
            Self.logger.error("Failed to restore playback mode: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func enqueue(_ id: CoachClipID) {
        if queue.last == id { return }
        if queue.count >= Self.maxQueueLength {
            queue.removeFirst()
        }
        queue.append(id)
    }

    private func startPlaying(_ id: CoachClipID) {
        guard let url = CoachClipLibrary.url(for: id) else {
            Self.logger.error("Missing coach clip in bundle: \(id.rawValue, privacy: .public).mp3")
            playNextFromQueue()
            return
        }
        configureSessionIfNeeded()

        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.volume = 1
            next.delegate = playbackDelegate
            next.prepareToPlay()
            player = next
            isPlaying = true
            guard next.play() else {
                Self.logger.error("AVAudioPlayer.play() returned false for \(id.rawValue, privacy: .public)")
                isPlaying = false
                player = nil
                playNextFromQueue()
                return
            }
        } catch {
            player = nil
            isPlaying = false
            Self.logger.error("Failed to play \(id.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            playNextFromQueue()
        }
    }

    private func playNextFromQueue() {
        isPlaying = false
        player = nil
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        startPlaying(next)
    }

    private func configureSessionIfNeeded() {
        guard !sessionConfigured else { return }
        sessionConfigured = true

        playbackDelegate.onFinish = { [weak self] in
            Task { @MainActor in
                self?.playNextFromQueue()
            }
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
        } catch {
            Self.logger.error("AVAudioSession setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func registerForInterruptionsIfNeeded() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                self.handleInterruption(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue),
            type == .ended
        else { return }

        try? AVAudioSession.sharedInstance().setActive(true)
        if isPlaying {
            player?.play()
        }
    }
}

// MARK: - AVAudioPlayerDelegate

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
