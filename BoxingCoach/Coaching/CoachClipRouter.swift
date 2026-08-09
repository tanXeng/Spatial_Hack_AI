import Foundation

/// Maps user speech to a pre-recorded coach clip. OpenAI picks the clip ID; keywords are the offline fallback.
nonisolated struct CoachClipRouter {
    var apiKey: String?
    var session: URLSession
    var timeout: TimeInterval

    init(apiKey: String? = nil, timeout: TimeInterval = 1.5) {
        self.apiKey = apiKey
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    func resolve(transcript: String, context: CoachVoiceContext) async -> CoachClipID {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .didntCatch }

        if let keywordMatch = Self.keywordMatch(for: normalized) {
            return keywordMatch
        }

        guard let effectiveKey = apiKey ?? CoachSecrets.openAIAPIKey, !effectiveKey.isEmpty else {
            return .didntCatch
        }

        do {
            return try await requestClipID(transcript: normalized, context: context, apiKey: effectiveKey)
        } catch {
            return Self.keywordMatch(for: normalized) ?? .didntCatch
        }
    }

    // MARK: - OpenAI

    private func requestClipID(
        transcript: String,
        context: CoachVoiceContext,
        apiKey: String
    ) async throws -> CoachClipID {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(
            transcript: transcript,
            context: context
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RouterError.badResponse
        }
        return try parseClipID(from: data)
    }

    private func requestBody(transcript: String, context: CoachVoiceContext) -> [String: Any] {
        let catalog = Self.voiceCatalog.map { entry in
            [
                "id": entry.id.rawValue,
                "title": entry.title,
                "whenToUse": entry.whenToUse
            ] as [String: String]
        }

        let contextSummary: String
        switch context.feature {
        case .auraPunch:
            contextSummary = "Aura Punch tutorial, phase: \(context.auraPhase?.rawValue ?? "unknown"), technique: \(context.techniqueName ?? "unknown")"
        case .reactiveStrike:
            contextSummary = "Reactive Strike drill, phase: \(context.drillPhase?.rawValue ?? "unknown")"
        }

        return [
            "model": "gpt-4o-mini",
            "temperature": 0,
            "max_tokens": 40,
            "response_format": ["type": "json_object"],
            "messages": [
                [
                    "role": "system",
                    "content": """
                    You are a boxing coach clip router. Given the user's spoken words and a clip catalog, \
                    return exactly one clipID from the catalog as JSON: {"clipID":"..."}. \
                    If nothing matches, return {"clipID":"didnt_catch"}. \
                    Never invent new clip IDs or spoken text.
                    """
                ],
                [
                    "role": "user",
                    "content": """
                    User said: "\(transcript)"
                    Training context: \(contextSummary)
                    Clip catalog: \(catalog)
                    """
                ]
            ]
        ]
    }

    private func parseClipID(from data: Data) throws -> CoachClipID {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String,
            let contentData = content.data(using: .utf8),
            let payload = try JSONSerialization.jsonObject(with: contentData) as? [String: Any],
            let clipID = payload["clipID"] as? String,
            let resolved = CoachClipID(rawValue: clipID)
        else {
            throw RouterError.malformedPayload
        }
        return resolved
    }

    // MARK: - Catalog + keywords

    private struct CatalogEntry: Sendable {
        let id: CoachClipID
        let title: String
        let whenToUse: String
        let keywords: [String]
    }

    private static let voiceCatalog: [CatalogEntry] = [
        CatalogEntry(
            id: .qaWhatFix,
            title: "What to fix",
            whenToUse: "User asks how they did or what to improve",
            keywords: ["fix", "wrong", "improve", "mistake", "score", "how was", "what should"]
        ),
        CatalogEntry(
            id: .qaWhyGuard,
            title: "Why guard",
            whenToUse: "User asks about keeping hands up or guard position",
            keywords: ["guard", "hands up", "chin", "why guard", "protect"]
        ),
        CatalogEntry(
            id: .qaRepeatDemo,
            title: "Repeat demo",
            whenToUse: "User wants to see the demonstration again",
            keywords: ["again", "repeat", "demo", "show me", "watch"]
        ),
        CatalogEntry(
            id: .qaSlower,
            title: "Go slower",
            whenToUse: "User wants a slower pace",
            keywords: ["slow", "slower", "too fast", "pace"]
        ),
        CatalogEntry(
            id: .qaHitTarget,
            title: "Hit target",
            whenToUse: "User asks where or how to punch the target",
            keywords: ["target", "where", "punch", "hit", "orange", "sphere"]
        ),
        CatalogEntry(
            id: .qaThreePunches,
            title: "Three punches",
            whenToUse: "User asks how many punches in the scored round",
            keywords: ["how many", "three", "punches", "reps", "round"]
        ),
        CatalogEntry(
            id: .pauseAck,
            title: "Pause",
            whenToUse: "User wants to pause or stop briefly",
            keywords: ["pause", "stop", "hold on", "wait"]
        ),
        CatalogEntry(
            id: .resumeAck,
            title: "Resume",
            whenToUse: "User wants to continue training",
            keywords: ["continue", "resume", "ready", "go", "start again"]
        ),
        CatalogEntry(
            id: .helpCommands,
            title: "Help",
            whenToUse: "User asks what they can say",
            keywords: ["help", "commands", "what can i say", "options"]
        ),
        CatalogEntry(
            id: .didntCatch,
            title: "Didn't catch",
            whenToUse: "Unclear or unsupported request",
            keywords: []
        )
    ]

    static func keywordMatch(for transcript: String) -> CoachClipID? {
        let lowered = transcript.lowercased()
        var best: (CoachClipID, Int)?
        for entry in voiceCatalog where !entry.keywords.isEmpty {
            let hits = entry.keywords.filter { lowered.contains($0) }.count
            guard hits > 0 else { continue }
            if let current = best {
                if hits > current.1 { best = (entry.id, hits) }
            } else {
                best = (entry.id, hits)
            }
        }
        return best?.0
    }

    private enum RouterError: Error {
        case badResponse
        case malformedPayload
    }
}
