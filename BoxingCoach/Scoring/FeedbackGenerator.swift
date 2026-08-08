import Foundation

/// Natural-language coaching for one attempt.
nonisolated struct CoachingFeedback: Sendable, Equatable {
    /// One line summarizing how the punch went.
    var headline: String
    /// The single most valuable correction for the next rep.
    var primaryFix: String
    /// Something the user did well, so feedback isn't purely negative.
    var encouragement: String

    /// True when this came from the offline generator rather than the model.
    var isOffline: Bool = false
}

/// Turns a deterministic `TechniqueScore` into coaching a beginner can act on.
///
/// **The generator never decides the score.** It receives numbers that were already computed
/// geometrically and writes prose about them. That split is what makes the feedback trustworthy:
/// the same attempt always produces the same score, and the model's only job is explaining it.
/// A model that could move the number could also flatter the user into a bad habit.
protocol FeedbackGenerating: Sendable {
    func feedback(for score: TechniqueScore, technique: Technique) async -> CoachingFeedback
}

// MARK: - Offline

/// Deterministic, offline coaching built from the sub-metric breakdown.
///
/// **This is the demo's safety net.** Conference wifi fails, and a live demo that hangs waiting on
/// a network call is worse than one with slightly less eloquent coaching — so this runs instantly,
/// never fails, and is good enough to ship on its own.
nonisolated struct MockFeedbackGenerator: FeedbackGenerating {
    func feedback(for score: TechniqueScore, technique: Technique) async -> CoachingFeedback {
        CoachingFeedback(
            headline: headline(for: score, technique: technique),
            primaryFix: primaryFix(for: score, technique: technique),
            encouragement: encouragement(for: score),
            isOffline: true
        )
    }

    private func headline(for score: TechniqueScore, technique: Technique) -> String {
        let base = "\(technique.name): \(Int(score.overall.rounded()))/100 — \(score.grade)."
        guard score.wrongHand else { return base }
        return "\(base) Wrong hand — that one doesn't count as a \(technique.name.lowercased())."
    }

    private func primaryFix(for score: TechniqueScore, technique: Technique) -> String {
        // The hand comes first when it was wrong. Coaching someone's elbow on a punch they threw
        // with the wrong arm fixes the wrong problem — they have to throw it off the right hand
        // before anything else about the shape is worth talking about.
        if let note = score.wrongHandNote {
            return "\(note) Throw the next one off your \(score.requiredHandName)."
        }

        guard let weakest = score.weakest, let value = weakest.score, value < 85 else {
            // Nothing stands out as wrong, so fall back to a technique cue rather than
            // manufacturing a fault the numbers don't support.
            return technique.coachingCues.first ?? "Keep the shape you just threw and repeat it."
        }
        return "Next rep, focus on this: \(weakest.kind.faultDescription). \(cue(for: weakest.kind, technique: technique))"
    }

    private func encouragement(for score: TechniqueScore) -> String {
        guard let strongest = score.strongest, let value = strongest.score, value >= 70 else {
            return "Early reps are about the shape, not the score — keep going."
        }
        return "Your \(strongest.kind.title.lowercased()) looked good — keep that part."
    }

    /// Pairs a failing sub-metric with the technique's own cue for that fault, so the advice is
    /// specific to the punch rather than generic.
    private func cue(for kind: SubMetricKind, technique: Technique) -> String {
        let cues = technique.coachingCues
        switch kind {
        case .extensionReach: return cues.first(where: { $0.lowercased().contains("straight") || $0.lowercased().contains("drive") }) ?? "Reach all the way through the target."
        case .path: return cues.first(where: { $0.lowercased().contains("straight") || $0.lowercased().contains("level") }) ?? "Send the fist on the shortest line to the target."
        case .elbow: return cues.first(where: { $0.lowercased().contains("elbow") }) ?? "Keep the elbow in line with the punch."
        case .guardHand: return cues.first(where: { $0.lowercased().contains("chin") || $0.lowercased().contains("hand") }) ?? "Keep the spare hand at your chin."
        case .retraction: return cues.first(where: { $0.lowercased().contains("back") || $0.lowercased().contains("guard") }) ?? "Snap the hand straight back to guard."
        }
    }
}

// MARK: - Claude

/// Coaching written by Claude from the computed sub-metrics.
///
/// Swift has no official Anthropic SDK, so this talks to the Messages API over raw HTTPS.
///
/// ⚠️ **The API key ships inside the app binary.** Anyone with the `.app` can extract it and spend
/// against the account. That is acceptable for a hackathon demo on a device you control and
/// nothing else — for anything real, move this call behind a server you own and have the app talk
/// to that instead. Do not commit a key to the repository.
nonisolated struct ClaudeFeedbackGenerator: FeedbackGenerating {
    var apiKey: String
    var session: URLSession

    /// Falls back to this whenever the network call fails for any reason.
    private let offline = MockFeedbackGenerator()

    init(apiKey: String, timeout: TimeInterval = 12) {
        self.apiKey = apiKey

        // A live demo cannot afford to hang on a stalled request — time out fast and use the
        // offline coach instead. The user gets feedback either way.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    func feedback(for score: TechniqueScore, technique: Technique) async -> CoachingFeedback {
        do {
            return try await requestFeedback(for: score, technique: technique)
        } catch {
            // Any failure — offline, refused, rate-limited, malformed — degrades to the offline
            // coach rather than surfacing an error where coaching should be.
            return await offline.feedback(for: score, technique: technique)
        }
    }

    // MARK: Request

    private func requestFeedback(
        for score: TechniqueScore,
        technique: Technique
    ) async throws -> CoachingFeedback {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Opt in to server-side fallbacks: if a safety classifier declines the request, the API
        // re-runs it on another model in the same call instead of returning nothing.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(for: score, technique: technique)
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FeedbackError.badResponse
        }

        return try parse(data)
    }

    private func requestBody(for score: TechniqueScore, technique: Technique) -> [String: Any] {
        [
            "model": "claude-opus-5",

            // Generous ceiling on purpose. `max_tokens` caps reasoning *and* reply together, and
            // thinking is on by default on this model — a tight limit truncates the reply rather
            // than saving money. Cost is controlled with `effort` below instead.
            "max_tokens": 16000,

            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": scoreSummary(for: score, technique: technique)]
            ],
            "output_config": [
                // Turning five numbers into two sentences needs no deep reasoning, and the user is
                // standing there waiting after throwing a punch.
                "effort": "low",

                // Structured output: the reply is schema-checked JSON, so there is no prose to
                // parse heuristically and no "here's your feedback:" preamble to strip.
                "format": [
                    "type": "json_schema",
                    "schema": [
                        "type": "object",
                        "properties": [
                            "headline": [
                                "type": "string",
                                "description": "One short line on how the punch went overall."
                            ],
                            "primaryFix": [
                                "type": "string",
                                "description": "The single most valuable correction for the next rep, in one or two sentences."
                            ],
                            "encouragement": [
                                "type": "string",
                                "description": "One short line naming something the boxer did well."
                            ]
                        ],
                        "required": ["headline", "primaryFix", "encouragement"],
                        "additionalProperties": false
                    ]
                ]
            ],

            // Recommended fallback routing — picks the substitute model automatically rather than
            // pinning one that later needs migrating.
            "fallbacks": "default"
        ]
    }

    private var systemPrompt: String {
        """
        You are a boxing coach giving feedback to a complete beginner training alone at home.

        You will be given scores that were already computed from motion-tracking data. Explain \
        those scores. Never invent, recalculate, contradict, or hedge them — if a sub-metric is \
        90, treat it as good; if it is 30, treat it as the problem. If a sub-metric is marked \
        unavailable, do not comment on it at all; it was not measured, which is not the same as \
        the boxer doing it badly.

        If the summary says the punch was thrown with the wrong hand, lead with that and make it \
        the correction — everything else is secondary, because the shape of a punch thrown off \
        the wrong arm is not the fault worth fixing first. Say plainly which hand it should be.

        Coach one thing at a time. Beginners cannot fix five faults at once, so name the single \
        most valuable correction and leave the rest. Write plainly, the way someone would talk in \
        a gym — no jargon the boxer would not already know, no lists, no preamble. Keep every \
        field to one or two sentences.
        """
    }

    /// The measured facts, formatted for the model. Deliberately dry — every judgment is already
    /// baked into the numbers, so there is nothing here for the model to re-decide.
    private func scoreSummary(for score: TechniqueScore, technique: Technique) -> String {
        var lines: [String] = [
            "Technique: \(technique.name) — \(technique.summary)",
            "Overall: \(Int(score.overall.rounded()))/100 (\(score.grade))",
            "Punch duration: \(String(format: "%.2f", score.duration))s",
            "Required hand: \(score.requiredHandName)"
        ]

        if let note = score.wrongHandNote {
            lines.append("WRONG HAND: \(note) The overall score above already includes the penalty for this.")
        }

        lines.append(contentsOf: [
            "",
            "Sub-metrics (0-100, higher is better):"
        ])

        for metric in score.metrics {
            if let value = metric.score {
                lines.append("- \(metric.kind.title): \(Int(value.rounded()))/100 — \(metric.kind.explanation). Measured: \(metric.detail)")
            } else {
                lines.append("- \(metric.kind.title): not measured (\(metric.detail)) — do not comment on this")
            }
        }

        if score.trackedFraction < 0.9 {
            lines.append("")
            lines.append("Note: \(Int((score.trackedFraction * 100).rounded()))% of the motion was cleanly tracked; the rest was interpolated.")
        }

        lines.append("")
        lines.append("Standard cues for this punch: \(technique.coachingCues.joined(separator: "; "))")

        return lines.joined(separator: "\n")
    }

    // MARK: Response

    private func parse(_ data: Data) throws -> CoachingFeedback {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeedbackError.malformed
        }

        // Check this before reading content. A declined request still returns HTTP 200, with an
        // empty or partial `content` array — indexing into it blindly would crash or read garbage.
        if root["stop_reason"] as? String == "refusal" {
            throw FeedbackError.refused
        }

        guard let content = root["content"] as? [[String: Any]] else {
            throw FeedbackError.malformed
        }

        // Responses can carry thinking blocks ahead of the answer, so find the text block rather
        // than assuming it is first.
        guard let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let payload = text.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let headline = fields["headline"] as? String,
              let primaryFix = fields["primaryFix"] as? String,
              let encouragement = fields["encouragement"] as? String
        else {
            throw FeedbackError.malformed
        }

        return CoachingFeedback(
            headline: headline,
            primaryFix: primaryFix,
            encouragement: encouragement,
            isOffline: false
        )
    }

    enum FeedbackError: Error {
        case badResponse
        case refused
        case malformed
    }
}
