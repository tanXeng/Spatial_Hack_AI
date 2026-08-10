import Foundation

nonisolated struct OpenAITTSClient {
    static let defaultVoice = "onyx"
    static let defaultModel = "tts-1"

    var apiKey: String?
    var session: URLSession
    var timeout: TimeInterval

    init(apiKey: String? = nil, session: URLSession? = nil, timeout: TimeInterval = 8) {
        self.apiKey = apiKey
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func synthesize(
        text: String,
        voice: String = defaultVoice,
        model: String = defaultModel
    ) async throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenAITTSError.emptyText }

        guard let effectiveKey = apiKey ?? CoachSecrets.openAIAPIKey, !effectiveKey.isEmpty else {
            throw OpenAITTSError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(effectiveKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "voice": voice,
            "input": trimmed,
            "response_format": "mp3"
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenAITTSError.badResponse
        }
        guard !data.isEmpty else { throw OpenAITTSError.emptyAudio }
        return data
    }

    enum OpenAITTSError: LocalizedError {
        case missingAPIKey
        case emptyText
        case badResponse
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "OpenAI API key is missing. Add it to Secrets.xcconfig and rebuild."
            case .emptyText:
                return "Nothing to speak."
            case .badResponse:
                return "Voice synthesis failed. Check your network and API key."
            case .emptyAudio:
                return "Voice synthesis returned no audio."
            }
        }
    }
}
