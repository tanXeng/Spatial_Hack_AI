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
    private var queueLooper: AVPlayerLooper?
    private var interruptionObserver: NSObjectProtocol?

    private var usingBundledTracks = false
    private var bundledTrackURLs: [URL] = []

    private(set) var isActive = false {
        didSet { Self.logger.debug("Music active: \(self.isActive)") }
    }

    var volume: Float {
        get { player?.volume ?? queuePlayer?.volume ?? 0 }
        set {
            let v = max(0, min(1, newValue))
            player?.volume = v
            queuePlayer?.volume = v
        }
    }

    init() {
        bundledTrackURLs = discoverBundledTracks()
    }

    func prepare() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        if !bundledTrackURLs.isEmpty {
            prepareBundledTracks()
        } else {
            prepareSynthesizedBeat()
        }
    }

    func start() {
        guard !isActive else { return }

        if player == nil, queuePlayer == nil {
            prepare()
        }

        if usingBundledTracks {
            queuePlayer?.play()
        } else {
            player?.play()
        }

        isActive = true
        Self.logger.debug("Music started")
    }

    func stop() {
        isActive = false
        player?.stop()
        player?.currentTime = 0
        queuePlayer?.pause()
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
        queueLooper = nil
    }

    private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        if type == .ended {
            guard let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume), isActive {
                if usingBundledTracks {
                    queuePlayer?.play()
                } else {
                    player?.play()
                }
                Self.logger.debug("Music resumed after interruption")
            }
        }
    }

    // MARK: - Bundled tracks

    private func discoverBundledTracks() -> [URL] {
        let dirs = ["WorkoutMusic", "Resources/WorkoutMusic"]
        for dir in dirs {
            if let url = Bundle.main.resourceURL?.appendingPathComponent(dir),
               FileManager.default.fileExists(atPath: url.path) {
                if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    let tracks = contents.filter { $0.pathExtension == "mp3" || $0.pathExtension == "m4a" || $0.pathExtension == "wav" }
                    if !tracks.isEmpty {
                        Self.logger.debug("Found \(tracks.count) bundled music track(s)")
                        return tracks.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                    }
                }
            }
        }
        return []
    }

    private func prepareBundledTracks() {
        usingBundledTracks = true
        let items = bundledTrackURLs.map { AVPlayerItem(url: $0) }
        let player = AVQueuePlayer(items: items)
        player.volume = 0.4
        queueLooper = AVPlayerLooper(player: player, templateItem: items[0])
        queuePlayer = player
        Self.logger.debug("Bundled music player ready")
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
            default:
                break
            }
        }

        let url = tempBeatURL()
        return writeWAV(buffer: buffer, url: url) ? url : nil
    }

    private func mix(into data: UnsafePointer<UnsafeMutablePointer<Float>>,
                     channels: AVAudioChannelCount,
                     at startFrame: Int,
                     samples: [Float],
                     gain: Float) {
        for i in 0..<samples.count {
            let idx = startFrame + i
            if idx < Int.max {
                for ch in 0..<Int(channels) {
                    data[ch][idx] += samples[i] * gain
                }
            }
        }
    }

    // MARK: - Drum sample generators

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

    // MARK: - WAV writer

    private func writeWAV(buffer: AVAudioPCMBuffer, url: URL) -> Bool {
        guard let floatData = buffer.floatChannelData else { return false }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let sampleRate = Int(buffer.format.sampleRate)

        var int16Data = Data(capacity: frameCount * channels * 2)
        for frame in 0..<frameCount {
            for ch in 0..<channels {
                var sample = floatData[ch][frame]
                sample = max(-1, min(1, sample))
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
            Self.logger.error("Failed to write WAV: \(error.localizedDescription)")
            return false
        }
    }
}