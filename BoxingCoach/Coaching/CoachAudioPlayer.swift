import AVFoundation
import Foundation
import os

/// Plays synthesized coach speech audio. Playback-only — mic capture lives in SpeechRecognitionClient.
@MainActor
final class CoachAudioPlayer {
    private static let logger = Logger(subsystem: "com.josephkwokpersonalteam.BoxingCoach", category: "CoachAudio")
    private static let maxQueueLength = 2
    /// OpenAI TTS MP3s run quiet when mixed with workout music — boost decoded samples before playback.
    private static let playbackGain: Float = 1.45

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
            let playbackData = try Self.amplifiedPlaybackData(from: data, gain: Self.playbackGain)
            let next = try AVAudioPlayer(data: playbackData)
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
        do {
            // Mix with background music instead of deactivating the session, which would cut it off.
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

    private static func amplifiedPlaybackData(from data: Data, gain: Float) throws -> Data {
        guard gain > 1.001 else { return data }

        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try data.write(to: inputURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let file = try AVAudioFile(forReading: inputURL)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return data
        }
        try file.read(into: buffer)

        guard let channels = buffer.floatChannelData else { return data }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        for channel in 0..<channelCount {
            for frame in 0..<frames {
                channels[channel][frame] = max(-1, min(1, channels[channel][frame] * gain))
            }
        }

        return try wavData(from: buffer)
    }

    private static func wavData(from buffer: AVAudioPCMBuffer) throws -> Data {
        guard let floatData = buffer.floatChannelData else {
            throw CoachAudioError.cannotAmplify
        }

        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let sampleRate = Int(buffer.format.sampleRate)
        var int16Data = Data(capacity: frameCount * channels * 2)

        for frame in 0..<frameCount {
            for channel in 0..<channels {
                let sample = max(-1, min(1, floatData[channel][frame]))
                var intSample = Int16(sample * 32767).littleEndian
                withUnsafeBytes(of: &intSample) { int16Data.append(contentsOf: $0) }
            }
        }

        let blockAlign = channels * 2
        let byteRate = sampleRate * blockAlign
        let dataSize = int16Data.count
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        var fileSize = UInt32(36 + dataSize).littleEndian
        withUnsafeBytes(of: &fileSize) { header.append(contentsOf: $0) }
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        var fmtSize = UInt32(16).littleEndian
        withUnsafeBytes(of: &fmtSize) { header.append(contentsOf: $0) }
        var audioFormat = UInt16(1).littleEndian
        withUnsafeBytes(of: &audioFormat) { header.append(contentsOf: $0) }
        var channelCount = UInt16(channels).littleEndian
        withUnsafeBytes(of: &channelCount) { header.append(contentsOf: $0) }
        var sampleRateLE = UInt32(sampleRate).littleEndian
        withUnsafeBytes(of: &sampleRateLE) { header.append(contentsOf: $0) }
        var byteRateLE = UInt32(byteRate).littleEndian
        withUnsafeBytes(of: &byteRateLE) { header.append(contentsOf: $0) }
        var blockAlignLE = UInt16(blockAlign).littleEndian
        withUnsafeBytes(of: &blockAlignLE) { header.append(contentsOf: $0) }
        var bitsPerSample = UInt16(16).littleEndian
        withUnsafeBytes(of: &bitsPerSample) { header.append(contentsOf: $0) }
        header.append("data".data(using: .ascii)!)
        var dataSizeLE = UInt32(dataSize).littleEndian
        withUnsafeBytes(of: &dataSizeLE) { header.append(contentsOf: $0) }
        header.append(int16Data)
        return header
    }

    private enum CoachAudioError: Error {
        case cannotAmplify
    }
}

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
