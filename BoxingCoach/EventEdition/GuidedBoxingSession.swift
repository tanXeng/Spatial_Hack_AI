import Foundation

nonisolated enum TrackingPauseReason: String, Codable, Sendable, Equatable {
    case requiredSampleStale
    case requiredJointsUnavailable
    case timestampInvalid
    case providerStopped
    case permissionChanged
    case spatialDiscontinuity

    var message: String {
        switch self {
        case .requiredSampleStale: "A required tracking sample was more than 100 milliseconds old."
        case .requiredJointsUnavailable: "The required hand joints are not visible."
        case .timestampInvalid: "Tracking timestamps repeated or moved backwards."
        case .providerStopped: "Hand tracking stopped."
        case .permissionChanged: "Hand tracking permission changed."
        case .spatialDiscontinuity: "Tracking moved farther than a plausible controlled motion."
        }
    }
}

nonisolated enum SessionFailure: String, Codable, Sendable, Equatable {
    case unsupported
    case permissionDenied
    case providerFailed
    case calibrationUnavailable
    case technicalDiscardLimit
    case persistenceFailed
}

nonisolated enum GuidedStage: Sendable, Equatable {
    case idle
    case acquiringTracking
    case calibratingOpenHands
    case calibratingFists
    case calibratingGuard
    case calibratingReach(side: BodySide)
    case jabWatch
    case jabFollow(rep: Int)
    case jabBaseline
    case jabCorrection
    case jabRetest
    case crossWatch
    case crossFollow(rep: Int)
    case crossBaseline
    case crossCorrection
    case crossRetest
    case oneTwoPractice(rep: Int)
    case challenge(rep: Int, punch: PunchType)
    case paused(TrackingPauseReason)
    case saving
    case completed(runID: UUID)
    case failed(SessionFailure)
}

/// Event-level state layered above the existing tracking and drill engines. It serializes the
/// participant flow without creating a second ARKit session or doing work in a SwiftUI body.
@Observable
@MainActor
final class GuidedBoxingSession {
    private(set) var stage: GuidedStage = .idle
    private(set) var plan: TrainingPlan?
    private(set) var technicalDiscardCount = 0
    private(set) var readyToResume = false
    private(set) var instruction = "Ready"
    private var stageBeforePause: GuidedStage?
    private var stableEvidenceStartedAt: TimeInterval?

    func start(plan: TrainingPlan) {
        self.plan = plan
        technicalDiscardCount = 0
        readyToResume = false
        stableEvidenceStartedAt = nil
        stage = .acquiringTracking
        instruction = "Stand comfortably and look forward."
    }

    func advanceCalibration(withFreshEvidenceAt timestamp: TimeInterval) {
        guard timestamp.isFinite else { pause(.timestampInvalid); return }
        if stableEvidenceStartedAt == nil { stableEvidenceStartedAt = timestamp }
        guard let start = stableEvidenceStartedAt, timestamp >= start else {
            pause(.timestampInvalid)
            return
        }
        guard timestamp - start >= 0.5 else { return }
        stableEvidenceStartedAt = nil

        switch stage {
        case .acquiringTracking:
            stage = .calibratingOpenHands
            instruction = "Hold both open hands beside your face."
        case .calibratingOpenHands:
            stage = .calibratingFists
            instruction = "Close both hands gently. Do not squeeze."
        case .calibratingFists:
            stage = .calibratingGuard
            instruction = "Hold your normal guard until both rings fill."
        case .calibratingGuard:
            stage = .calibratingReach(side: .left)
            instruction = "Slowly extend your left fist only as far as comfortable."
        case .calibratingReach(side: .left):
            stage = .calibratingReach(side: .right)
            instruction = "Slowly extend your right fist only as far as comfortable."
        case .calibratingReach(side: .right):
            beginPlan()
        default:
            break
        }
    }

    func pause(_ reason: TrackingPauseReason) {
        guard case .paused = stage else {
            stageBeforePause = stage
            stage = .paused(reason)
            readyToResume = false
            stableEvidenceStartedAt = nil
            technicalDiscardCount += 1
            instruction = "That attempt was not scored. Hold both hands in guard and look forward."
            if technicalDiscardCount >= 3, plan == .controlledOneTwoOfficial {
                stage = .failed(.technicalDiscardLimit)
                instruction = "Tracking could not stabilize. This attempt did not count."
            }
            return
        }
    }

    func noteRecoveryEvidence(at timestamp: TimeInterval, bothHandsInGuard: Bool) {
        guard case .paused = stage, bothHandsInGuard, timestamp.isFinite else {
            stableEvidenceStartedAt = nil
            readyToResume = false
            return
        }
        if stableEvidenceStartedAt == nil { stableEvidenceStartedAt = timestamp }
        guard let start = stableEvidenceStartedAt, timestamp >= start else {
            pause(.timestampInvalid)
            return
        }
        readyToResume = timestamp - start >= 0.5
        if readyToResume { instruction = "Ready to resume. No score was lost." }
    }

    func resume() {
        guard case .paused = stage, readyToResume, let prior = stageBeforePause else { return }
        stage = prior
        stageBeforePause = nil
        stableEvidenceStartedAt = nil
        readyToResume = false
        instruction = "3… 2… 1…"
    }

    func beginSaving() { stage = .saving; instruction = "Saving Your Session…" }
    func complete(runID: UUID) { stage = .completed(runID: runID); instruction = "Session Saved" }
    func fail(_ failure: SessionFailure) { stage = .failed(failure) }

    func transition(to stage: GuidedStage, instruction: String) {
        self.stage = stage
        self.instruction = instruction
    }

    func reset() {
        stage = .idle
        plan = nil
        technicalDiscardCount = 0
        readyToResume = false
        stageBeforePause = nil
        stableEvidenceStartedAt = nil
        instruction = "Ready"
    }

    private func beginPlan() {
        switch plan {
        case .guidedCore, .observeOnly:
            stage = .jabWatch
            instruction = "Watch the lead hand travel straight out and back."
        case .controlledOneTwoOfficial, .controlledOneTwoPractice:
            stage = .challenge(rep: 1, punch: .jab)
            instruction = "Jab, return; cross, return."
        case .experimental:
            stage = .oneTwoPractice(rep: 1)
            instruction = "Practice a controlled 1–2."
        case nil:
            stage = .failed(.calibrationUnavailable)
        }
    }
}
