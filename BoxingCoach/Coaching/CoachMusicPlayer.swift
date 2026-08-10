import AVFoundation
import Foundation
import os

@MainActor
final class CoachMusicPlayer {
    private static let logger = Logger(
        subsystem: "com.josephkwokpersonalteam.BoxingCoach", category: "CoachMusic"
    )

    private var player: AVAudioPlayer?
    private var queuePlayer: AVQueuePlayer?
    private var allTrackURLs: [URL] = []
    private var currentTrackIndex = 0
    private var interruptionObserver: NSObjectProtocol?
    private var playbackObserver: Any?
    private var usingBundledTracks = false

    private(set) var isPlaying = false
    private(set) var currentTrackName: String?

    var hasMultipleTracks: Bool { usingBundledTracks && allTrackURLs.count > 1 }

    var volume: Float {
        get { player?.volume ?? queuePlayer?.volume ?? 0 }
        set {
            let v = max(0, min(1, newValue))
            player?.volume = v
            queuePlayer?.volume = v
        }
    }

    init() {
        allTrackURLs = discoverBundledTracks()
    }

    func prepare() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        if !allTrackURLs.isEmpty {
            usingBundledTracks = true
            currentTrackIndex = 0
            playTrack(at: 0, autoplay: false)
        } else {
            prepareSynthesizedBeat()
        }
    }

    func play() {
        if player == nil, queuePlayer == nil {
            prepare()
        }
        if usingBundledTracks {
            queuePlayer?.play()
        } else {
            player?.play()
        }
        isPlaying = true
        Self.logger.debug("Music playing")
    }

    func pause() {
        isPlaying = false
        if usingBundledTracks {
            queuePlayer?.pause()
        } else {
            player?.pause()
        }
        Self.logger.debug("Music paused")
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func skip() {
        guard usingBundledTracks, !allTrackURLs.isEmpty else { return }
        currentTrackIndex = (currentTrackIndex + 1) % allTrackURLs.count
        playTrack(at: currentTrackIndex, autoplay: isPlaying)
    }

    func previous() {
        guard usingBundledTracks, !allTrackURLs.isEmpty else { return }
        currentTrackIndex = currentTrackIndex > 0 ? currentTrackIndex - 1 : allTrackURLs.count - 1
        playTrack(at: currentTrackIndex, autoplay: isPlaying)
    }

    func stop() {
        isPlaying = false
        if let observer = playbackObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackObserver = nil
        }
        player?.stop()
        player?.currentTime = 0
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        Self.logger.debug("Music stopped")
    }

    func shutdown() {
        stop()
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        player = nil
        queuePlayer = nil
    }

    private func playTrack(at index: Int, autoplay: Bool) {
        guard usingBundledTracks, index < allTrackURLs.count else { return }

        if let observer = playbackObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()

        let url = allTrackURLs[index]
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer(items: [item])
        player.volume = 0.4
        queuePlayer = player

        currentTrackName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized

        playbackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.currentTrackIndex = (self.currentTrackIndex + 1) % self.allTrackURLs.count
                self.playTrack(at: self.currentTrackIndex, autoplay: true)
            }
        }

        if autoplay {
            player.play()
        }
        Self.logger.debug("Playing track \(index): \(self.currentTrackName ?? "?")")
    }

    // MARK: - Interruptions

    private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        if type == .ended, isPlaying {
            if usingBundledTracks {
                queuePlayer?.play()
            } else {
                player?.play()
            }
            Self.logger.debug("Music resumed after interruption")
        }
    }

    // MARK: - Bundled tracks

    private static let coachClipNames: Set<String> = [
        "back_to_guard", "countdown", "didnt_catch", "follow_out", "guard_up",
        "help_commands", "hit_target", "match_extension", "pause_ack", "qa_hit_target",
        "qa_repeat_demo", "qa_slower", "qa_three_punches", "qa_what_fix", "qa_why_guard",
        "rep_faster", "results_good", "results_needs_work", "resume_ack", "return_in",
        "scoring", "welcome", "calibrate_reach", "extend_other_arm", "reach_calibrated"
    ]

    private func discoverBundledTracks() -> [URL] {
        let dirs: [String?] = ["WorkoutMusic", "Resources/WorkoutMusic", nil]
        for dir in dirs {
            let files = mp3Files(in: dir)
            let music = files.filter {
                !Self.coachClipNames.contains($0.deletingPathExtension().lastPathComponent)
            }
            if !music.isEmpty {
                Self.logger.debug("Found \(music.count) music track(s) in \(dir ?? "bundle root")")
                return music.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            }
        }
        return []
    }

    private func mp3Files(in subdirectory: String?) -> [URL] {
        let url: URL?
        if let sub = subdirectory {
            url = Bundle.main.resourceURL?.appendingPathComponent(sub)
        } else {
            url = Bundle.main.resourceURL
        }
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        else { return [] }
        return contents.filter {
            let e = $0.pathExtension; return e == "mp3" || e == "m4a" || e == "wav"
        }
    }

    // MARK: - Synthesized beat

    private func prepareSynthesizedBeat() {
        usingBundledTracks = false
        guard let url = renderBeatToTempFile() else {
            Self.logger.error("Failed to render beat")
            return
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.4
        player?.numberOfLoops = -1
        player?.prepareToPlay()
        currentTrackName = nil
        Self.logger.debug("Synthesized beat ready")
    }

    private func tempBeatURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("boxing_beat.wav")
    }

    private func renderBeatToTempFile() -> URL? {
        let sampleRate: Double = 44100
        let tempo: Double = 130
        let bars = 4
        let beatsPerBar = 4
        let totalBeats = bars * beatsPerBar
        let beatDuration = 60.0 / tempo
        let totalDuration = Double(totalBeats) * beatDuration
        let totalFrames = AVAudioFrameCount(totalDuration * sampleRate)
        let channels: AVAudioChannelCount = 2

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            return nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            return nil
        }
        buffer.frameLength = totalFrames
        guard let data = buffer.floatChannelData else { return nil }

        let kick = generateKickSamples(sampleRate: sampleRate)
        let snare = generateSnareSamples(sampleRate: sampleRate)
        let hihatClosed = generateHihatClosedSamples(sampleRate: sampleRate)
        let hihatOpen = generateHihatOpenSamples(sampleRate: sampleRate)

        for beat in 0..<totalBeats {
            let beatStart = Int(Double(beat) * beatDuration * sampleRate)
            let halfBeat = Int(beatDuration * 0.5 * sampleRate)
            switch beat % beatsPerBar {
            case 0:
                mix(into: data, channels: channels, at: beatStart, samples: kick, gain: 0.85)
                mix(into: data, channels: channels, at: beatStart, samples: hihatClosed, gain: 0.25)
                mix(into: data, channels: channels, at: beatStart + halfBeat, samples: hihatClosed, gain: 0.22)
            case 1:
                mix(into: data, channels: channels, at: beatStart, samples: snare, gain: 0.75)
                mix(into: data, channels: channels, at: beatStart, samples: hihatClosed, gain: 0.25)
                mix(into: data, channels: channels, at: beatStart + halfBeat, samples: hihatClosed, gain: 0.22)
            case 2:
                mix(into: data, channels: channels, at: beatStart, samples: kick, gain: 0.80)
                mix(into: data, channels: channels, at: beatStart, samples: hihatClosed, gain: 0.25)
                mix(into: data, channels: channels, at: beatStart + halfBeat, samples: hihatOpen, gain: 0.18)
            case 3:
                mix(into: data, channels: channels, at: beatStart, samples: snare, gain: 0.70)
                mix(into: data, channels: channels, at: beatStart, samples: hihatClosed, gain: 0.25)
                mix(into: data, channels: channels, at: beatStart + halfBeat, samples: hihatClosed, gain: 0.22)
            default: break
            }
        }
        let url = tempBeatURL()
        return writeWAV(buffer: buffer, url: url) ? url : nil
    }

    private func mix(into data: UnsafePointer<UnsafeMutablePointer<Float>>,
                     channels: AVAudioChannelCount, at startFrame: Int,
                     samples: [Float], gain: Float) {
        for i in 0..<samples.count {
            let idx = startFrame + i
            if idx < Int.max {
                for ch in 0..<Int(channels) { data[ch][idx] += samples[i] * gain }
            }
        }
    }

    private func generateKickSamples(sampleRate: Double) -> [Float] {
        let duration: Double = 0.22
        let count = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let envelope = exp(-t * 18.0)
            let pitchEnv = exp(-t * 30.0)
            let freq = 60.0 * pitchEnv + 35.0
            let body = sin(2.0 * .pi * freq * t)
            let click = sin(2.0 * .pi * 180.0 * t) * exp(-t * 200.0) * 0.3
            out[i] = Float((Double(body) * 0.9 + Double(click)) * envelope)
        }
        return out
    }

    private func generateSnareSamples(sampleRate: Double) -> [Float] {
        let duration: Double = 0.16
        let count = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let envelope = exp(-t * 25.0)
            let noise = Float.random(in: -1...1) * 0.7
            let tone1 = sin(2.0 * .pi * 220.0 * t) * 0.3
            let tone2 = sin(2.0 * .pi * 180.0 * t) * 0.2
            let click = sin(2.0 * .pi * 1500.0 * t) * exp(-t * 300.0) * 0.25
            out[i] = Float((Double(noise) + Double(tone1) + Double(tone2) + Double(click)) * envelope * 0.55)
        }
        return out
    }

    private func generateHihatClosedSamples(sampleRate: Double) -> [Float] {
        let duration: Double = 0.05
        let count = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let envelope = exp(-t * 80.0)
            let noise = Float.random(in: -0.7...0.7)
            let high = sin(2.0 * .pi * 6000.0 * t) * 0.25
            let mid = sin(2.0 * .pi * 3000.0 * t) * 0.15
            out[i] = Float((Double(noise) + Double(high) + Double(mid)) * envelope)
        }
        return out
    }

    private func generateHihatOpenSamples(sampleRate: Double) -> [Float] {
        let duration: Double = 0.30
        let count = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let envelope = exp(-t * 8.0)
            let noise = Float.random(in: -0.5...0.5)
            let high = sin(2.0 * .pi * 7000.0 * t) * 0.15
            out[i] = Float((Double(noise) + Double(high)) * envelope * 0.7)
        }
        return out
    }

    private func writeWAV(buffer: AVAudioPCMBuffer, url: URL) -> Bool {
        guard let floatData = buffer.floatChannelData else { return false }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let sampleRate = Int(buffer.format.sampleRate)
        var int16Data = Data(capacity: frameCount * channels * 2)
        for frame in 0..<frameCount {
            for ch in 0..<channels {
                var sample = max(-1, min(1, floatData[ch][frame]))
                let intSample = Int16(sample * 32767)
                var little = intSample.littleEndian
                withUnsafeBytes(of: &little) { int16Data.append(contentsOf: $0) }
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
        var chCount = UInt16(channels).littleEndian
        withUnsafeBytes(of: &chCount) { header.append(contentsOf: $0) }
        var sr = UInt32(sampleRate).littleEndian
        withUnsafeBytes(of: &sr) { header.append(contentsOf: $0) }
        var br = UInt32(byteRate).littleEndian
        withUnsafeBytes(of: &br) { header.append(contentsOf: $0) }
        var ba = UInt16(blockAlign).littleEndian
        withUnsafeBytes(of: &ba) { header.append(contentsOf: $0) }
        var bps = UInt16(16).littleEndian
        withUnsafeBytes(of: &bps) { header.append(contentsOf: $0) }
        header.append("data".data(using: .ascii)!)
        var ds = UInt32(dataSize).littleEndian
        withUnsafeBytes(of: &ds) { header.append(contentsOf: $0) }
        header.append(int16Data)
        do {
            try? FileManager.default.removeItem(at: url)
            try header.write(to: url)
            return true
        } catch {
            Self.logger.error("Failed WAV: \(error.localizedDescription)")
            return false
        }
    }
}