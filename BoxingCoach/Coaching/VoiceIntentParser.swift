import Foundation

/// Parses completed on-device speech into an exact, allow-listed command.
/// This boundary is deterministic and performs no I/O or network work.
nonisolated struct VoiceIntentParser: Sendable {
    func parse(
        _ utterance: VoiceUtterance,
        in context: VoiceCommandContext
    ) -> VoiceIntentParseResult {
        let phrase = Self.normalizedPhrase(utterance.transcript)

        guard !phrase.isEmpty else {
            return rejection(
                phrase: phrase,
                confidence: utterance.confidence,
                reason: .emptyInput,
                recoveryMessage: "I didn't hear a command. Say \"help\" for available commands."
            )
        }
        guard Self.isEnglishLocale(utterance.localeIdentifier) else {
            return rejection(
                phrase: phrase,
                confidence: utterance.confidence,
                reason: .unsupportedLocale,
                recoveryMessage: "Voice commands are available in English. Use the visible controls to continue."
            )
        }
        guard utterance.isFinal else {
            return rejection(
                phrase: phrase,
                confidence: utterance.confidence,
                reason: .incompleteUtterance,
                recoveryMessage: "Finish speaking one command, then try again."
            )
        }
        guard utterance.confidence != .low else {
            return rejection(
                phrase: phrase,
                confidence: utterance.confidence,
                reason: .lowConfidence,
                recoveryMessage: "I didn't catch that clearly. Try again or use the visible controls."
            )
        }
        guard !Self.containsMultipleCommands(phrase) else {
            return rejection(
                phrase: phrase,
                confidence: utterance.confidence,
                reason: .ambiguous,
                recoveryMessage: "I heard more than one command. Say one command at a time."
            )
        }
        guard let intents = Self.intentsByPhrase[phrase], intents.count == 1,
              let intent = intents.first else {
            let reason: VoiceIntentRejectionReason = Self.intentsByPhrase[phrase] == nil
                ? .unrecognized
                : .ambiguous
            let message = reason == .ambiguous
                ? "I heard more than one command. Say one command at a time."
                : "I didn't recognize that command. Say \"help\" for available commands."
            return rejection(
                phrase: phrase,
                confidence: utterance.confidence,
                reason: reason,
                recoveryMessage: message
            )
        }
        guard intent.isAvailable(in: context.state) else {
            return rejection(
                phrase: phrase,
                confidence: utterance.confidence,
                reason: .unavailableInState(intent: intent, state: context.state),
                recoveryMessage: "That command isn't available right now. Say \"help\" for available commands."
            )
        }
        guard context.capabilities.contains(intent.requiredCapability) else {
            return rejection(
                phrase: phrase,
                confidence: utterance.confidence,
                reason: .unavailableCapability(intent: intent),
                recoveryMessage: "That action isn't available in this training mode. Use the visible controls or say \"help\"."
            )
        }

        return .accepted(
            VoiceIntentMatch(
                intent: intent,
                normalizedPhrase: phrase,
                confidence: utterance.confidence
            )
        )
    }

    static func normalizedPhrase(_ transcript: String) -> String {
        let folded = transcript
            .folding(
                options: [.diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))

        var result = ""
        var needsSpace = false
        for scalar in folded.unicodeScalars {
            if Self.apostrophes.contains(scalar) {
                continue
            }
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSpace, !result.isEmpty {
                    result.append(" ")
                }
                result.unicodeScalars.append(scalar)
                needsSpace = false
            } else if !result.isEmpty {
                needsSpace = true
            }
        }
        return result
    }

    private func rejection(
        phrase: String,
        confidence: VoiceRecognitionConfidence,
        reason: VoiceIntentRejectionReason,
        recoveryMessage: String
    ) -> VoiceIntentParseResult {
        .rejected(
            VoiceIntentRejection(
                normalizedPhrase: phrase,
                confidence: confidence,
                reason: reason,
                recoveryMessage: recoveryMessage
            )
        )
    }

    private static func isEnglishLocale(_ identifier: String) -> Bool {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return normalized == "en" || normalized.hasPrefix("en-")
    }

    private static func containsMultipleCommands(_ phrase: String) -> Bool {
        var segmented = " \(phrase) "
        for separator in [" and then ", " and ", " then "] {
            segmented = segmented.replacingOccurrences(of: separator, with: "|")
        }
        let parts = segmented
            .split(separator: "|")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.count > 1 && parts.allSatisfy { Self.intentsByPhrase[$0] != nil }
    }

    private static let apostrophes: Set<Unicode.Scalar> = ["'", "’", "ʼ"]

    private static let grammar: [(VoiceIntent, [String])] = [
        (.pause, ["pause", "pause training", "hold on", "wait", "stop"]),
        (.resume, ["resume", "resume training", "continue", "continue training"]),
        (.requestEnd, ["end training", "end session", "finish training", "quit training"]),
        (.confirmEnd, ["confirm end"]),
        (.cancelEnd, ["cancel", "keep training"]),
        (.repeatDemo, ["repeat", "repeat demo", "show demo again", "show that again"]),
        (.slower, ["slower", "slow down", "show it slower"]),
        (.normalPace, ["normal speed", "reset speed"]),
        (.faster, ["faster", "speed up", "show it faster"]),
        (.next, ["next", "next step", "move on"]),
        (.correction, ["what should i fix", "how was that", "what can i improve"]),
        (.guardExplanation, ["why guard", "why keep my hands up"]),
        (.targetHelp, ["where is the target", "how do i hit the target"]),
        (.progress, ["how many reps", "how many punches"]),
        (.help, ["help", "voice commands", "what can i say"]),
        (.score, ["score", "my score", "what is my score", "what was my score", "whats my score"]),
        (.why, ["why", "why that correction", "why did i get that score", "why does that matter"]),
        (.leaderboard, ["leaderboard", "show leaderboard", "show the leaderboard", "where do i rank"]),
        (
            .participantHandoff,
            ["next boxer", "ready for next boxer", "switch participant", "change participant"]
        )
    ]

    private static let intentsByPhrase: [String: Set<VoiceIntent>] = {
        var result: [String: Set<VoiceIntent>] = [:]
        for (intent, aliases) in grammar {
            for alias in aliases {
                result[normalizedPhrase(alias), default: []].insert(intent)
            }
        }
        return result
    }()
}
