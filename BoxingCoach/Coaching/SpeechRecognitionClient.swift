import AVFoundation
import Foundation
import Speech

nonisolated struct SpeechRecognitionResult: Sendable, Equatable {
    var transcript: String
    var duration: TimeInterval
}

nonisolated struct SpeechRecognitionSessionUpdate: Sendable, Equatable {
    let transcript: String?
    let isFinal: Bool
}

@MainActor
protocol SpeechRecognitionSessionBackend: AnyObject {
    var isAvailable: Bool { get }

    func start(
        updateHandler: @escaping @MainActor @Sendable (SpeechRecognitionSessionUpdate) -> Void
    ) throws
    func finishAudio()
    func cancel()
}

@MainActor
protocol SpeechRecognizing: AnyObject {
    func requestPermissions() async -> Bool
    func start() throws
    func stop() async -> SpeechRecognitionResult
    func cancel()
}

/// Owns the framework objects for one speech-recognition stream. The semantic client binds every
/// callback from this backend to the capture generation that created it.
@MainActor
final class SystemSpeechRecognitionSessionBackend: SpeechRecognitionSessionBackend {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInstalledTap = false

    var isAvailable: Bool {
        speechRecognizer?.isAvailable == true
    }

    func start(
        updateHandler: @escaping @MainActor @Sendable (SpeechRecognitionSessionUpdate) -> Void
    ) throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = Self.recordingFormat(for: inputNode)
        removeInputTapIfNeeded()
        do {
            try inputNode.installAudioTap(
                onBus: 0,
                bufferSize: 1024,
                format: recordingFormat,
                tapProvider: { buffer, _ in
                    guard let writable = Self.writableCopy(of: buffer) else { return }
                    request.append(writable)
                }
            )
            hasInstalledTap = true

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            cancel()
            throw error
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            let update = SpeechRecognitionSessionUpdate(
                transcript: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal == true || error != nil
            )
            Task { @MainActor in
                updateHandler(update)
            }
        }
    }

    func finishAudio() {
        request?.endAudio()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeInputTapIfNeeded()
    }

    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeInputTapIfNeeded()
    }

    private func removeInputTapIfNeeded() {
        guard hasInstalledTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        hasInstalledTap = false
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
}

/// On-device speech-to-text for push-to-talk voice commands.
@MainActor
final class SpeechRecognitionClient: SpeechRecognizing {
    private let backend: any SpeechRecognitionSessionBackend
    private var startedAt: Date?
    private var latestTranscript = ""
    private var receivedFinal = false
    private var nextCaptureGeneration: UInt64 = 0
    private var activeCaptureGeneration: UInt64?
    private(set) var isRecording = false

    convenience init() {
        self.init(backend: SystemSpeechRecognitionSessionBackend())
    }

    init(backend: any SpeechRecognitionSessionBackend) {
        self.backend = backend
    }

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
        guard backend.isAvailable else {
            throw SpeechError.recognizerUnavailable
        }
        guard activeCaptureGeneration == nil else { return }

        nextCaptureGeneration &+= 1
        let captureGeneration = nextCaptureGeneration
        activeCaptureGeneration = captureGeneration
        latestTranscript = ""
        receivedFinal = false
        startedAt = Date()

        do {
            try backend.start { [weak self] update in
                guard let self,
                      self.activeCaptureGeneration == captureGeneration else { return }
                if let transcript = update.transcript {
                    self.latestTranscript = transcript
                }
                if update.isFinal {
                    self.receivedFinal = true
                }
            }
            isRecording = true
        } catch {
            activeCaptureGeneration = nil
            backend.cancel()
            latestTranscript = ""
            receivedFinal = false
            startedAt = nil
            throw error
        }
    }

    func stop() async -> SpeechRecognitionResult {
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard isRecording,
              let captureGeneration = activeCaptureGeneration else {
            return SpeechRecognitionResult(transcript: "", duration: duration)
        }

        isRecording = false
        backend.finishAudio()

        let deadline = ContinuousClock.now + .milliseconds(1_000)
        while activeCaptureGeneration == captureGeneration,
              !receivedFinal,
              ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                cancel()
                return SpeechRecognitionResult(transcript: "", duration: duration)
            }
        }

        guard activeCaptureGeneration == captureGeneration else {
            return SpeechRecognitionResult(transcript: "", duration: duration)
        }
        let transcript = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        activeCaptureGeneration = nil
        backend.cancel()
        startedAt = nil

        return SpeechRecognitionResult(transcript: transcript, duration: duration)
    }

    func cancel() {
        activeCaptureGeneration = nil
        isRecording = false
        backend.cancel()
        latestTranscript = ""
        receivedFinal = false
        startedAt = nil
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
