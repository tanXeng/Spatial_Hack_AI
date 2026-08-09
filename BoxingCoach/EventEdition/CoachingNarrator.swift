import Foundation
import FoundationModels

nonisolated struct CoachingFactSet: Sendable, Equatable {
    let correctionID: String
    let evidence: String
    let confidence: Float
    let approvedVocabulary: [String]
    let deterministicFallback: String
}

nonisolated struct CoachingNarration: Sendable, Equatable {
    enum Source: String, Sendable { case onDevice, deterministic }
    let correctionID: String
    let sentence: String
    let source: Source
}

protocol CoachingNarrator: Sendable {
    func narrate(_ facts: CoachingFactSet) async -> CoachingNarration
}

nonisolated struct DeterministicNarrator: CoachingNarrator {
    func narrate(_ facts: CoachingFactSet) async -> CoachingNarration {
        CoachingNarration(
            correctionID: facts.correctionID,
            sentence: facts.deterministicFallback,
            source: .deterministic
        )
    }
}

/// Constrains an optional on-device model to wording only. The correction and evidence are fixed
/// first; timeout, refusal, unsupported claims, or malformed output always return the same local
/// deterministic sentence and can never alter scoring or ranking facts.
nonisolated struct ConstrainedCoachingNarrator: CoachingNarrator {
    typealias Generator = @Sendable (String) async throws -> String

    private let generator: Generator
    private let timeout: Duration
    private let fallback = DeterministicNarrator()

    init(timeout: Duration = .seconds(2), generator: @escaping Generator) {
        self.timeout = timeout
        self.generator = generator
    }

    static var live: ConstrainedCoachingNarrator {
        ConstrainedCoachingNarrator { prompt in
            guard SystemLanguageModel.default.isAvailable else { throw NarrationError.unavailable }
            let session = LanguageModelSession(
                instructions: "Rewrite only the supplied correction. Return CORRECTION_ID|one short sentence. Add no numbers, scores, body claims, or second correction."
            )
            return try await session.respond(to: prompt).content
        }
    }

    func narrate(_ facts: CoachingFactSet) async -> CoachingNarration {
        do {
            let output = try await generateWithTimeout(prompt(for: facts))
            guard let sentence = validate(output, facts: facts) else {
                return await fallback.narrate(facts)
            }
            return CoachingNarration(
                correctionID: facts.correctionID,
                sentence: sentence,
                source: .onDevice
            )
        } catch {
            return await fallback.narrate(facts)
        }
    }

    private func prompt(for facts: CoachingFactSet) -> String {
        """
        CORRECTION_ID: \(facts.correctionID)
        EVIDENCE: \(facts.evidence)
        CONFIDENCE: \(facts.confidence)
        APPROVED_WORDS: \(facts.approvedVocabulary.joined(separator: ", "))
        REQUIRED_MEANING: \(facts.deterministicFallback)
        """
    }

    private func generateWithTimeout(_ prompt: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await generator(prompt) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NarrationError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw NarrationError.unavailable }
            return first
        }
    }

    private func validate(_ output: String, facts: CoachingFactSet) -> String? {
        let parts = output.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == facts.correctionID
        else { return nil }
        let sentence = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty,
              sentence.count <= 140,
              !sentence.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains),
              sentence.filter({ ".!?".contains($0) }).count <= 1
        else { return nil }
        let lower = sentence.lowercased()
        let forbidden = ["power", "force", "hip", "torso", "feet", "rank", "score", "speed"]
        guard !forbidden.contains(where: lower.contains) else { return nil }
        return sentence
    }

    enum NarrationError: Error { case unavailable, timedOut }
}

