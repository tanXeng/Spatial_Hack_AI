import Foundation
import simd

nonisolated enum AuraGuidanceAvailability: Equatable, Sendable {
    case ready
    case guardUnavailable
    case trackingUnavailable
}

nonisolated enum AuraGuidanceClockAction: Equatable, Sendable {
    case advance
    case holdForGuard
    case recoverTracking
}

/// Decides whether live Learn/drill time may advance. Guidance needs the current body frame and
/// both fresh physical hands: the spare hand proves guard while the punching hand is the motion
/// being rehearsed. Losing either hand is tracking recovery, never elapsed rehearsal time.
nonisolated enum AuraGuidanceTrackingPolicy {
    static func availability(
        bodyFrameAvailable: Bool,
        punchingHandAvailable: Bool,
        guardHandAvailable: Bool,
        nonPunchingGuardUp: Bool?
    ) -> AuraGuidanceAvailability {
        guard bodyFrameAvailable,
              punchingHandAvailable,
              guardHandAvailable,
              let nonPunchingGuardUp
        else { return .trackingUnavailable }
        return nonPunchingGuardUp ? .ready : .guardUnavailable
    }
}

/// A monotonic active-time clock shared by Learn and corrective drills. Any tracking/guard pause
/// clears the previous tick, so recovery wall time can never leak into animation or hold time.
nonisolated struct AuraGuidanceActiveClock: Sendable {
    private(set) var activeElapsed: TimeInterval = 0
    private var lastReadyTimestamp: TimeInterval?

    mutating func observe(
        at timestamp: TimeInterval,
        availability: AuraGuidanceAvailability
    ) -> AuraGuidanceClockAction {
        guard timestamp.isFinite, timestamp >= 0 else {
            lastReadyTimestamp = nil
            return .recoverTracking
        }

        switch availability {
        case .trackingUnavailable:
            lastReadyTimestamp = nil
            return .recoverTracking
        case .guardUnavailable:
            lastReadyTimestamp = nil
            return .holdForGuard
        case .ready:
            if let previous = lastReadyTimestamp, timestamp >= previous {
                activeElapsed += timestamp - previous
            }
            lastReadyTimestamp = timestamp
            return .advance
        }
    }
}

nonisolated enum CorrectiveDrillStep: String, Equatable, Sendable {
    case trackingRecovery
    case correctHandGuard
    case outbound
    case pathCheckpoint
    case elbowCheckpoint
    case landingHold
    case guardAnchorHold
    case returnToGuard
    case guardHold
    case fullShape
}

/// Deterministic allow-listed behavior and matching copy for the selected correction drill.
nonisolated struct CorrectiveDrillPlan: Equatable, Sendable {
    let drill: CoachCorrectiveDrill
    let headline: String
    let instruction: String
    let steps: [CorrectiveDrillStep]

    init(drill: CoachCorrectiveDrill) {
        self.drill = drill
        switch drill {
        case .trackingRecovery:
            headline = "RECOVER TRACKING"
            instruction = "Hold both closed fists in your fitted guard until tracking is stable."
            steps = [.trackingRecovery]
        case .correctHand:
            headline = "SET THE CORRECT HAND"
            instruction = "Start the required hand in fitted guard, then complete one controlled rep."
            steps = [.correctHandGuard, .outbound, .landingHold, .returnToGuard, .guardHold]
        case .fullExtension:
            headline = "REACH COMFORTABLY"
            instruction = "Travel to your fitted extension and hold without leaning or locking out."
            steps = [.outbound, .landingHold]
        case .straightLine:
            headline = "TRACE ONE LINE"
            instruction = "Send the fist straight out and return on the same cyan line."
            steps = [.outbound, .landingHold, .returnToGuard, .guardHold]
        case .elbowTuck:
            headline = "TUCK THE ELBOW"
            instruction = "Keep the elbow behind the fist while you trace the outbound path."
            steps = [.elbowCheckpoint, .outbound, .landingHold]
        case .guardAnchor:
            headline = "ANCHOR THE GUARD"
            instruction = "Keep the spare hand beside your cheek through the whole punch."
            steps = [.guardAnchorHold, .outbound, .landingHold, .returnToGuard, .guardHold]
        case .snapBack:
            headline = "SNAP BACK"
            instruction = "Start at fitted extension and bring the fist straight back to guard."
            steps = [.landingHold, .returnToGuard, .guardHold]
        case .repeatShape:
            headline = "REPEAT THE SHAPE"
            instruction = "Repeat one balanced guard-to-guard rep at the fitted pace."
            steps = [.fullShape]
        }
    }

    var behaviorSignature: String {
        ([drill.rawValue] + steps.map(\.rawValue)).joined(separator: "|")
    }
}

/// Converts the fitted body-relative guard to the current world frame while retaining the fitted
/// point as the only arming origin. A live fist may prove reacquisition, but cannot redefine it.
nonisolated struct AuraTransferGuardContract: Sendable {
    let calibratedBodyGuard: SIMD3<Float>
    let frame: BodyFrame
    let worldGuard: SIMD3<Float>

    init(calibratedBodyGuard: SIMD3<Float>, frame: BodyFrame) {
        self.calibratedBodyGuard = calibratedBodyGuard
        self.frame = frame
        worldGuard = frame.toWorld(calibratedBodyGuard)
    }

    func isFreshGuard(
        fistWorld: SIMD3<Float>,
        fistState: TrackedFistState
    ) -> Bool {
        fistState == .closed
            && fistWorld.isFinite
            && CombinationPunchValidator.isRetracted(
                fist: frame.toBody(fistWorld),
                guardPosition: calibratedBodyGuard,
                radius: CombinationPunchValidator.guardRadius
            )
    }
}

/// The reducer seam used by live PTT capture. Capture start always destroys partial evidence;
/// capture end stays paused until the live session confirms fresh fitted-guard recovery.
nonisolated enum AuraVoiceCaptureTrainingPolicy {
    static func captureDidBegin(cycle: inout CoachingCycleSession) {
        cycle.trainingDidPause()
    }

    static func guardRecoveryDidComplete(cycle: inout CoachingCycleSession) {
        cycle.trainingDidResume()
    }
}

/// The capture button releases before recognition, command routing, and spoken response finish.
/// This owner keeps that whole interval inside one training pause and ignores stale callbacks.
nonisolated struct CoachVoiceCyclePauseOwner: Sendable {
    nonisolated enum Event: Equatable, Sendable {
        case captureBegan(UUID)
        case captureReleased(UUID)
        case responseCompleted(UUID)
        case responseCancelled(UUID)
        case freshGuardRecovered(UUID)
    }

    nonisolated enum Action: Equatable, Sendable {
        case pauseTraining
        case holdTraining
        case beginFreshGuardRecovery
        case resumeTraining
        case ignore
    }

    private enum State: Sendable {
        case idle
        case capturing(UUID)
        case processing(UUID)
        case awaitingFreshGuard(UUID)
    }

    private var state: State = .idle

    var isTrainingPaused: Bool {
        if case .idle = state { return false }
        return true
    }

    mutating func reset() {
        state = .idle
    }

    mutating func observe(_ event: Event) -> Action {
        switch (state, event) {
        case (.idle, .captureBegan(let id)):
            state = .capturing(id)
            return .pauseTraining
        case (.capturing(let current), .captureReleased(let id)) where current == id:
            state = .processing(id)
            return .holdTraining
        case (.capturing(let current), .responseCompleted(let id)) where current == id,
             (.capturing(let current), .responseCancelled(let id)) where current == id,
             (.processing(let current), .responseCompleted(let id)) where current == id,
             (.processing(let current), .responseCancelled(let id)) where current == id:
            state = .awaitingFreshGuard(id)
            return .beginFreshGuardRecovery
        case (.awaitingFreshGuard(let current), .freshGuardRecovered(let id)) where current == id:
            state = .idle
            return .resumeTraining
        default:
            return .ignore
        }
    }
}

/// Aura deliberately shares the normal combination gate: three consecutive accepted bilateral
/// pairs, all belonging to one provider generation and continuity epoch.
typealias AuraGuardRecoveryGate = NormalCombinationGuardRecoveryGate

nonisolated enum AuraScoringAdmissionPolicy {
    static func scorerRejectedAttempt(cycle: inout CoachingCycleSession) {
        cycle.rejectPartialAttempt(.invalidEvidence)
    }
}

enum AuraImmersiveInstructionPolicy {
    static func instruction(
        phase: AuraPunchPhase,
        coachingHeadline: String,
        coachingDetail: String,
        cyclePresentation: CoachingCyclePresentation,
        trackingPaused: Bool,
        trainingPaused: Bool,
        statusMessage: String
    ) -> ImmersiveInstruction {
        if trackingPaused {
            return ImmersiveInstruction(
                stage: "TRACKING PAUSED",
                message: coachingDetail.isEmpty
                    ? "Hold both closed fists in guard and look forward"
                    : coachingDetail,
                symbol: "pause.circle.fill",
                action: "Recover tracking",
                progress: cyclePresentation.progress
            )
        }

        if trainingPaused {
            return ImmersiveInstruction(
                stage: coachingHeadline.isEmpty ? "TRAINING PAUSED" : coachingHeadline,
                message: coachingDetail.isEmpty ? statusMessage : coachingDetail,
                symbol: "pause.circle.fill",
                action: "Resume after guard",
                progress: cyclePresentation.progress
            )
        }

        switch phase {
        case .idle:
            if statusMessage == "Stopped" {
                return ImmersiveInstruction(
                    stage: "TRAINING STOPPED",
                    message: "Your training was stopped",
                    symbol: "stop.circle.fill"
                )
            }
            return ImmersiveInstruction(
                stage: "GET READY",
                message: coachingDetail,
                symbol: "figure.boxing"
            )
        case .acquiring:
            return ImmersiveInstruction(
                stage: coachingHeadline,
                message: coachingDetail,
                symbol: coachingHeadline.contains("FIT") ? "ruler" : "hand.raised.fill",
                action: cyclePresentation.action,
                progress: cyclePresentation.progress,
                metric: cyclePresentation.metric
            )
        case .guiding, .countdown, .attempting, .scoring:
            return ImmersiveInstruction(
                stage: cyclePresentation.stage,
                message: coachingDetail,
                symbol: symbol(for: cyclePresentation.stage),
                action: cyclePresentation.action,
                progress: cyclePresentation.progress,
                metric: cyclePresentation.metric
            )
        case .results:
            return ImmersiveInstruction(
                stage: "COMPLETE",
                message: coachingDetail.isEmpty ? "Your results are ready" : coachingDetail,
                symbol: "checkmark.circle.fill",
                action: cyclePresentation.action,
                metric: cyclePresentation.metric
            )
        }
    }

    private static func symbol(for stage: String) -> String {
        if stage.contains("WATCH") { return "eye.fill" }
        if stage.contains("CORRECTION") || stage.contains("DRILL") { return "scope" }
        if stage.contains("PROOF") || stage.contains("COMPLETE") {
            return "chart.line.uptrend.xyaxis"
        }
        if stage.contains("FIT") { return "ruler" }
        return "figure.boxing"
    }
}

extension ImmersiveInstruction {
    var accessibilityValue: String {
        [message, progress, metric, action]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}
