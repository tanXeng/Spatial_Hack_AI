import AVFoundation
import Foundation
import Speech

nonisolated struct SpeechRecognitionResult: Sendable, Equatable {
    var transcript: String
    var duration: TimeInterval
}

/// On-device speech-to-text for push-to-talk voice commands.
@MainActor
final class SpeechRecognitionClient {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var startedAt: Date?
    private var latestTranscript = ""
    private var receivedFinal = false
    private(set) var isRecording = false

    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }

        let micStatus = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        return micStatus
    }

    func start() throws {
        guard speechRecognizer?.isAvailable == true else {
            throw SpeechError.recognizerUnavailable
        }
        guard !isRecording else { return }

        latestTranscript = ""
        receivedFinal = false
        startedAt = Date()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = Self.recordingFormat(for: inputNode)
        inputNode.removeTap(onBus: 0)
        try inputNode.installAudioTap(
            onBus: 0,
            bufferSize: 1024,
            format: recordingFormat,
            tapProvider: { buffer, _ in
                guard let writable = Self.writableCopy(of: buffer) else { return }
                request.append(writable)
            }
        )

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.latestTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.receivedFinal = true
                    }
                } else if error != nil {
                    self.receivedFinal = true
                }
            }
        }
    }

    nonisolated private static func writableCopy(
        of source: AVReadOnlyAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: AVAudioFrameCount(source.frameLength)
        ) else { return nil }
        copy.frameLength = AVAudioFrameCount(source.frameLength)

        source.withUnsafeAudioBufferList { sourceList in
            let sourceBuffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: sourceList)
            )
            let destinationBuffers = UnsafeMutableAudioBufferListPointer(
                copy.mutableAudioBufferList
            )
            for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
                guard let sourceData = sourceBuffers[index].mData,
                      let destinationData = destinationBuffers[index].mData else { continue }
                let byteCount = min(
                    Int(sourceBuffers[index].mDataByteSize),
                    Int(destinationBuffers[index].mDataByteSize)
                )
                destinationData.copyMemory(from: sourceData, byteCount: byteCount)
                destinationBuffers[index].mDataByteSize = UInt32(byteCount)
            }
        }
        return copy
    }

    func stop() async -> SpeechRecognitionResult {
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard isRecording else {
            return SpeechRecognitionResult(transcript: "", duration: duration)
        }

        isRecording = false
        request?.endAudio()
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        let deadline = ContinuousClock.now + .milliseconds(1_000)
        while !receivedFinal, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        let transcript = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        finishRecognitionTask()
        startedAt = nil

        return SpeechRecognitionResult(transcript: transcript, duration: duration)
    }

    func cancel() {
        isRecording = false
        finishRecognitionTask()
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        latestTranscript = ""
        receivedFinal = false
        startedAt = nil
    }

    private func finishRecognitionTask() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
    }

    private static func recordingFormat(for inputNode: AVAudioInputNode) -> AVAudioFormat {
        let outputFormat = inputNode.outputFormat(forBus: 0)
        if outputFormat.sampleRate > 0 {
            return outputFormat
        }
        let inputFormat = inputNode.inputFormat(forBus: 0)
        if inputFormat.sampleRate > 0 {
            return inputFormat
        }
        return AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    }

    enum SpeechError: LocalizedError {
        case recognizerUnavailable

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "Speech recognition is unavailable on this device."
            }
        }
    }
}
