import Foundation

/// Fixed spoken scripts for drill milestones (TTS only — no GPT).
enum CoachMilestoneScripts {
    static func text(for milestone: CoachClipID) -> String? {
        switch milestone {
        case .welcome:
            return "Welcome to GhostTrainer. Raise your guard and follow the hologram."
        case .followOut:
            return "Extend your arm and follow the hologram out."
        case .matchExtension:
            return "Match the hologram's extension at the peak."
        case .returnIn:
            return "Bring your hand back in along the path."
        case .backToGuard:
            return "Return to guard. Hands up, chin tucked."
        case .repFaster:
            return "Good. Now try that rep a little faster."
        case .countdown:
            return "Three, two, one, go!"
        case .hitTarget:
            return "Nice hit. Snap back to guard."
        case .scoring:
            return "Hold your guard while we score that rep."
        case .resultsGood:
            return "Strong round. Keep that form on the next rep."
        case .resultsNeedsWork:
            return "Good effort. Focus on extension and getting back to guard."
        case .guardUp:
            return "Keep your hands up. Protect your chin."
        case .calibrateReach:
            return "Extend your arm comfortably. We will measure your reach."
        case .extendOtherArm:
            return "Now extend your other arm the same way."
        case .reachCalibrated:
            return "Reach calibrated. You are ready to train."
        case .didntCatch:
            return "Sorry, I didn't catch that. Hold the button until you see Listening, then try again."
        case .qaWhatFix, .qaWhyGuard, .qaRepeatDemo, .qaSlower, .qaHitTarget,
             .qaThreePunches, .pauseAck, .resumeAck, .helpCommands:
            return nil
        }
    }
}
