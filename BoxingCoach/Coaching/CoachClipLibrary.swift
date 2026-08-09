import Foundation

/// Identifiers for pre-recorded coach clips in `CoachAudio/`.
enum CoachClipID: String, CaseIterable, Sendable {
    case welcome
    case followOut = "follow_out"
    case matchExtension = "match_extension"
    case returnIn = "return_in"
    case backToGuard = "back_to_guard"
    case repFaster = "rep_faster"
    case countdown
    // Per-impact feedback uses an original short transient, not the legacy spoken prompt.
    case hitTarget = "clean_hit_1"
    case scoring
    case resultsGood = "results_good"
    case resultsNeedsWork = "results_needs_work"
    case guardUp = "guard_up"
    case calibrateReach = "calibrate_reach"
    case extendOtherArm = "extend_other_arm"
    case reachCalibrated = "reach_calibrated"

    // Phase 2 — voice Q&A (catalogued now, not auto-played in Phase 1).
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

/// Original, non-verbal sonic-ring resources used by the training-audio coordinator.
enum SonicRingSoundID: String, CaseIterable, Sendable {
    case calibrateReach = "calibrate_reach"
    case extendOtherArm = "extend_other_arm"
    case reachCalibrated = "reach_calibrated"
    case gymAmbienceLoop = "gym_ambience_loop"
    case competitionCrowdLowLoop = "competition_crowd_low_loop"
    case bellStart = "bell_start"
    case bellEnd = "bell_end"
    case cleanHitOne = "clean_hit_1"
    case cleanHitTwo = "clean_hit_2"
    case cleanHitThree = "clean_hit_3"
    case rejectedHit = "rejected_hit"
    case trackingLost = "tracking_lost"
    case trackingRestored = "tracking_restored"
    case improvementSting = "improvement_sting"
    case winnerSwell = "winner_swell"
}

struct CoachClipLibrary: TrainingAudioResourceResolving {
    private static let fileExtensions = ["mp3", "m4a", "wav", "caf", "aac"]
    private static let subdirectories = ["CoachAudio", "Resources/CoachAudio", nil as String?]

    func url(for resource: TrainingAudioResourceID) -> URL? {
        Self.url(for: resource)
    }

    static func url(for resource: TrainingAudioResourceID) -> URL? {
        url(for: resource.fileName)
    }

    static func url(for id: CoachClipID) -> URL? {
        url(for: id.rawValue)
    }

    static func url(for id: SonicRingSoundID) -> URL? {
        url(for: id.rawValue)
    }

    static func url(for id: String) -> URL? {
        for fileExtension in fileExtensions {
            for subdirectory in subdirectories {
                if let url = Bundle.main.url(
                    forResource: id,
                    withExtension: fileExtension,
                    subdirectory: subdirectory
                ) {
                    return url
                }
            }
        }

        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: nil
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            guard fileURL.deletingPathExtension().lastPathComponent == id else { continue }
            return fileURL
        }
        return nil
    }
}
