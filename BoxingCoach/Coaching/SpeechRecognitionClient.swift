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
    var supportsOnDeviceRecognition: Bool { get }

    func prepareModel() async throws
    func start(
        updateHandler: @escaping @MainActor @Sendable (SpeechRecognitionSessionUpdate) -> Void
    ) throws
    func finishAudio()
    func cancel()
}

@MainActor
protocol SpeechRecognizing: AnyObject {
    func requestPermissions() async -> Bool
    func prepareModel() async throws
    func setTranscriptUpdateHandler(
        _ handler: (@MainActor @Sendable (String) -> Void)?
    )
    func start() throws
    func stop() async -> SpeechRecognitionResult
    func cancel()
}

extension SpeechRecognitionSessionBackend {
    func prepareModel() async throws {}
}

extension SpeechRecognizing {
    func prepareModel() async throws {}
    func setTranscriptUpdateHandler(
        _ handler: (@MainActor @Sendable (String) -> Void)?
    ) {}
}

/// Owns the framework objects for one speech-recognition stream. The semantic client binds every
/// callback from this backend to the capture generation that created it.
@MainActor
final class SystemSpeechRecognitionSessionBackend: SpeechRecognitionSessionBackend {
    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var selectedModule: SelectedTranscriber?
    private var inputConverter: AnalyzerInputConverter?
    private var inputBridge: AnalyzerAudioInputBridge?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var hasInstalledTap = false

    var isAvailable: Bool {
        selectedModule != nil || SpeechTranscriber.isAvailable
    }

    var supportsOnDeviceRecognition: Bool {
        selectedModule != nil
    }

    func prepareModel() async throws {
        cancel()
        let requestedLocale = Locale.autoupdatingCurrent
        let selectedModule: SelectedTranscriber

        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            selectedModule = .speech(SpeechTranscriber(
                locale: locale,
                preset: .progressiveTranscription
            ))
        } else if let locale = await DictationTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) {
            selectedModule = .dictation(DictationTranscriber(
                locale: locale,
                preset: .progressiveShortDictation
            ))
        } else {
            throw SpeechRecognitionClient.SpeechError.unsupportedLocale
        }

        let modules = selectedModule.modules
        switch await AssetInventory.status(forModules: modules) {
        case .unsupported:
            throw SpeechRecognitionClient.SpeechError.onDeviceRecognitionUnavailable
        case .downloading, .supported:
            if let installation = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) {
                try await installation.downloadAndInstall()
            }
        case .installed:
            break
        @unknown default:
            throw SpeechRecognitionClient.SpeechError.onDeviceRecognitionUnavailable
        }

        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw SpeechRecognitionClient.SpeechError.onDeviceRecognitionUnavailable
        }

        self.selectedModule = selectedModule
        inputConverter = try await AnalyzerInputConverter.converter(compatibleWith: modules)
    }

    func start(
        updateHandler: @escaping @MainActor @Sendable (SpeechRecognitionSessionUpdate) -> Void
    ) throws {
        guard let selectedModule, let inputConverter else {
            throw SpeechRecognitionClient.SpeechError.onDeviceRecognitionUnavailable
        }
        let analyzer = SpeechAnalyzer(
            modules: selectedModule.modules,
            options: .init(priority: .userInitiated, modelRetention: .whileInUse)
        )
        self.analyzer = analyzer

        let streamPair = AsyncStream<AnalyzerInput>.makeStream()
        let bridge = try AnalyzerAudioInputBridge(
            converter: inputConverter,
            continuation: streamPair.continuation
        )
        inputBridge = bridge

        resultTask = selectedModule.makeResultTask(updateHandler: updateHandler)
        analysisTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: streamPair.stream)
            } catch is CancellationError {
                return
            } catch {
                guard self?.inputBridge === bridge else { return }
                updateHandler(.init(transcript: nil, isFinal: true))
            }
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = Self.recordingFormat(for: inputNode)
        removeInputTapIfNeeded()
        do {
            try inputNode.installAudioTap(
                onBus: 0,
                bufferSize: 1024,
                format: recordingFormat,
                tapProvider: { [bridge] buffer, time in
                    bridge.consume(buffer, at: time)
                }
            )
            hasInstalledTap = true

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            cancel()
            throw error
        }
    }

    func finishAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeInputTapIfNeeded()
        inputBridge?.finish()
        if let analyzer {
            finalizationTask = Task {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        }
    }

    func cancel() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeInputTapIfNeeded()
        inputBridge?.cancel()
        inputBridge = nil
        analysisTask?.cancel()
        analysisTask = nil
        resultTask?.cancel()
        resultTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        if let analyzer {
            self.analyzer = nil
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private func removeInputTapIfNeeded() {
        guard hasInstalledTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        hasInstalledTap = false
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

    private enum SelectedTranscriber {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var modules: [any SpeechModule] {
            switch self {
            case let .speech(transcriber): [transcriber]
            case let .dictation(transcriber): [transcriber]
            }
        }

        func makeResultTask(
            updateHandler: @escaping @MainActor @Sendable (
                SpeechRecognitionSessionUpdate
            ) -> Void
        ) -> Task<Void, Never> {
            switch self {
            case let .speech(transcriber):
                Task {
                    do {
                        for try await result in transcriber.results {
                            updateHandler(.init(
                                transcript: String(result.text.characters),
                                isFinal: result.isFinal
                            ))
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        updateHandler(.init(transcript: nil, isFinal: true))
                    }
                }
            case let .dictation(transcriber):
                Task {
                    do {
                        for try await result in transcriber.results {
                            updateHandler(.init(
                                transcript: String(result.text.characters),
                                isFinal: result.isFinal
                            ))
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        updateHandler(.init(transcript: nil, isFinal: true))
                    }
                }
            }
        }
    }
}

/// The audio tap is synchronously serialized by AVAudioEngine. The lock also excludes `finish()`
/// after the engine has stopped, so the non-Sendable converter never has concurrent callers and
/// no captured buffer escapes the tap callback.
nonisolated private final class AnalyzerAudioInputBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AnalyzerInputConverter
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    init(
        converter: AnalyzerInputConverter,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        self.converter = converter
        self.continuation = continuation
    }

    func consume(_ buffer: AVReadOnlyAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        do {
            // The visionOS 27 tap intentionally exposes read-only input. The analyzer converter
            // accepts an owned AVAudioBuffer, so make an in-memory copy whose lifetime cannot
            // escape this synchronous callback.
            let ownedBuffer = AVAudioPCMBuffer(copying: buffer)
            for input in try converter.convert(ownedBuffer, at: time) {
                continuation.yield(input)
            }
        } catch {
            continuation.finish()
            self.continuation = nil
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        if let inputs = try? converter.flush() {
            for input in inputs { continuation.yield(input) }
        }
        continuation.finish()
        self.continuation = nil
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
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
    private var transcriptUpdateHandler: (@MainActor @Sendable (String) -> Void)?
    private(set) var isRecording = false

    convenience init() {
        self.init(backend: SystemSpeechRecognitionSessionBackend())
    }

    init(backend: any SpeechRecognitionSessionBackend) {
        self.backend = backend
    }

    func requestPermissions() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func prepareModel() async throws {
        try await backend.prepareModel()
    }

    func setTranscriptUpdateHandler(
        _ handler: (@MainActor @Sendable (String) -> Void)?
    ) {
        transcriptUpdateHandler = handler
    }

    func start() throws {
        guard backend.isAvailable else {
            throw SpeechError.recognizerUnavailable
        }
        guard backend.supportsOnDeviceRecognition else {
            throw SpeechError.onDeviceRecognitionUnavailable
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
                    self.transcriptUpdateHandler?(transcript)
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
        latestTranscript = ""
        receivedFinal = false
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

    enum SpeechError: LocalizedError, Equatable {
        case recognizerUnavailable
        case onDeviceRecognitionUnavailable
        case unsupportedLocale

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "Speech recognition is unavailable on this device."
            case .onDeviceRecognitionUnavailable:
                return "On-device speech recognition is unavailable on this device."
            case .unsupportedLocale:
                return "On-device speech recognition is unavailable for this language."
            }
        }
    }
}
