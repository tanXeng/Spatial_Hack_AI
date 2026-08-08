//
//  RoundEngine.swift
//  Test
//
//  Owns calibration, deterministic cue timing, hit evaluation, safe pause,
//  and non-clinical session metrics.
//

import Foundation
import Observation
import simd

enum RoundPhase: Equatable, Sendable {
    case setup
    case calibratingGuard(progress: Double)
    case awaitingReach
    case calibratingReach(progress: Double)
    case ready
    case countdown(seconds: Int)
    case running
    case pausedForTracking
    case failed(message: String)
    case finished

    var title: String {
        switch self {
        case .setup:
            "Set up your guard"
        case .calibratingGuard:
            "Hold guard"
        case .awaitingReach:
            "Reach calibration"
        case .calibratingReach:
            "Extend one straight punch"
        case .ready:
            "Ready for the round"
        case .countdown:
            "Starting"
        case .running:
            "Round in progress"
        case .pausedForTracking:
            "Paused for tracking"
        case .failed:
            "Drill unavailable"
        case .finished:
            "Round complete"
        }
    }
}

enum MittVisualState: Equatable, Sendable {
    case inactive
    case active
    case hit
    case miss
    case paused
}

enum RoundFeedback: Equatable, Sendable {
    case neutral
    case hit(PunchKind)
    case miss(PunchKind)
    case wrong(expected: PunchKind)
    case paused

    var text: String? {
        switch self {
        case .neutral:
            nil
        case .hit(let punch):
            "\(punch.title) hit"
        case .miss(let punch):
            "\(punch.title) missed"
        case .wrong(let expected):
            "Use your \(expected.rawValue) hand"
        case .paused:
            "Return both hands to guard"
        }
    }
}

@MainActor
@Observable
final class RoundEngine {
    private struct BoardTargetSpec: Sendable {
        let punch: PunchKind
        let lateralOffset: Float
        let verticalOffset: Float
    }

    /// A compact six-pad board that remains inside the measured forward reach
    /// envelope. Logical cue centers, not the rendered pads, remain scoring
    /// truth.
    private static let boardPattern: [BoardTargetSpec] = [
        BoardTargetSpec(punch: .jab, lateralOffset: -0.09, verticalOffset: 0.08),
        BoardTargetSpec(punch: .cross, lateralOffset: 0.09, verticalOffset: 0.08),
        BoardTargetSpec(punch: .jab, lateralOffset: -0.12, verticalOffset: -0.04),
        BoardTargetSpec(punch: .cross, lateralOffset: 0.12, verticalOffset: -0.04),
        BoardTargetSpec(punch: .jab, lateralOffset: -0.03, verticalOffset: 0.15),
        BoardTargetSpec(punch: .cross, lateralOffset: 0.03, verticalOffset: -0.13),
    ]

    private struct PendingGuardReturn {
        let attemptID: UUID
        let eventAt: TimeInterval
        let deadline: TimeInterval
    }

    private struct ReachMeasurement {
        let delta: SIMD3<Float>
        let distance: Float
    }

    private struct ReachRepetition {
        let hand: HandSide
        let measurement: ReachMeasurement
        let peakSpeed: Float
    }

    private enum ReachCycleState {
        case waitingForGuard
        case armed
        case extending(hand: HandSide)
    }

    let configuration: DrillConfiguration

    var selectedStance: Stance = .orthodox
    private(set) var phase: RoundPhase = .setup
    private(set) var instruction = "Enter the mixed space, raise both hands, then calibrate."
    private(set) var validationMessage: String?
    private(set) var trackingAvailable = false
    private(set) var calibration: CalibrationProfile?
    private(set) var activeCue: TargetCue?
    private(set) var cueIsVisuallyActive = false
    private(set) var feedback: RoundFeedback = .neutral
    private(set) var remainingTime: TimeInterval
    private(set) var attempts: [AttemptResult] = []
    private(set) var summary: RoundSummary?
    private(set) var lastResolvedBoardIndex: Int?
    private(set) var jabTargetPosition = SIMD3<Float>(-0.16, 1.35, -0.82)
    private(set) var crossTargetPosition = SIMD3<Float>(0.16, 1.35, -0.82)
    private(set) var activeDifficulty: TrainingDifficulty = .defaultValue
    private(set) var functionalCalibrationReports: [
        HandSide: FunctionalCalibrationReport
    ] = [:]

    @ObservationIgnored private var guardStartedAt: TimeInterval?
    @ObservationIgnored private var guardLeftSum = SIMD3<Float>.zero
    @ObservationIgnored private var guardRightSum = SIMD3<Float>.zero
    @ObservationIgnored private var guardSampleCount = 0
    @ObservationIgnored private var previousGuardSample: HandSample?
    @ObservationIgnored private var draftLeftGuard: SIMD3<Float>?
    @ObservationIgnored private var draftRightGuard: SIMD3<Float>?
    @ObservationIgnored private let functionalCalibrationThresholds =
        FunctionalCalibrationThresholds.provisional
    @ObservationIgnored private var reachCycleStartedAt: TimeInterval?
    @ObservationIgnored private var reachCycleState = ReachCycleState.waitingForGuard
    @ObservationIgnored private var reachPairHand: HandSide?
    @ObservationIgnored private var reachCycleMeasurement: ReachMeasurement?
    @ObservationIgnored private var reachCyclePeakSpeed: Float = 0
    @ObservationIgnored private var reachRepetitions: [
        HandSide: [ReachRepetition]
    ] = [:]
    @ObservationIgnored private var previousReachSample: HandSample?
    @ObservationIgnored private var detector: PunchDetector?
    @ObservationIgnored private var roundTask: Task<Void, Never>?
    @ObservationIgnored private var countdownEndsAt: TimeInterval?
    @ObservationIgnored private var lastTickAt: TimeInterval?
    @ObservationIgnored private var nextCueAt: TimeInterval?
    @ObservationIgnored private var nextSequenceIndex = 0
    @ObservationIgnored private var pendingGuardReturns: [HandSide: PendingGuardReturn] = [:]
    @ObservationIgnored private var pausedStartedAt: TimeInterval?
    @ObservationIgnored private var totalPausedDuration: TimeInterval = 0
    @ObservationIgnored private var resumeGuardStartedAt: TimeInterval?
    @ObservationIgnored private var resumeRestartsCountdown = false
    @ObservationIgnored private var cancelledCueCount = 0
    @ObservationIgnored private var trackingInterruptionCount = 0
    @ObservationIgnored private var systemInterrupted = false
    @ObservationIgnored private var lastAcceptedSampleTimestamp: TimeInterval?

    init(configuration: DrillConfiguration? = nil) {
        let resolvedConfiguration = configuration ?? .provisional
        self.configuration = resolvedConfiguration
        remainingTime = resolvedConfiguration.roundDuration
    }

    var isCalibrated: Bool {
        calibration != nil
    }

    var canCalibrateGuard: Bool {
        trackingAvailable && phase == .setup
    }

    var canStartRound: Bool {
        trackingAvailable && phase == .ready && calibration != nil
    }

    var isRoundActive: Bool {
        switch phase {
        case .countdown, .running, .pausedForTracking:
            true
        default:
            false
        }
    }

    var boardTargetCount: Int { Self.boardPattern.count }

    var completedReachRepetitionCount: Int {
        HandSide.allCases.reduce(0) {
            $0 + (functionalCalibrationReports[$1]?.captureCount ?? 0)
        }
    }

    var requiredReachRepetitionCount: Int {
        functionalCalibrationThresholds.requiredRepetitionCount
            * HandSide.allCases.count
    }

    func functionalCalibrationReport(
        for hand: HandSide
    ) -> FunctionalCalibrationReport? {
        functionalCalibrationReports[hand]
    }

    func completedReachRepetitionCount(for hand: HandSide) -> Int {
        functionalCalibrationReports[hand]?.captureCount ?? 0
    }

    /// The only live-reach scalar eligible for profile persistence. It is the
    /// minimum uncapped accepted reach across both independently graded hands.
    var conservativeBilateralProfileReachMeters: Float? {
        guard let left = functionalCalibrationReports[.left],
              left.grade.isAccepted,
              let leftReach = left.conservativeReachMeters,
              let right = functionalCalibrationReports[.right],
              right.grade.isAccepted,
              let rightReach = right.conservativeReachMeters else {
            return nil
        }
        return min(leftReach, rightReach)
    }

    func setTrackingState(_ state: HandTrackingState) {
        switch state {
        case .denied:
            failForTracking("Hand tracking permission was denied. Exit, enable permission, and re-enter.")
            return
        case .unsupported:
            failForTracking("This device does not support the required hand tracking.")
            return
        case .failed(let message):
            failForTracking(message)
            return
        case .simulatorUnavailable:
            trackingAvailable = false
            validationMessage = "Live calibration and the drill require Apple Vision Pro."
            return
        default:
            break
        }

        let wasAvailable = trackingAvailable
        trackingAvailable = state.hasBothHands

        if wasAvailable,
           !trackingAvailable,
           isRoundActive,
           phase != .pausedForTracking {
            pauseForTracking(at: ProcessInfo.processInfo.systemUptime)
        }

        if !trackingAvailable {
            resumeGuardStartedAt = nil
        }
    }

    func pauseForSystemInterruption() {
        guard !systemInterrupted else { return }
        systemInterrupted = true
        trackingAvailable = false

        switch phase {
        case .calibratingGuard:
            resetGuardCapture()
            phase = .setup
            validationMessage = "Guard calibration was cancelled by a system interruption."
            instruction = "When active, make both hands visible and start guard calibration again."
            return
        case .calibratingReach:
            resetReachCapture()
            phase = .awaitingReach
            validationMessage = "Reach calibration was cancelled by a system interruption."
            instruction = "When active, start a fresh reach capture."
            return
        case .awaitingReach:
            resetCalibration()
            validationMessage = "Calibration was cancelled by a system interruption."
            instruction = "When active, start guard calibration again."
            return
        default:
            break
        }

        guard isRoundActive else { return }

        if phase != .pausedForTracking {
            pauseForTracking(
                at: ProcessInfo.processInfo.systemUptime
            )
        } else {
            resumeGuardStartedAt = nil
        }
        instruction = "Paused for a system interruption. Return both hands to guard when active."
    }

    func resumeFromSystemInterruption() {
        systemInterrupted = false
        resumeGuardStartedAt = nil
        if phase == .pausedForTracking {
            instruction = "System active. Make both hands visible and hold the calibrated guard to resume."
        }
    }

    func setStance(_ stance: Stance) {
        guard !isRoundActive, phase != .finished else { return }
        selectedStance = stance
        resetCalibration()
    }

    func startGuardCalibration() {
        guard trackingAvailable else {
            validationMessage = "Both hands must be tracked before calibration."
            return
        }
        guard phase == .setup else { return }

        validationMessage = nil
        resetGuardCapture()
        phase = .calibratingGuard(progress: 0)
        instruction = "Hold a comfortable boxing guard still for two seconds."
    }

    func startReachCalibration() {
        guard phase == .awaitingReach else { return }
        guard trackingAvailable else {
            validationMessage = "Both hands must be tracked before reach calibration."
            return
        }

        validationMessage = nil
        let failedHands = HandSide.allCases.filter {
            functionalCalibrationReports[$0]?.grade == .freshCaptureNeeded
        }
        if failedHands.isEmpty {
            resetReachCapture()
        } else {
            resetCurrentReachCycle(previous: nil)
            for hand in failedHands {
                reachRepetitions[hand] = []
                functionalCalibrationReports[hand] = emptyFunctionalReport()
            }
            reachPairHand = failedHands.first
        }
        for hand in HandSide.allCases
        where functionalCalibrationReports[hand] == nil {
            functionalCalibrationReports[hand] = emptyFunctionalReport()
        }
        if let acceptedHand = HandSide.allCases.first(where: {
            functionalCalibrationReports[$0]?.grade == .consistent
        }) {
            reachPairHand = acceptedHand == .left ? .right : .left
        }
        updateReachProgress(cycleFraction: 0)
        instruction = "Begin with both fists in guard. Complete two controlled extensions and returns with each hand."
    }

    func startRound(difficulty: TrainingDifficulty = .defaultValue) {
        guard canStartRound else {
            validationMessage = "Complete calibration and track both hands before starting."
            return
        }

        validationMessage = nil
        activeDifficulty = difficulty
        attempts = []
        summary = nil
        feedback = .neutral
        remainingTime = configuration.roundDuration
        activeCue = nil
        cueIsVisuallyActive = false
        lastResolvedBoardIndex = nil
        nextSequenceIndex = 0
        pendingGuardReturns = [:]
        totalPausedDuration = 0
        cancelledCueCount = 0
        trackingInterruptionCount = 0
        pausedStartedAt = nil
        resumeGuardStartedAt = nil
        resumeRestartsCountdown = false
        detector = calibration.map {
            PunchDetector(calibration: $0, configuration: configuration)
        }

        let now = ProcessInfo.processInfo.systemUptime
        countdownEndsAt = now + configuration.countdownDuration
        lastTickAt = now
        phase = .countdown(seconds: Int(ceil(configuration.countdownDuration)))
        instruction = "Bring both hands to guard. The first mitt will light up after the countdown."
        startRoundClock()
    }

    func prepareAnotherRound() {
        guard phase == .finished else { return }
        summary = nil
        attempts = []
        feedback = .neutral
        cancelledCueCount = 0
        trackingInterruptionCount = 0
        cueIsVisuallyActive = false
        lastResolvedBoardIndex = nil
        remainingTime = configuration.roundDuration
        phase = calibration == nil ? .setup : .ready
        instruction = calibration == nil
            ? "Calibrate your guard and reach."
            : "Calibration is retained. Start when your area is still clear."
    }

    func stop() {
        roundTask?.cancel()
        roundTask = nil
        activeCue = nil
        cueIsVisuallyActive = false
        lastResolvedBoardIndex = nil
        feedback = .neutral
        pendingGuardReturns = [:]
        pausedStartedAt = nil
        resumeGuardStartedAt = nil
        remainingTime = configuration.roundDuration
        validationMessage = nil

        if calibration == nil {
            resetReachCapture()
            phase = .setup
            instruction = "Enter the mixed space, raise both hands, then calibrate."
        } else {
            phase = .ready
            instruction = "The round stopped safely. Start again when ready."
        }
    }

    /// Tears down world-space state whenever the immersive scene closes.
    /// Finished results can survive so they are reviewed safely in the window;
    /// calibration never survives because a new space has a new origin.
    func leaveImmersiveSpace() {
        let preserveResults = summary != nil

        roundTask?.cancel()
        roundTask = nil
        trackingAvailable = false
        activeCue = nil
        cueIsVisuallyActive = false
        lastResolvedBoardIndex = nil
        pendingGuardReturns = [:]
        pausedStartedAt = nil
        resumeGuardStartedAt = nil
        detector = nil
        calibration = nil
        draftLeftGuard = nil
        draftRightGuard = nil
        resetGuardCapture()
        resetReachCapture()
        jabTargetPosition = SIMD3<Float>(-0.16, 1.35, -0.82)
        crossTargetPosition = SIMD3<Float>(0.16, 1.35, -0.82)

        if preserveResults {
            remainingTime = 0
            feedback = .neutral
            phase = .finished
            validationMessage = nil
            instruction = "Training space closed. Review the relative drill metrics below."
        } else {
            summary = nil
            attempts = []
            remainingTime = configuration.roundDuration
            feedback = .neutral
            phase = .setup
            validationMessage = nil
            instruction = "Enter the mixed space, raise both hands, then calibrate."
        }
    }

    func resetCalibration() {
        guard !isRoundActive, phase != .finished else { return }
        roundTask?.cancel()
        roundTask = nil
        calibration = nil
        detector = nil
        summary = nil
        attempts = []
        activeCue = nil
        cueIsVisuallyActive = false
        lastResolvedBoardIndex = nil
        feedback = .neutral
        remainingTime = configuration.roundDuration
        phase = .setup
        instruction = "Raise both hands, then hold a comfortable guard for calibration."
        validationMessage = nil
        draftLeftGuard = nil
        draftRightGuard = nil
        resetGuardCapture()
        resetReachCapture()
        jabTargetPosition = SIMD3<Float>(-0.16, 1.35, -0.82)
        crossTargetPosition = SIMD3<Float>(0.16, 1.35, -0.82)
    }

    func targetPosition(for punch: PunchKind) -> SIMD3<Float> {
        punch == .jab ? jabTargetPosition : crossTargetPosition
    }

    func expectedPunch(forBoardTarget index: Int) -> PunchKind {
        Self.boardPattern[normalizedBoardIndex(index)].punch
    }

    func boardTargetPosition(at index: Int) -> SIMD3<Float> {
        let spec = Self.boardPattern[normalizedBoardIndex(index)]
        guard let profile = calibration else {
            let fallback = targetPosition(for: spec.punch)
            return fallback + SIMD3<Float>(spec.lateralOffset, spec.verticalOffset, 0)
        }

        let hand = profile.hand(for: spec.punch)
        let forward = profile.straightPunchDirection(for: hand)
            * (profile.targetPlacementReach(for: hand) * 0.70)
        return profile.guardPosition(for: hand)
            + forward
            + SIMD3<Float>(spec.lateralOffset, spec.verticalOffset, 0)
    }

    func visualState(forBoardTarget index: Int) -> MittVisualState {
        let normalized = normalizedBoardIndex(index)
        if case .pausedForTracking = phase { return .paused }

        if cueIsVisuallyActive,
           let cue = activeCue,
           normalizedBoardIndex(cue.sequenceIndex) == normalized {
            return .active
        }

        guard lastResolvedBoardIndex == normalized else { return .inactive }
        switch feedback {
        case .hit:
            return .hit
        case .miss, .wrong:
            return .miss
        case .paused:
            return .paused
        case .neutral:
            return .inactive
        }
    }

    func visualState(for punch: PunchKind) -> MittVisualState {
        if phase == .pausedForTracking || {
            if case .failed = phase { return true }
            return false
        }() {
            return .paused
        }

        switch feedback {
        case .hit(let feedbackPunch) where feedbackPunch == punch:
            return .hit
        case .miss(let feedbackPunch) where feedbackPunch == punch:
            return .miss
        case .wrong(let expected) where expected == punch:
            return .miss
        default:
            return cueIsVisuallyActive && activeCue?.expectedPunch == punch
                ? .active
                : .inactive
        }
    }

    func ingest(_ sample: HandSample) {
        guard isValid(sample) else {
            invalidateActiveCalibrationCapture(
                instruction: "Tracking produced an invalid sample. Hold still and restart this capture."
            )
            return
        }

        if let lastAcceptedSampleTimestamp,
           sample.timestamp <= lastAcceptedSampleTimestamp {
            return
        }
        lastAcceptedSampleTimestamp = sample.timestamp

        let sampleHasBothHands = sample.left != nil && sample.right != nil
        if trackingAvailable != sampleHasBothHands {
            let wasAvailable = trackingAvailable
            trackingAvailable = sampleHasBothHands

            if wasAvailable,
               !sampleHasBothHands,
               isRoundActive,
               phase != .pausedForTracking {
                pauseForTracking(at: sample.timestamp)
            }
        }

        switch phase {
        case .calibratingGuard:
            ingestGuardCalibration(sample)
        case .calibratingReach:
            ingestReachCalibration(sample)
        case .running:
            ingestRunningSample(sample)
        case .pausedForTracking:
            ingestPausedSample(sample)
        default:
            break
        }
    }

    private func ingestGuardCalibration(_ sample: HandSample) {
        guard let left = sample.left, let right = sample.right else {
            resetGuardCapture()
            phase = .calibratingGuard(progress: 0)
            instruction = "Keep both hands visible and hold guard continuously."
            return
        }

        if guardStartedAt == nil {
            guardStartedAt = sample.timestamp
        }

        if let previous = previousGuardSample {
            let movedTooFast = HandSide.allCases.contains { hand in
                guard let currentPose = sample.pose(for: hand),
                      let previousPose = previous.pose(for: hand),
                      currentPose.capturedAt > previousPose.capturedAt else {
                    return false
                }
                let deltaTime = currentPose.capturedAt - previousPose.capturedAt
                guard deltaTime <= configuration.maximumSampleInterval else { return true }
                let speed = simd_length(
                    currentPose.fistCenter - previousPose.fistCenter
                ) / Float(deltaTime)
                return speed > configuration.maximumGuardSpeed
            }

            if movedTooFast {
                resetGuardCapture(startedAt: sample.timestamp, previous: sample)
                phase = .calibratingGuard(progress: 0)
                instruction = "Hold both fists still; the two-second hold restarted."
                return
            }
        }
        previousGuardSample = sample

        guardLeftSum += left.fistCenter
        guardRightSum += right.fistCenter
        guardSampleCount += 1

        let elapsed = sample.timestamp - (guardStartedAt ?? sample.timestamp)
        phase = .calibratingGuard(
            progress: min(1, elapsed / configuration.guardHoldDuration)
        )

        guard elapsed >= configuration.guardHoldDuration, guardSampleCount > 0 else {
            return
        }

        draftLeftGuard = guardLeftSum / Float(guardSampleCount)
        draftRightGuard = guardRightSum / Float(guardSampleCount)
        phase = .awaitingReach
        instruction = "Next, capture two controlled straight extensions and returns with each hand. No bag or partner."
    }

    private func ingestReachCalibration(_ sample: HandSample) {
        guard let leftGuard = draftLeftGuard,
              let rightGuard = draftRightGuard,
              let left = sample.left,
              let right = sample.right else {
            restartReachCapture(
                previous: nil,
                message: "Both hands must remain visible. The bilateral capture restarted."
            )
            return
        }

        if let previousReachSample,
           sample.timestamp - previousReachSample.timestamp
                > configuration.maximumSampleInterval {
            restartReachCapture(
                previous: sample,
                message: "Reach capture restarted after a tracking gap. Begin again from guard."
            )
            return
        }

        guard isFreshReachSample(sample, comparedTo: previousReachSample) else {
            restartReachCapture(
                previous: sample,
                message: "Reach capture restarted because a hand sample was not current. Begin again from guard."
            )
            return
        }

        let previous = previousReachSample
        previousReachSample = sample

        let leftDistance = simd_length(left.fistCenter - leftGuard)
        let rightDistance = simd_length(right.fistCenter - rightGuard)
        let atGuard: [HandSide: Bool] = [
            .left: leftDistance <= configuration.guardReturnRadius,
            .right: rightDistance <= configuration.guardReturnRadius,
        ]
        let distances: [HandSide: Float] = [
            .left: leftDistance,
            .right: rightDistance,
        ]

        switch reachCycleState {
        case .waitingForGuard:
            guard atGuard[.left] == true, atGuard[.right] == true else {
                updateReachProgress(cycleFraction: 0)
                instruction = "Place both fists in the calibrated guard to arm \(reachPairPrompt)."
                return
            }

            reachCycleState = .armed
            reachCycleStartedAt = nil
            reachCycleMeasurement = nil
            reachCyclePeakSpeed = 0
            updateReachProgress(cycleFraction: 0)
            instruction = reachInstructionForArmedCycle()

        case .armed:
            guard !reachCycleTimedOut(at: sample.timestamp) else {
                requestFreshReachCapture(
                    message: "The repetition was not completed inside the provisional capture window."
                )
                return
            }

            let departedHands = HandSide.allCases.filter {
                (distances[$0] ?? 0) >= configuration.minimumGuardDeparture
            }
            guard !departedHands.isEmpty else {
                updateReachProgress(cycleFraction: 0)
                return
            }

            guard departedHands.count == 1, let movingHand = departedHands.first else {
                restartReachCapture(
                    previous: sample,
                    message: "Move only one fist. The bilateral capture restarted from guard."
                )
                return
            }

            if let reachPairHand,
               movingHand != reachPairHand {
                restartCurrentReachCycle(
                    previous: sample,
                    message: "Finish the two \(reachPairHand.rawValue)-hand repetitions before switching hands."
                )
                return
            }

            if functionalCalibrationReports[movingHand]?.grade == .consistent {
                let remainingHand: HandSide = movingHand == .left ? .right : .left
                reachPairHand = remainingHand
                restartCurrentReachCycle(
                    previous: sample,
                    message: "The \(movingHand.rawValue) hand is complete. Return to guard and use the \(remainingHand.rawValue) hand."
                )
                return
            }

            let otherHand: HandSide = movingHand == .left ? .right : .left
            guard atGuard[otherHand] == true else {
                restartCurrentReachCycle(
                    previous: sample,
                    message: "Keep the other fist at guard. This repetition restarted."
                )
                return
            }

            reachPairHand = movingHand
            reachCycleState = .extending(hand: movingHand)
            reachCycleStartedAt = sample.timestamp
            updateReachCycle(
                hand: movingHand,
                sample: sample,
                previous: previous,
                guardPosition: movingHand == .left ? leftGuard : rightGuard
            )

        case .extending(let hand):
            guard !reachCycleTimedOut(at: sample.timestamp) else {
                requestFreshReachCapture(
                    message: "The repetition was not completed inside the provisional capture window."
                )
                return
            }

            let otherHand: HandSide = hand == .left ? .right : .left
            guard atGuard[otherHand] == true else {
                restartCurrentReachCycle(
                    previous: sample,
                    message: "Keep the other fist at guard throughout the motion. This repetition restarted."
                )
                return
            }

            updateReachCycle(
                hand: hand,
                sample: sample,
                previous: previous,
                guardPosition: hand == .left ? leftGuard : rightGuard
            )

            guard (distances[hand] ?? .infinity) <= configuration.guardReturnRadius else {
                return
            }

            guard let measurement = reachCycleMeasurement,
                  measurement.distance >= configuration.minimumComfortableReach else {
                reachCycleState = .armed
                reachCycleStartedAt = nil
                reachCycleMeasurement = nil
                reachCyclePeakSpeed = 0
                updateReachProgress(cycleFraction: 0)
                instruction = "That motion did not complete a straight reach. Begin again from guard."
                return
            }

            completeReachRepetition(
                hand: hand,
                measurement: measurement,
                peakSpeed: reachCyclePeakSpeed,
                leftGuard: leftGuard,
                rightGuard: rightGuard
            )
        }
    }

    private func nextReachRepetitionNumber(for hand: HandSide) -> Int {
        min(
            (reachRepetitions[hand]?.count ?? 0) + 1,
            functionalCalibrationThresholds.requiredRepetitionCount
        )
    }

    private var reachPairPrompt: String {
        guard let reachPairHand else { return "the first hand pair" }
        return "\(reachPairHand.rawValue) repetition \(nextReachRepetitionNumber(for: reachPairHand)) of 2"
    }

    private func reachInstructionForArmedCycle() -> String {
        let count = functionalCalibrationThresholds.requiredRepetitionCount
        if let reachPairHand {
            return "\(reachPairHand.rawValue.capitalized) repetition \(nextReachRepetitionNumber(for: reachPairHand)) of \(count): extend straight, then return to guard."
        }
        return "Choose either fist for its first of \(count) straight extension-and-return repetitions."
    }

    private func updateReachCycle(
        hand: HandSide,
        sample: HandSample,
        previous: HandSample?,
        guardPosition: SIMD3<Float>
    ) {
        guard let pose = sample.pose(for: hand) else { return }

        let delta = pose.fistCenter - guardPosition
        let distance = simd_length(delta)
        let forwardRatio = -delta.z / max(distance, 0.0001)
        let isStraight = forwardRatio >= configuration.minimumForwardRatio

        if isStraight,
           distance > (reachCycleMeasurement?.distance ?? 0) {
            reachCycleMeasurement = ReachMeasurement(
                delta: delta,
                distance: distance
            )
        }

        if let previousPose = previous?.pose(for: hand),
           pose.capturedAt > previousPose.capturedAt {
            let deltaTime = pose.capturedAt - previousPose.capturedAt
            if deltaTime <= configuration.maximumSampleInterval {
                let velocity = (pose.fistCenter - previousPose.fistCenter)
                    / Float(deltaTime)
                let speed = simd_length(velocity)
                let cycleDirection = simd_normalize(
                    reachCycleMeasurement?.delta ?? delta
                )
                let projectedSpeed = max(0, simd_dot(velocity, cycleDirection))
                let velocityForwardRatio = projectedSpeed / max(speed, 0.0001)
                if projectedSpeed > 0,
                   velocityForwardRatio >= configuration.minimumForwardRatio {
                    // Match the PunchDetector numerator: both are velocity
                    // projected onto this hand's calibrated straight path.
                    reachCyclePeakSpeed = max(
                        reachCyclePeakSpeed,
                        projectedSpeed
                    )
                }
            }
        }

        let cycleFraction: Double
        if let peakDistance = reachCycleMeasurement?.distance,
           peakDistance >= configuration.minimumComfortableReach {
            let returnFraction = 1 - min(distance / max(peakDistance, 0.0001), 1)
            cycleFraction = 0.5 + Double(returnFraction) * 0.5
            instruction = "Extension captured. Return the \(hand.rawValue) fist to guard to complete repetition \(nextReachRepetitionNumber(for: hand))."
        } else {
            let outwardFraction = min(
                distance / max(configuration.minimumComfortableReach, 0.0001),
                1
            )
            cycleFraction = Double(outwardFraction) * 0.5
            instruction = "Extend the \(hand.rawValue) fist straight while the other fist stays at guard."
        }
        updateReachProgress(cycleFraction: cycleFraction)
    }

    private func completeReachRepetition(
        hand: HandSide,
        measurement: ReachMeasurement,
        peakSpeed: Float,
        leftGuard: SIMD3<Float>,
        rightGuard: SIMD3<Float>
    ) {
        var handRepetitions = reachRepetitions[hand] ?? []
        handRepetitions.append(
            ReachRepetition(
                hand: hand,
                measurement: measurement,
                peakSpeed: peakSpeed
            )
        )
        reachRepetitions[hand] = handRepetitions
        functionalCalibrationReports[hand] = FunctionalCalibrationReport.evaluate(
            reachMeters: handRepetitions.map(\.measurement.distance),
            thresholds: functionalCalibrationThresholds
        )

        guard handRepetitions.count
                >= functionalCalibrationThresholds.requiredRepetitionCount else {
            reachPairHand = hand
            reachCycleState = .armed
            reachCycleStartedAt = nil
            reachCycleMeasurement = nil
            reachCyclePeakSpeed = 0
            updateReachProgress(cycleFraction: 0)
            instruction = "\(hand.rawValue.capitalized) repetition 1 of 2 captured. Repeat with the same hand from guard."
            validationMessage = nil
            return
        }

        guard functionalCalibrationReports[hand]?.grade.isAccepted == true else {
            resetCurrentReachCycle(previous: nil)
            reachPairHand = hand
            phase = .awaitingReach
            validationMessage = "The two \(hand.rawValue)-hand repetitions were not repeatable enough for this provisional fit check."
            instruction = "Start a fresh two-repetition \(hand.rawValue)-hand capture; any accepted opposite-hand pair is retained for this session."
            return
        }

        let otherHand: HandSide = hand == .left ? .right : .left
        guard functionalCalibrationReports[otherHand]?.grade.isAccepted == true else {
            reachPairHand = otherHand
            reachCycleState = .armed
            reachCycleStartedAt = nil
            reachCycleMeasurement = nil
            reachCyclePeakSpeed = 0
            updateReachProgress(cycleFraction: 0)
            validationMessage = nil
            instruction = "\(hand.rawValue.capitalized) pair accepted. Now complete two \(otherHand.rawValue)-hand repetitions from guard."
            return
        }

        finishBilateralCalibration(
            leftGuard: leftGuard,
            rightGuard: rightGuard
        )
    }

    private func finishBilateralCalibration(
        leftGuard: SIMD3<Float>,
        rightGuard: SIMD3<Float>
    ) {
        guard let leftReport = functionalCalibrationReports[.left],
              leftReport.grade.isAccepted,
              let leftReach = leftReport.conservativeReachMeters,
              let leftRepetition = reachRepetitions[.left]?.min(by: {
                  $0.measurement.distance < $1.measurement.distance
              }),
              let rightReport = functionalCalibrationReports[.right],
              rightReport.grade.isAccepted,
              let rightReach = rightReport.conservativeReachMeters,
              let rightRepetition = reachRepetitions[.right]?.min(by: {
                  $0.measurement.distance < $1.measurement.distance
              }) else {
            phase = .awaitingReach
            validationMessage = "Both independently accepted hand pairs are required."
            instruction = "Start a fresh bilateral functional-reach capture."
            return
        }

        let leftHand = HandCalibrationProfile(
            acceptedFunctionalReach: leftReach,
            targetPlacementReach: min(
                leftReach,
                configuration.maximumComfortableReach
            ),
            straightPunchDirection: simd_normalize(
                leftRepetition.measurement.delta
            ),
            referenceProjectedPace: max(
                leftRepetition.peakSpeed,
                configuration.minimumReferenceSpeed
            )
        )
        let rightHand = HandCalibrationProfile(
            acceptedFunctionalReach: rightReach,
            targetPlacementReach: min(
                rightReach,
                configuration.maximumComfortableReach
            ),
            straightPunchDirection: simd_normalize(
                rightRepetition.measurement.delta
            ),
            referenceProjectedPace: max(
                rightRepetition.peakSpeed,
                configuration.minimumReferenceSpeed
            )
        )
        let profile = CalibrationProfile(
            stance: selectedStance,
            leftGuard: leftGuard,
            rightGuard: rightGuard,
            leftHand: leftHand,
            rightHand: rightHand
        )
        calibration = profile
        detector = PunchDetector(calibration: profile, configuration: configuration)
        jabTargetPosition = profile.targetPosition(for: .jab, configuration: configuration)
        crossTargetPosition = profile.targetPosition(for: .cross, configuration: configuration)
        clearReachWorkingState(clearReport: false)
        phase = .ready
        validationMessage = nil
        instruction = "Bilateral functional reach fit complete. Each hand uses its own accepted path and projected reference pace."
    }

    private func reachCycleTimedOut(at timestamp: TimeInterval) -> Bool {
        guard let reachCycleStartedAt else { return false }
        return timestamp - reachCycleStartedAt
            > configuration.reachCaptureDuration
    }

    private func updateReachProgress(cycleFraction: Double) {
        let completed = Double(completedReachRepetitionCount)
        let required = Double(
            max(1, requiredReachRepetitionCount)
        )
        let progress = min(1, max(0, (completed + cycleFraction) / required))
        phase = .calibratingReach(progress: progress)
    }

    private func restartReachCapture(
        previous: HandSample?,
        message: String
    ) {
        clearReachWorkingState(clearReport: true)
        previousReachSample = previous
        for hand in HandSide.allCases {
            functionalCalibrationReports[hand] = emptyFunctionalReport()
        }
        phase = .calibratingReach(progress: 0)
        validationMessage = message
        instruction = "\(message) Place both fists in guard to start a fresh bilateral capture."
    }

    private func restartCurrentReachCycle(
        previous: HandSample?,
        message: String
    ) {
        resetCurrentReachCycle(previous: previous)
        updateReachProgress(cycleFraction: 0)
        validationMessage = message
        instruction = "\(message) Return both fists to guard."
    }

    private func requestFreshReachCapture(message: String) {
        clearReachWorkingState(clearReport: true)
        for hand in HandSide.allCases {
            functionalCalibrationReports[hand] = emptyFunctionalReport()
        }
        phase = .awaitingReach
        validationMessage = message
        instruction = "Start a fresh bilateral capture when both fists are visible."
    }

    private func emptyFunctionalReport() -> FunctionalCalibrationReport {
        FunctionalCalibrationReport.evaluate(
            reachMeters: [],
            thresholds: functionalCalibrationThresholds
        )
    }

    private func resetCurrentReachCycle(previous: HandSample?) {
        reachCycleStartedAt = nil
        reachCycleState = .waitingForGuard
        reachCycleMeasurement = nil
        reachCyclePeakSpeed = 0
        previousReachSample = previous
    }

    private func isFreshReachSample(
        _ sample: HandSample,
        comparedTo previous: HandSample?
    ) -> Bool {
        HandSide.allCases.allSatisfy { hand in
            guard let pose = sample.pose(for: hand) else { return false }
            let captureAge = sample.timestamp - pose.capturedAt
            guard captureAge >= 0,
                  captureAge <= configuration.maximumSampleInterval else {
                return false
            }

            guard let previousPose = previous?.pose(for: hand) else {
                return true
            }
            guard pose.capturedAt >= previousPose.capturedAt else {
                return false
            }
            return pose.capturedAt == previousPose.capturedAt
                || pose.capturedAt - previousPose.capturedAt
                    <= configuration.maximumSampleInterval
        }
    }

    private func ingestRunningSample(_ sample: HandSample) {
        updateGuardReturns(with: sample)
        guard var detector else { return }

        let cue = activeCue
        let events = detector.process(sample, target: cue)
        self.detector = detector

        guard let cue else { return }
        let event = events.min { lhs, rhs in
            if lhs.completedAt == rhs.completedAt {
                return lhs.kind == cue.expectedPunch && rhs.kind != cue.expectedPunch
            }
            return lhs.completedAt < rhs.completedAt
        }
        guard let event else { return }

        let outcome: AttemptOutcome
        if event.kind != cue.expectedPunch {
            outcome = .wrongPunch
        } else if event.contactAt != nil {
            outcome = .hit
        } else {
            outcome = .miss
        }
        let responseTime = outcome == .hit
            ? event.contactAt.map { max(0, $0 - cue.presentedAt) }
            : nil

        resolveCue(
            cue,
            outcome: outcome,
            at: max(sample.timestamp, event.completedAt),
            punch: event,
            responseTime: responseTime
        )
        updateGuardReturns(with: sample)
    }

    private func ingestPausedSample(_ sample: HandSample) {
        guard !systemInterrupted else { return }
        guard trackingAvailable,
              let profile = calibration,
              let left = sample.left,
              let right = sample.right else {
            resumeGuardStartedAt = nil
            return
        }

        let leftAtGuard = simd_length(left.fistCenter - profile.leftGuard)
            <= configuration.guardReturnRadius
        let rightAtGuard = simd_length(right.fistCenter - profile.rightGuard)
            <= configuration.guardReturnRadius

        guard leftAtGuard, rightAtGuard else {
            resumeGuardStartedAt = nil
            return
        }

        if resumeGuardStartedAt == nil {
            resumeGuardStartedAt = sample.timestamp
            return
        }

        guard sample.timestamp - (resumeGuardStartedAt ?? sample.timestamp)
                >= configuration.resumeGuardHoldDuration else {
            return
        }

        if let pausedStartedAt {
            totalPausedDuration += max(0, sample.timestamp - pausedStartedAt)
        }
        self.pausedStartedAt = nil
        resumeGuardStartedAt = nil
        detector?.reset()
        _ = detector?.process(sample, target: nil)
        feedback = .neutral
        lastTickAt = sample.timestamp

        if resumeRestartsCountdown {
            countdownEndsAt = sample.timestamp + configuration.countdownDuration
            phase = .countdown(seconds: Int(ceil(configuration.countdownDuration)))
            instruction = "Tracking is stable. Restarting the countdown."
        } else {
            nextCueAt = sample.timestamp + 0.2
            phase = .running
            instruction = "Tracking restored. The interrupted cue was cancelled."
        }
    }

    private func startRoundClock() {
        roundTask?.cancel()
        roundTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                self?.tick(at: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    private func tick(at now: TimeInterval) {
        switch phase {
        case .countdown:
            guard let countdownEndsAt else { return }
            let seconds = max(0, Int(ceil(countdownEndsAt - now)))
            phase = .countdown(seconds: seconds)
            guard now >= countdownEndsAt else { return }
            phase = .running
            lastTickAt = now
            presentNextCue(at: now)

        case .running:
            let previousTick = lastTickAt ?? now
            remainingTime = max(0, remainingTime - max(0, now - previousTick))
            lastTickAt = now
            expireGuardReturns(at: now)

            if remainingTime <= 0 {
                finishRound(at: now)
                return
            }

            if let cue = activeCue,
               cueIsVisuallyActive,
               now >= cue.expiresAt {
                cueIsVisuallyActive = false
            }

            if let cue = activeCue,
               now >= cue.expiresAt + configuration.maximumSampleInterval {
                resolveCue(
                    cue,
                    outcome: .timeout,
                    at: now,
                    punch: nil,
                    responseTime: nil
                )
            } else if activeCue == nil,
                      remainingTime >= activeCueDuration
                        + configuration.maximumSampleInterval,
                      now >= (nextCueAt ?? now) {
                presentNextCue(at: now)
            }

        default:
            break
        }
    }

    private func presentNextCue(at timestamp: TimeInterval) {
        guard phase == .running, calibration != nil else { return }
        guard remainingTime >= activeCueDuration
                + configuration.maximumSampleInterval else {
            instruction = "Round ending — stay in guard."
            return
        }
        let boardIndex = normalizedBoardIndex(nextSequenceIndex)
        let punch = Self.boardPattern[boardIndex].punch
        let cue = TargetCue(
            sequenceIndex: nextSequenceIndex,
            expectedPunch: punch,
            center: boardTargetPosition(at: boardIndex),
            radius: configuration.targetRadius,
            presentedAt: timestamp,
            expiresAt: timestamp + activeCueDuration
        )
        nextSequenceIndex += 1
        lastResolvedBoardIndex = nil
        activeCue = cue
        cueIsVisuallyActive = true
        feedback = .neutral
        instruction = "\(punch.title) — punch the highlighted mitt and return to guard."
    }

    private func resolveCue(
        _ cue: TargetCue,
        outcome: AttemptOutcome,
        at timestamp: TimeInterval,
        punch: PunchEvent?,
        responseTime: TimeInterval?
    ) {
        guard activeCue?.id == cue.id else { return }
        lastResolvedBoardIndex = normalizedBoardIndex(cue.sequenceIndex)
        let expectedHand = calibration?.hand(for: cue.expectedPunch)
        let relativeSpeed = punch.flatMap { punch -> Double? in
            guard let calibration,
                  let expectedHand,
                  punch.hand == expectedHand else {
                return nil
            }
            let projectedReference = max(
                calibration.referenceProjectedPace(for: expectedHand),
                configuration.minimumReferenceSpeed
            )
            // PunchDetector's numerator and the hand-specific denominator are
            // both velocities projected onto this expected hand's straight path.
            return Double(punch.peakSpeed / projectedReference)
        }
        let attempt = AttemptResult(
            cue: cue,
            outcome: outcome,
            resolvedAt: timestamp,
            punch: punch,
            responseTime: responseTime,
            relativeSpeed: relativeSpeed
        )
        attempts.append(attempt)

        if let punch {
            let eventAt = punch.contactAt ?? punch.completedAt
            pendingGuardReturns[punch.hand] = PendingGuardReturn(
                attemptID: attempt.id,
                eventAt: eventAt,
                deadline: eventAt + configuration.guardReturnGoal
            )
        }

        switch outcome {
        case .hit:
            feedback = .hit(cue.expectedPunch)
            instruction = "Hit. Return to guard."
        case .miss:
            feedback = .miss(cue.expectedPunch)
            instruction = "Miss. Return to guard."
        case .wrongPunch:
            feedback = .wrong(expected: cue.expectedPunch)
            instruction = "Wrong hand. Return to guard."
        case .timeout:
            feedback = .miss(cue.expectedPunch)
            instruction = "Cue timed out. Stay in guard."
        }

        activeCue = nil
        cueIsVisuallyActive = false
        nextCueAt = timestamp + activeFeedbackDelay
    }

    private func normalizedBoardIndex(_ index: Int) -> Int {
        let count = Self.boardPattern.count
        return ((index % count) + count) % count
    }

    private func updateGuardReturns(with sample: HandSample) {
        guard let profile = calibration else { return }
        for hand in HandSide.allCases {
            guard let pending = pendingGuardReturns[hand] else { continue }

            if let pose = sample.pose(for: hand),
               pose.capturedAt >= pending.eventAt,
               pose.capturedAt <= pending.deadline,
               simd_length(pose.fistCenter - profile.guardPosition(for: hand))
                    <= configuration.guardReturnRadius {
                setGuardReturn(attemptID: pending.attemptID, value: true)
                pendingGuardReturns.removeValue(forKey: hand)
            } else if sample.timestamp > pending.deadline + configuration.maximumSampleInterval {
                setGuardReturn(attemptID: pending.attemptID, value: false)
                pendingGuardReturns.removeValue(forKey: hand)
            }
        }
    }

    private func expireGuardReturns(at timestamp: TimeInterval) {
        for (hand, pending) in pendingGuardReturns
        where timestamp > pending.deadline + configuration.maximumSampleInterval {
            setGuardReturn(attemptID: pending.attemptID, value: false)
            pendingGuardReturns.removeValue(forKey: hand)
        }
    }

    private func setGuardReturn(attemptID: UUID, value: Bool) {
        guard let index = attempts.firstIndex(where: { $0.id == attemptID }) else { return }
        attempts[index].returnedToGuard = value
    }

    private func pauseForTracking(
        at timestamp: TimeInterval,
        countInterruption: Bool = true
    ) {
        if phase == .running {
            let previousTick = lastTickAt ?? timestamp
            remainingTime = max(
                0,
                remainingTime - max(0, timestamp - previousTick)
            )
            lastTickAt = timestamp
        }
        if countInterruption {
            trackingInterruptionCount += 1
        }
        resumeRestartsCountdown = {
            if case .countdown = phase { return true }
            return false
        }()
        if activeCue != nil {
            cancelledCueCount += 1
        }
        phase = .pausedForTracking
        pausedStartedAt = timestamp
        resumeGuardStartedAt = nil
        activeCue = nil
        cueIsVisuallyActive = false
        pendingGuardReturns = [:]
        feedback = .paused
        detector?.reset()
        instruction = "Paused. Hold both hands at the calibrated guard to resume."
    }

    private func failForTracking(_ message: String) {
        if isRoundActive, phase != .pausedForTracking {
            trackingInterruptionCount += 1
        }
        if activeCue != nil {
            cancelledCueCount += 1
        }
        roundTask?.cancel()
        roundTask = nil
        trackingAvailable = false
        activeCue = nil
        cueIsVisuallyActive = false
        pendingGuardReturns = [:]
        pausedStartedAt = nil
        resumeGuardStartedAt = nil
        feedback = .paused
        phase = .failed(message: message)
        instruction = "Stop and exit the training space. Re-enter only after the tracking issue is resolved."
        validationMessage = message
    }

    private func finishRound(at timestamp: TimeInterval) {
        if let cue = activeCue {
            resolveCue(
                cue,
                outcome: .timeout,
                at: timestamp,
                punch: nil,
                responseTime: nil
            )
        }
        pendingGuardReturns = [:]
        remainingTime = 0
        activeCue = nil
        cueIsVisuallyActive = false
        feedback = .neutral
        summary = RoundSummary(
            attempts: attempts,
            pausedDuration: totalPausedDuration,
            cancelledCues: cancelledCueCount,
            trackingInterruptions: trackingInterruptionCount,
            difficulty: activeDifficulty
        )
        phase = .finished
        instruction = "Review the separate metrics below. They are relative, not force or medical measurements."
        roundTask?.cancel()
        roundTask = nil
    }

    private var activeCueDuration: TimeInterval {
        configuration.cueDuration
            * activeDifficulty.presentation.boardCueDurationMultiplier
    }

    private var activeFeedbackDelay: TimeInterval {
        configuration.feedbackDuration
            * activeDifficulty.presentation.boardFeedbackDelayMultiplier
    }

    private func resetGuardCapture(
        startedAt: TimeInterval? = nil,
        previous: HandSample? = nil
    ) {
        guardStartedAt = startedAt
        guardLeftSum = .zero
        guardRightSum = .zero
        guardSampleCount = 0
        previousGuardSample = previous
    }

    private func resetReachCapture() {
        clearReachWorkingState(clearReport: true)
    }

    private func clearReachWorkingState(clearReport: Bool) {
        resetCurrentReachCycle(previous: nil)
        reachPairHand = nil
        reachRepetitions = [:]
        if clearReport {
            functionalCalibrationReports = [:]
        }
    }

    private func isValid(_ sample: HandSample) -> Bool {
        guard sample.timestamp.isFinite else { return false }
        return [sample.left, sample.right].allSatisfy { pose in
            guard let pose else { return true }
            guard pose.capturedAt.isFinite,
                  isFinite(pose.fistCenter) else {
                return false
            }
            if let wrist = pose.wrist, !isFinite(wrist) {
                return false
            }
            return true
        }
    }

    private func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private func invalidateActiveCalibrationCapture(instruction: String) {
        switch phase {
        case .calibratingGuard:
            resetGuardCapture()
            phase = .calibratingGuard(progress: 0)
            self.instruction = instruction
        case .calibratingReach:
            restartReachCapture(previous: nil, message: instruction)
        default:
            break
        }
    }
}
