import AVFoundation
import Foundation
import os

@MainActor
final class CoachMusicPlayer {
    private static let logger = Logger(
        subsystem: "com.josephkwokpersonalteam.BoxingCoach", category: "CoachMusic"
    )

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let mixerNode = AVAudioMixerNode()

    private var kickBuffer: AVAudioPCMBuffer?
    private var snareBuffer: AVAudioPCMBuffer?
    private var hihatBuffer: AVAudioPCMBuffer?

    private var isPlaying = false
    private var beatTimer: DispatchSourceTimer?
    private let beatQueue = DispatchQueue(label: "coach.music.beat")
    private let sampleRate: Double = 44100
    private var beatIndex: Int = 0
    private var eighthIndex: Int = 0
    private var tempo: Double = 130

    private(set) var isActive = false {
        didSet { Self.logger.debug("Music active: \(self.isActive)") }
    }

    var volume: Float {
        get { mixerNode.outputVolume }
        set { mixerNode.outputVolume = max(0, min(1, newValue)) }
    }

    func prepare() {
        guard !engine.isRunning else { return }

        engine.attach(playerNode)
        engine.attach(mixerNode)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        engine.connect(playerNode, to: mixerNode, format: format)
        engine.connect(mixerNode, to: engine.mainMixerNode, format: format)

        kickBuffer = synthesizeKick(format: format)
        snareBuffer = synthesizeSnare(format: format)
        hihatBuffer = synthesizeHihat(format: format)

        do {
            try engine.start()
            playerNode.play()
            Self.logger.debug("Audio engine started for music")
        } catch {
            Self.logger.error("Failed to start music engine: \(error.localizedDescription)")
        }
    }

    func start() {
        guard engine.isRunning, !isActive else { return }
        isActive = true
        beatIndex = 0
        eighthIndex = 0
        startBeatLoop()
        Self.logger.debug("Music started at \(self.tempo) BPM")
    }

    func stop() {
        isActive = false
        beatTimer?.cancel()
        beatTimer = nil
        Self.logger.debug("Music stopped")
    }

    func setTempo(_ bpm: Double) {
        tempo = max(60, min(180, bpm))
        if isActive {
            beatTimer?.cancel()
            startBeatLoop()
        }
    }

    func shutdown() {
        stop()
        if engine.isRunning {
            engine.stop()
        }
    }

    private func startBeatLoop() {
        let interval = 60.0 / tempo / 2.0
        let timer = DispatchSource.makeTimerSource(queue: beatQueue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.tick()
            }
        }
        timer.resume()
        beatTimer = timer
    }

    private func tick() {
        guard isActive else { return }

        let beat = beatIndex % 4
        let eighth = eighthIndex % 8

        if eighth == 0 || eighth == 4 {
            if beat == 0 || beat == 2 {
                scheduleKick()
            } else {
                scheduleSnare()
            }
        } else {
            scheduleHihat()
        }

        eighthIndex += 1
        if eighth % 2 == 0 {
            beatIndex += 1
        }
    }

    private func scheduleKick() {
        guard let buf = kickBuffer else { return }
        playerNode.scheduleBuffer(buf, at: nil, options: .interruptsAtLoop, completionHandler: nil)
    }

    private func scheduleSnare() {
        guard let buf = snareBuffer else { return }
        playerNode.scheduleBuffer(buf, at: nil, options: .interruptsAtLoop, completionHandler: nil)
    }

    private func scheduleHihat() {
        guard let buf = hihatBuffer else { return }
        playerNode.scheduleBuffer(buf, at: nil, options: .interruptsAtLoop, completionHandler: nil)
    }

    private func synthesizeKick(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let duration: Double = 0.15
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return AVAudioPCMBuffer()
        }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData else { return buffer }

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let envelope = exp(-t * 30.0)
            let freq = 80.0 * exp(-t * 20.0) + 40.0
            let sample = Float(sin(2.0 * .pi * freq * t) * envelope * 0.7)
            for channel in 0..<Int(format.channelCount) {
                data[channel][frame] = sample
            }
        }
        return buffer
    }

    private func synthesizeSnare(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let duration: Double = 0.10
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return AVAudioPCMBuffer()
        }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData else { return buffer }

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let envelope = exp(-t * 40.0)
            let noise = Float.random(in: -1...1)
            let tone = Float(sin(2.0 * .pi * 200.0 * t))
            let sample = Float((Double(noise) * 0.6 + Double(tone) * 0.4) * envelope * 0.5)
            for channel in 0..<Int(format.channelCount) {
                data[channel][frame] = sample
            }
        }
        return buffer
    }

    private func synthesizeHihat(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let duration: Double = 0.04
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return AVAudioPCMBuffer()
        }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData else { return buffer }

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let envelope = exp(-t * 120.0)
            let noise = Float.random(in: -1...1)
            let highFreq = Float(sin(2.0 * .pi * 8000.0 * t))
            let sample = Float((Double(noise) * 0.5 + Double(highFreq) * 0.5) * envelope * 0.25)
            for channel in 0..<Int(format.channelCount) {
                data[channel][frame] = sample
            }
        }
        return buffer
    }
}