import Foundation

/// Product knowledge injected into the live ChatGPT coach so answers reference this app.
nonisolated enum CoachAppGuide {
    static let overview: String = """
    Boxing Coach is an Apple Vision Pro app. Training happens in immersive space with hand tracking — \
    not generic "at home" shadowboxing unless the user explicitly asks about off-headset practice.

    MAIN MODES (home screen):
    • Aura Punch — follow a spatial hologram through a full punch path. Best for learning technique \
    (Jab, Cross, Hook, Uppercut). Pick technique + Orthodox/Southpaw, start training, raise guard until \
    tracking locks, then mirror the hologram: extend out, match peak extension, return along the path, \
    snap back to guard. Includes countdown, scored reps, and on-screen form feedback.
    • Reactive Strike — hit floating orange targets on reaction. Air Mode: one target at a time. \
    Combination Mode: numbered combos (e.g. Jab-Cross 1-2, Double Jab-Cross 1-1-2). Reach calibration \
    measures both arms first. Only the correct hand advances the combo; wrong-hand contact ends the rep.

    VOICE COACH: Hold "Ask Coach", wait for Listening, speak, release. Answers are generated live by ChatGPT.

    TRACKING LIMITS: Hands + headset pose only. Shoulders are estimated. Cannot see feet, hip rotation, \
    or punch power. Coach about what the app can see: guard height, extension path, elbow angle, retraction.

    HOW TO PRACTICE A JAB IN THIS APP:
    1. Home → Aura Punch → Jab → choose stance → Start Training.
    2. In immersive space, raise guard until coaching audio plays.
    3. Follow the hologram's lead-hand straight punch: extend from guard, match extension, retract to guard.
    For reaction work: Reactive Strike → Air Mode or a combo that starts with a jab (e.g. Jab-Cross).
    """

    /// Shorter app summary for the live voice coach prompt (less latency + tokens).
    static let compactOverview: String = """
    Boxing Coach on Vision Pro. Aura Punch = follow hologram for Jab/Cross/Hook/Uppercut. \
    Reactive Strike = hit orange targets (Air or Combination mode). Hold Ask Coach to talk. \
    Jab practice: Home → Aura Punch → Jab → raise guard → mirror hologram. No feet/hip tracking.
    """

    static func sessionContext(for context: CoachVoiceContext) -> String {
        var lines: [String] = []

        switch context.feature {
        case .auraPunch:
            lines.append("Active mode: Aura Punch (hologram follow-along).")
            if let phase = context.auraPhase {
                lines.append("Aura phase: \(phase.rawValue).")
            }
            if let technique = context.techniqueName {
                lines.append("Selected technique: \(technique).")
                if let guidance = techniqueGuidance(named: technique) {
                    lines.append(guidance)
                }
            }
        case .reactiveStrike:
            lines.append("Active mode: Reactive Strike (reaction targets).")
            if let phase = context.drillPhase {
                lines.append("Drill phase: \(phase.rawValue).")
            }
            if let mode = context.reactiveMode {
                lines.append("Reactive sub-mode: \(mode.title) — \(mode.subtitle).")
            }
            if let combo = context.combinationName {
                lines.append("Selected combination: \(combo).")
            }
        }

        if let stance = context.stance {
            lines.append("Stance: \(stance.rawValue).")
        }

        if lines.isEmpty {
            return "User is on the home/setup screen (not in an active drill)."
        }
        return lines.joined(separator: " ")
    }

    static func techniqueGuidance(named name: String) -> String? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let technique = Technique.all.first(where: {
            $0.id == normalized || $0.name.lowercased() == normalized
        }) else { return nil }

        let cues = technique.coachingCues.joined(separator: "; ")
        return "\(technique.name) in-app cues: \(technique.summary) Focus on: \(cues)."
    }
}
