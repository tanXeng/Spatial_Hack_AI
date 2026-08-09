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
    case hitTarget = "hit_target"
    case scoring
    case resultsGood = "results_good"
    case resultsNeedsWork = "results_needs_work"
    case guardUp = "guard_up"

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

enum CoachClipLibrary {
    private static let fileExtension = "mp3"
    private static let subdirectories = ["CoachAudio", "Resources/CoachAudio", nil as String?]

    static func url(for id: CoachClipID) -> URL? {
        url(for: id.rawValue)
    }

    static func url(for id: String) -> URL? {
        for subdirectory in subdirectories {
            if let url = Bundle.main.url(
                forResource: id,
                withExtension: fileExtension,
                subdirectory: subdirectory
            ) {
                return url
            }
        }

        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: nil
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == fileExtension else { continue }
            guard fileURL.deletingPathExtension().lastPathComponent == id else { continue }
            return fileURL
        }
        return nil
    }
}
