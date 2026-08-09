import Foundation

/// Maps user speech to a pre-recorded coach clip without sending speech off device.
nonisolated struct CoachClipRouter {
    func resolve(transcript: String, context: CoachVoiceContext) async -> CoachClipID {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .didntCatch }
        return Self.keywordMatch(for: normalized) ?? .didntCatch
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
}
