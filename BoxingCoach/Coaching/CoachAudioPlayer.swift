import AVFoundation
import Foundation
import os

/// Plays synthesized coach speech audio. Playback-only — mic capture lives in SpeechRecognitionClient.
@MainActor
final class CoachAudioPlayer {
    private static let logger = Logger(subsystem: "com.josephkwokpersonalteam.BoxingCoach", category: "CoachAudio")
    private static let maxQueueLength = 2

    private var player: AVAudioPlayer?
    private var playbackDelegate = PlaybackDelegate()
    private var queue: [Data] = []
    private var isPlaying = false
    private var playbackReady = false
    private var interruptionObserver: NSObjectProtocol?
    private var voiceResponseContinuation: CheckedContinuation<Void, Never>?

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func prepare() {
        ensurePlaybackSession()
        registerForInterruptionsIfNeeded()
    }

    func play(data: Data) {
        if isPlaying {
            enqueue(data)
        } else {
            startPlaying(data)
        }
    }

    func playAndWait(data: Data) async {
        await withCheckedContinuation { continuation in
            voiceResponseContinuation = continuation
            if isPlaying {
                queue.removeAll()
                player?.stop()
                player = nil
                isPlaying = false
            }
            startPlaying(data)
            if !isPlaying {
                finishVoiceResponseIfNeeded()
            }
        }
    }

    func stop() {
        queue.removeAll()
        isPlaying = false
        player?.stop()
        player = nil
        finishVoiceResponseIfNeeded()
    }

    var isClipPlaying: Bool { isPlaying }

    func restorePlaybackMode() {
        playbackReady = false
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
            playbackReady = true
        } catch {
            Self.logger.error("Failed to restore playback mode: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func enqueue(_ data: Data) {
        if queue.count >= Self.maxQueueLength {
            queue.removeFirst()
        }
        queue.append(data)
    }

    private func startPlaying(_ data: Data) {
        ensurePlaybackSession()

        do {
            let next = try AVAudioPlayer(data: data)
            next.volume = 1
            next.delegate = playbackDelegate
            next.prepareToPlay()
            player = next
            isPlaying = true
            guard next.play() else {
                Self.logger.error("AVAudioPlayer.play() returned false")
                isPlaying = false
                player = nil
                finishVoiceResponseIfNeeded()
                playNextFromQueue()
                return
            }
        } catch {
            player = nil
            isPlaying = false
            Self.logger.error("Failed to play audio: \(error.localizedDescription, privacy: .public)")
            finishVoiceResponseIfNeeded()
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

    private func ensurePlaybackSession() {
        installPlaybackFinishHandler()

        let session = AVAudioSession.sharedInstance()
        let isPlaybackConfigured = session.category == .playback && session.mode == .spokenAudio
        if playbackReady, isPlaybackConfigured {
            try? session.setActive(true)
            return
        }

        do {
            if !isPlaybackConfigured {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
            playbackReady = true
        } catch {
            Self.logger.error("AVAudioSession playback setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func installPlaybackFinishHandler() {
        playbackDelegate.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.finishVoiceResponseIfNeeded()
                self.playNextFromQueue()
            }
        }
    }

    private func finishVoiceResponseIfNeeded() {
        guard let continuation = voiceResponseContinuation else { return }
        voiceResponseContinuation = nil
        continuation.resume()
    }

    private func registerForInterruptionsIfNeeded() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.didBecomeActiveNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.isPlaying {
                    self.player?.play()
                }
            }
        }
    }
}

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
