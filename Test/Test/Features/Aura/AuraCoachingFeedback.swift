//
//  AuraCoachingFeedback.swift
//  Test
//
//  Deterministic, offline wording over already-computed hand-only metrics.
//  It never invents measurements, changes scores, or calls a network model.
//

import Foundation

struct AuraCoachingCue: Equatable, Sendable {
    let positive: String
    let focus: String
}

@MainActor
enum AuraCoachingFeedback {
    static func cue(for result: AuraPunchRepetitionResult) -> AuraCoachingCue {
        let strengths: [(score: Double, text: String)] = [
            (result.pathScore, "Your hand stayed close to the guide path."),
            (result.extensionScore, "Your extension matched the calibrated target depth."),
            (result.otherHandGuardScore, "Your other hand stayed close to its guard reference."),
        ]
        let strongest = strengths.max(by: { $0.score < $1.score })
        let positive: String
        if let strongest, strongest.score >= 0.70 {
            positive = strongest.text
        } else {
            positive = "You completed a controlled extension and return."
        }

        let focus: String
        if result.pathScore <= result.extensionScore,
           result.pathScore <= result.otherHandGuardScore {
            focus = "Next set: trace the center of the ghost-glove path with less lateral drift."
        } else if result.extensionScore <= result.otherHandGuardScore {
            focus = result.extensionRatio < 0.90
                ? "Next set: extend smoothly to the target depth, then return without adding speed."
                : "Next set: stop at the target depth and keep the motion controlled."
        } else {
            focus = "Next set: keep the non-punching hand closer to its calibrated guard point."
        }

        return AuraCoachingCue(positive: positive, focus: focus)
    }
}
