import Foundation

/// Builds `CoachVoiceContext` with a live snapshot of on-screen scores and drill state.
@MainActor
enum CoachVoiceContextBuilder {
    static func make(session: ReactiveStrikeSession, selection: TrainingSelection) -> CoachVoiceContext {
        switch selection {
        case .aura(let technique, let stance):
            return CoachVoiceContext(
                feature: .auraPunch,
                auraPhase: session.auraPunch.phase,
                drillPhase: nil,
                techniqueName: technique.name,
                stance: stance,
                reactiveMode: nil,
                combinationName: nil,
                liveSummary: auraLiveSummary(session.auraPunch)
            )

        case .reactive(let mode, let combination, let stance):
            return CoachVoiceContext(
                feature: .reactiveStrike,
                auraPhase: nil,
                drillPhase: session.phase,
                techniqueName: nil,
                stance: stance,
                reactiveMode: mode,
                combinationName: combination?.name,
                liveSummary: reactiveLiveSummary(session, mode: mode)
            )

        case .reachCalibration, .competitionCalibration, .competition:
            return CoachVoiceContext(
                feature: .reactiveStrike,
                auraPhase: nil,
                drillPhase: session.phase,
                techniqueName: nil,
                stance: session.stance,
                reactiveMode: session.mode,
                combinationName: session.selectedCombination.name,
                liveSummary: reactiveLiveSummary(session, mode: session.mode)
            )
        }
    }

    static func makeSetup(
        feature: TrainingFeature,
        stance: Stance,
        reactiveMode: ReactiveStrikeMode? = nil,
        combinationName: String? = nil
    ) -> CoachVoiceContext {
        switch feature {
        case .auraPunch:
            return CoachVoiceContext(
                feature: .auraPunch,
                auraPhase: .idle,
                drillPhase: nil,
                techniqueName: nil,
                stance: stance,
                reactiveMode: nil,
                combinationName: nil,
                liveSummary: nil
            )
        case .reactiveStrike:
            return CoachVoiceContext(
                feature: .reactiveStrike,
                auraPhase: nil,
                drillPhase: .idle,
                techniqueName: nil,
                stance: stance,
                reactiveMode: reactiveMode,
                combinationName: combinationName,
                liveSummary: nil
            )
        }
    }

    // MARK: - Aura Punch

    private static func auraLiveSummary(_ aura: AuraPunchSession) -> String? {
        var parts: [String] = []

        parts.append("Phase: \(aura.phase.rawValue).")
        if !aura.statusMessage.isEmpty, aura.statusMessage != "Ready" {
            parts.append("Status: \(aura.statusMessage).")
        }
        if aura.phase == .attempting, aura.currentScoredPunch > 0 {
            parts.append("Punch \(aura.currentScoredPunch) of \(aura.scoredPunchCount).")
            if aura.liveReach > 0 {
                parts.append(String(format: "Live reach: %.0f%%.", aura.liveReach * 100))
            }
        }
        if aura.coachingHeadline != "GET READY" {
            parts.append("Banner: \(aura.coachingHeadline) — \(aura.coachingDetail).")
        }

        if let score = aura.score {
            parts.append(scoreSummary(score))
        }
        if let feedback = aura.feedback {
            parts.append("Coach feedback headline: \(feedback.headline)")
            parts.append("Primary fix: \(feedback.primaryFix)")
        }

        let summary = parts.joined(separator: " ")
        return summary.isEmpty ? nil : summary
    }

    // MARK: - Reactive Strike

    private static func reactiveLiveSummary(
        _ session: ReactiveStrikeSession,
        mode: ReactiveStrikeMode
    ) -> String? {
        var parts: [String] = []

        parts.append("Drill phase: \(session.phase.rawValue).")
        if session.lastFeedback != "Ready" {
            parts.append("Status: \(session.lastFeedback).")
        }
        parts.append("Progress: \(session.progressLabel).")

        let metrics = session.metrics
        if !metrics.attempts.isEmpty {
            parts.append(
                "Hits \(metrics.hitCount), misses \(metrics.missCount), " +
                String(format: "accuracy %.0f%%.", metrics.accuracy * 100)
            )
            if let reaction = metrics.averageReactionTime {
                parts.append(String(format: "Avg reaction %.0f ms.", reaction * 1000))
            }
            if let speed = metrics.averageEstimatedSpeed {
                parts.append(String(format: "Avg speed %.2f m/s.", speed))
            }
        }

        if mode == .combination, session.phase == .running || session.phase == .finished {
            parts.append(
                "Combinations completed \(session.comboRepsCompleted) of \(session.comboRepeatCount)."
            )
        }

        let summary = parts.joined(separator: " ")
        return summary.isEmpty ? nil : summary
    }

    private static func scoreSummary(_ score: TechniqueScore) -> String {
        var parts = [
            String(format: "Overall score %.0f (%@).", score.overall, score.grade)
        ]
        if let note = score.wrongHandNote {
            parts.append(note)
        }
        let metricLine = score.metrics
            .filter(\.isAvailable)
            .map { metric in
                let value = metric.score.map { String(format: "%.0f", $0) } ?? "n/a"
                return "\(metric.kind.title) \(value)"
            }
            .joined(separator: ", ")
        if !metricLine.isEmpty {
            parts.append("Sub-scores: \(metricLine).")
        }
        if let weakest = score.weakest, let weakestScore = weakest.score {
            parts.append(
                String(format: "Weakest: %@ at %.0f.", weakest.kind.title, weakestScore)
            )
        }
        return parts.joined(separator: " ")
    }
}
