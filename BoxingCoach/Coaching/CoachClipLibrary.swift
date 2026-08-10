import Foundation

/// Milestone identifiers for live TTS coach speech.
enum CoachClipID: String, CaseIterable, Sendable {
    case welcome
    case followOut = "follow_out"
    case matchExtension = "match_extension"
    case returnIn = "return_in"
    case backToGuard = "back_to_guard"
    case repFaster = "rep_faster"
    case countdown
    case hitTarget = "hit_target"
    case scoring
    case resultsGood = "results_good"
    case resultsNeedsWork = "results_needs_work"
    case guardUp = "guard_up"
    case calibrateReach = "calibrate_reach"
    case extendOtherArm = "extend_other_arm"
    case reachCalibrated = "reach_calibrated"
    case qaWhatFix = "qa_what_fix"
    case qaWhyGuard = "qa_why_guard"
    case qaRepeatDemo = "qa_repeat_demo"
    case qaSlower = "qa_slower"
    case qaHitTarget = "qa_hit_target"
    case qaThreePunches = "qa_three_punches"
    case pauseAck = "pause_ack"
    case resumeAck = "resume_ack"
    case helpCommands = "help_commands"
    case didntCatch = "didnt_catch"
}
