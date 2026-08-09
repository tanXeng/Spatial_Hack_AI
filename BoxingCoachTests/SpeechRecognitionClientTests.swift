import Foundation
import Testing
@testable import BoxingCoach

@Suite("Speech recognition capture generations")
@MainActor
struct SpeechRecognitionClientTests {
    @Test("A cancelled capture callback cannot overwrite the next capture")
    func staleCallbackCannotOverwriteReusedCapture() async throws {
        let backend = ControlledSpeechRecognitionSessionBackend()
        let client = SpeechRecognitionClient(backend: backend)

        try client.start()
        let staleCallback = try #require(backend.updateHandlers.first)
        client.cancel()

        try client.start()
        let currentCallback = try #require(backend.updateHandlers.last)
        currentCallback(.init(transcript: "fresh command", isFinal: true))
        staleCallback(.init(transcript: "stale command", isFinal: true))

        let result = await client.stop()

        #expect(result.transcript == "fresh command")
        #expect(backend.startCount == 2)
        #expect(backend.cancelCount == 2)
    }
}

@MainActor
private final class ControlledSpeechRecognitionSessionBackend: SpeechRecognitionSessionBackend {
    private(set) var updateHandlers: [
        @MainActor @Sendable (SpeechRecognitionSessionUpdate) -> Void
    ] = []
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    var isAvailable = true

    func start(
        updateHandler: @escaping @MainActor @Sendable (SpeechRecognitionSessionUpdate) -> Void
    ) throws {
        startCount += 1
        updateHandlers.append(updateHandler)
    }

    func finishAudio() {}

    func cancel() {
        cancelCount += 1
    }
}
