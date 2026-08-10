import Foundation

nonisolated struct OpenAICoachChatClient {
    var apiKey: String?
    var session: URLSession
    var timeout: TimeInterval

    init(apiKey: String? = nil, session: URLSession? = nil, timeout: TimeInterval = 12) {
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
            "model": "gpt-4o-mini",
            "temperature": 0.4,
            "max_tokens": 200,
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
        You are the voice coach inside Boxing Coach on Apple Vision Pro. You know this product intimately.

        \(CoachAppGuide.overview)

        CURRENT SESSION: \(CoachAppGuide.sessionContext(for: context))

        RULES:
        - When users ask how to practice a punch or use the app, give concrete in-app steps \
        (Aura Punch, Reactive Strike, guard, hologram, targets). Do not tell them to shadowbox at home \
        unless they explicitly ask about training without the headset.
        - For general questions (math, trivia, facts), answer directly and briefly.
        - For boxing form, tie advice to what this app tracks and the active mode when relevant.
        - Reply in 1 to 3 short spoken sentences. No markdown, lists, or clip names.
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
