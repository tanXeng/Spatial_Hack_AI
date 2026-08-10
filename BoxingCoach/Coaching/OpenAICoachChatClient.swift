import Foundation

nonisolated struct OpenAICoachChatClient {
    static let defaultModel = "gpt-4.1-nano"
    static let defaultMaxTokens = 60

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

    func answer(transcript: String, context: CoachVoiceContext) async throws -> String {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw OpenAICoachChatError.emptyTranscript }

        guard let effectiveKey = apiKey ?? CoachSecrets.openAIAPIKey, !effectiveKey.isEmpty else {
            throw OpenAICoachChatError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(effectiveKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.defaultModel,
            "temperature": 0.3,
            "max_tokens": Self.defaultMaxTokens,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt(for: context)
                ],
                [
                    "role": "user",
                    "content": normalized
                ]
            ]
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenAICoachChatError.badResponse
        }
        return try parseAnswer(from: data)
    }

    private func systemPrompt(for context: CoachVoiceContext) -> String {
        """
        Voice coach for Boxing Coach on Vision Pro.

        \(CoachAppGuide.compactOverview)

        NOW: \(CoachAppGuide.sessionContext(for: context))

        Rules: Answer in one short spoken sentence (under 20 words). Be direct. \
        For app/how-to questions, name Aura Punch or Reactive Strike. \
        No markdown, lists, or home shadowboxing unless asked.
        """
    }

    private func parseAnswer(from data: Data) throws -> String {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw OpenAICoachChatError.malformedPayload
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenAICoachChatError.emptyAnswer }
        return trimmed
    }

    enum OpenAICoachChatError: LocalizedError {
        case missingAPIKey
        case emptyTranscript
        case badResponse
        case malformedPayload
        case emptyAnswer

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "OpenAI API key is missing. Add it to Secrets.xcconfig and rebuild."
            case .emptyTranscript:
                return "No speech was detected."
            case .badResponse:
                return "Could not get a coaching answer. Check your network and API key."
            case .malformedPayload, .emptyAnswer:
                return "Coach returned an empty answer. Try again."
            }
        }
    }
}
