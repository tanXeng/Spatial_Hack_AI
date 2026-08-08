//
//  DefenseEngine.swift
//  Test
//
//  Deterministic head-movement coaching domain. The engine consumes plain
//  device/head-proxy positions and monotonic timestamps; ARKit stays outside
//  this file and callers own the clock.
//

import Foundation
import Observation
import simd

enum DefenseDrill: String, CaseIterable, Hashable, Sendable {
    case slipLeft
    case slipRight
    case duck
    case mixed

    var title: String {
        switch self {
        case .slipLeft:
            "Slip Left"
        case .slipRight:
            "Slip Right"
        case .duck:
            "Duck"
        case .mixed:
            "Mixed"
        }
    }

    fileprivate var cueSequence: [DefenseDrill] {
        switch self {
        case .slipLeft:
            Array(repeating: .slipLeft, count: DefenseEngine.cueGoal)
        case .slipRight:
            Array(repeating: .slipRight, count: DefenseEngine.cueGoal)
        case .duck:
            Array(repeating: .duck, count: DefenseEngine.cueGoal)
        case .mixed:
            [.slipLeft, .slipRight, .duck, .slipRight, .slipLeft, .duck]
        }
    }
}

/// A calibrated horizontal basis shared by Defense visuals and spatial audio.
/// It is derived from the headset-right direction captured during the neutral
/// hold; it is not a torso, pelvis, or foot orientation measurement.
struct DefenseSpatialBasis: Equatable, Sendable {
    let right: SIMD3<Float>
    let forward: SIMD3<Float>

    init(rightDirection: SIMD3<Float>?) {
        let candidate = rightDirection ?? SIMD3<Float>(1, 0, 0)
        let horizontal = SIMD3<Float>(candidate.x, 0, candidate.z)
        if horizontal.x.isFinite,
           horizontal.z.isFinite,
           simd_length(horizontal) > Float.ulpOfOne {
            right = simd_normalize(horizontal)
        } else {
            right = SIMD3<Float>(1, 0, 0)
        }
        forward = simd_normalize(
            simd_cross(SIMD3<Float>(0, 1, 0), right)
        )
    }

    func cuePosition(
        neutral: SIMD3<Float>,
        movement: DefenseDrill,
        forwardDistance: Float,
        lateralMagnitude: Float,
        duckVerticalOffset: Float = 0
    ) -> SIMD3<Float> {
        let lateral: Float = switch movement {
        case .slipLeft: lateralMagnitude
        case .slipRight: -lateralMagnitude
        case .duck, .mixed: 0
        }
        let vertical = movement == .duck ? duckVerticalOffset : 0
        return neutral
            + forward * forwardDistance
            + right * lateral
            + SIMD3<Float>(0, vertical, 0)
    }
}

struct DefenseConfiguration: Equatable, Sendable {
    var neutralCalibrationDuration: TimeInterval = 1.0
    var countdownDuration: TimeInterval = 3.0
    var cueDuration: TimeInterval = 2.0
    var interCueDelay: TimeInterval = 0.25
    var movementThreshold: Float = 0.12
    var maximumMovementDisplacement: Float = 0.35
    var neutralReturnRadius: Float = 0.06
    var stalePositionInterval: TimeInterval = 0.35
    var maximumNeutralSampleInterval: TimeInterval = 0.15
    var maximumNeutralDeviation: Float = 0.04
    var minimumNeutralSamples = 2

    nonisolated static let provisional = DefenseConfiguration()
}

struct DefenseCue: Identifiable, Equatable, Sendable {
    let id: Int
    let sequenceIndex: Int
    let expectedMovement: DefenseDrill
    let presentedAt: TimeInterval
    let expiresAt: TimeInterval

    func visualProgress(at timestamp: TimeInterval) -> Double {
        guard expiresAt > presentedAt else { return 1 }
        return min(1, max(0, (timestamp - presentedAt) / (expiresAt - presentedAt)))
    }
}

enum DefenseAttemptOutcome: Equatable, Sendable {
    case success
    case wrongDirection(detected: DefenseDrill)
    case didNotReturn
    case timeout
}

struct DefenseAttempt: Identifiable, Equatable, Sendable {
    let id: Int
    let cue: DefenseCue
    let outcome: DefenseAttemptOutcome
    let detectedMovement: DefenseDrill?
    let detectedAt: TimeInterval?
    let resolvedAt: TimeInterval
    let responseTime: TimeInterval?
    let displacementFromNeutral: SIMD3<Float>?
}

struct DefenseSummary: Equatable, Sendable {
    nonisolated static let headMovementMetricScopeLabel = "Head movement only"

    let selectedDrill: DefenseDrill
    let difficulty: TrainingDifficulty
    let cueGoal: Int
    let completedAttempts: Int
    let successfulAvoidances: Int
    let wrongDirections: Int
    let missedReturns: Int
    let timeouts: Int
    let cancelledCues: Int
    let trackingInterruptions: Int
    let safetyBoundaryInterruptions: Int
    let averageSuccessfulResponseTime: TimeInterval?
    let activeDuration: TimeInterval
    let pausedDuration: TimeInterval
    let metricScopeLabel: String

    init(
        selectedDrill: DefenseDrill,
        attempts: [DefenseAttempt],
        cancelledCues: Int,
        trackingInterruptions: Int = 0,
        safetyBoundaryInterruptions: Int = 0,
        activeDuration: TimeInterval,
        pausedDuration: TimeInterval,
        difficulty: TrainingDifficulty = .defaultValue
    ) {
        self.selectedDrill = selectedDrill
        self.difficulty = difficulty
        cueGoal = DefenseEngine.cueGoal
        completedAttempts = attempts.count
        successfulAvoidances = attempts.filter {
            $0.outcome == .success
        }.count
        wrongDirections = attempts.filter {
            if case .wrongDirection = $0.outcome { return true }
            return false
        }.count
        missedReturns = attempts.filter {
            $0.outcome == .didNotReturn
        }.count
        timeouts = attempts.filter {
            $0.outcome == .timeout
        }.count
        self.cancelledCues = cancelledCues
        self.trackingInterruptions = trackingInterruptions
        self.safetyBoundaryInterruptions = safetyBoundaryInterruptions

        let successfulResponses = attempts.compactMap { attempt -> TimeInterval? in
            guard attempt.outcome == .success else { return nil }
            return attempt.responseTime
        }
        averageSuccessfulResponseTime = successfulResponses.isEmpty
            ? nil
            : successfulResponses.reduce(0, +) / Double(successfulResponses.count)
        self.activeDuration = activeDuration
        self.pausedDuration = pausedDuration
        metricScopeLabel = Self.headMovementMetricScopeLabel
    }

    var adaptiveEvidenceInterruptions: Int {
        trackingInterruptions + safetyBoundaryInterruptions
    }
}

enum DefensePauseReason: Equatable, Sendable {
    case staleDevicePosition
    case trackingUnavailable
    case systemInterruption
    case excessiveMovement
    case userRequested
    case other(String)

    var title: String {
        switch self {
        case .staleDevicePosition:
            "Device position became stale"
        case .trackingUnavailable:
            "Head-position tracking is unavailable"
        case .systemInterruption:
            "System interruption"
        case .excessiveMovement:
            "Movement exceeded the controlled head-motion range"
        case .userRequested:
            "Paused"
        case .other(let message):
            message
        }
    }

    /// Safety, sensor, and system interruptions invalidate evidence for an
    /// adaptive pacing suggestion. A deliberate user pause does not.
    var invalidatesAdaptiveEvidence: Bool {
        switch self {
        case .staleDevicePosition,
             .trackingUnavailable,
             .systemInterruption,
             .excessiveMovement:
            true
        case .userRequested, .other:
            false
        }
    }
}

enum DefensePhase: Equatable, Sendable {
    case idle
    case calibratingNeutral(progress: Double)
    case ready
    case countdown(seconds: Int)
    case active
    case paused(reason: DefensePauseReason)
    case completed
}

enum DefenseFeedback: Equatable, Sendable {
    case neutral
    case cue(DefenseDrill)
    case returnToNeutral
    case success(DefenseDrill)
    case wrongDirection(expected: DefenseDrill, detected: DefenseDrill)
    case didNotReturn(DefenseDrill)
    case timeout(DefenseDrill)
    case paused(DefensePauseReason)

    var text: String? {
        switch self {
        case .neutral:
            nil
        case .cue(let drill):
            drill.title
        case .returnToNeutral:
            "Return your head to neutral"
        case .success(let drill):
            "\(drill.title) complete"
        case .wrongDirection(let expected, _):
            "Move \(expected.title.lowercased())"
        case .didNotReturn:
            "Return to neutral before the cue ends"
        case .timeout:
            "No head movement detected"
        case .paused(let reason):
            reason.title
        }
    }
}

@MainActor
@Observable
final class DefenseEngine {
    static let cueGoal = 6

    private struct PendingMovement {
        let detected: DefenseDrill
        let detectedAt: TimeInterval
        let displacement: SIMD3<Float>
    }

    let configuration: DefenseConfiguration

    private(set) var selectedDrill: DefenseDrill
    private(set) var phase: DefensePhase = .idle
    private(set) var instruction = "Choose a head-movement drill, then calibrate a neutral position."
    private(set) var feedback: DefenseFeedback = .neutral
    private(set) var currentCue: DefenseCue?
    private(set) var attempts: [DefenseAttempt] = []
    private(set) var summary: DefenseSummary?
    private(set) var neutralPosition: SIMD3<Float>?
    private(set) var neutralRightDirection: SIMD3<Float>?
    private(set) var cancelledCueCount = 0
    private(set) var trackingInterruptionCount = 0
    private(set) var safetyBoundaryInterruptionCount = 0
    private(set) var activeDuration: TimeInterval = 0
    private(set) var pausedDuration: TimeInterval = 0
    private(set) var activeDifficulty: TrainingDifficulty = .defaultValue

    var progress: Double {
        min(1, Double(attempts.count) / Double(Self.cueGoal))
    }

    var isCalibrated: Bool {
        neutralPosition != nil
    }

    @ObservationIgnored private var neutralCalibrationStartedAt: TimeInterval?
    @ObservationIgnored private var neutralPositionSum = SIMD3<Float>.zero
    @ObservationIgnored private var neutralRightDirectionSum = SIMD3<Float>.zero
    @ObservationIgnored private var neutralSampleCount = 0
    @ObservationIgnored private var neutralReferencePosition: SIMD3<Float>?
    @ObservationIgnored private var previousNeutralSampleAt: TimeInterval?
    @ObservationIgnored private var latestDevicePosition: SIMD3<Float>?
    @ObservationIgnored private var latestDevicePositionAt: TimeInterval?
    @ObservationIgnored private var countdownEndsAt: TimeInterval?
    @ObservationIgnored private var nextCueAt: TimeInterval?
    @ObservationIgnored private var nextSequenceIndex = 0
    @ObservationIgnored private var presentedCueCount = 0
    @ObservationIgnored private var pendingMovement: PendingMovement?
    @ObservationIgnored private var lastTimelineAt: TimeInterval?
    @ObservationIgnored private var lastActiveUpdateAt: TimeInterval?
    @ObservationIgnored private var pausedStartedAt: TimeInterval?

    init(
        selectedDrill: DefenseDrill = .mixed,
        configuration: DefenseConfiguration = .provisional
    ) {
        self.selectedDrill = selectedDrill
        self.configuration = configuration
    }

    func selectDrill(_ drill: DefenseDrill) {
        guard !isSessionInProgress else { return }
        selectedDrill = drill
        resetRuntime(keepCalibration: true)
        phase = neutralPosition == nil ? .idle : .ready
        instruction = neutralPosition == nil
            ? "Calibrate a neutral head position before starting \(drill.title)."
            : "\(drill.title) is ready. Movements are scored as head movement only."
    }

    func beginNeutralCalibration(at timestamp: TimeInterval) {
        guard timestamp.isFinite, !isSessionInProgress else { return }

        resetRuntime(keepCalibration: false)
        neutralCalibrationStartedAt = timestamp
        phase = .calibratingNeutral(progress: 0)
        instruction = "Hold your head still in a comfortable neutral position for one second."
    }

    func ingestDevicePosition(
        _ position: SIMD3<Float>,
        rightDirection: SIMD3<Float>? = nil,
        capturedAt timestamp: TimeInterval
    ) {
        guard timestamp.isFinite, position.isFinite else { return }
        guard latestDevicePositionAt.map({ timestamp >= $0 }) ?? true else { return }
        guard lastTimelineAt.map({ timestamp >= $0 }) ?? true else { return }

        let previousPositionAt = latestDevicePositionAt

        if let previousPositionAt,
           isTimingSensitive,
           timestamp - previousPositionAt > configuration.stalePositionInterval {
            pause(
                reason: .staleDevicePosition,
                at: previousPositionAt + configuration.stalePositionInterval
            )
        }

        latestDevicePosition = position
        latestDevicePositionAt = timestamp

        switch phase {
        case .calibratingNeutral:
            ingestNeutralCalibration(
                position,
                rightDirection: Self.horizontalRightDirection(from: rightDirection),
                capturedAt: timestamp
            )

        case .countdown, .active:
            advanceTimeline(to: timestamp, checkPositionFreshness: false)
            guard phase == .active else { return }
            processActivePosition(position, capturedAt: timestamp)

        case .idle, .ready, .paused, .completed:
            break
        }
    }

    func start(
        at timestamp: TimeInterval,
        difficulty: TrainingDifficulty = .defaultValue
    ) {
        guard timestamp.isFinite,
              phase == .ready,
              neutralPosition != nil,
              hasFreshPosition(at: timestamp),
              latestPositionIsNeutral else {
            instruction = "Return to the calibrated neutral position before starting."
            return
        }

        resetRuntime(keepCalibration: true)
        activeDifficulty = difficulty
        countdownEndsAt = timestamp + configuration.countdownDuration
        lastTimelineAt = timestamp
        phase = .countdown(seconds: Int(ceil(configuration.countdownDuration)))
        instruction = "Stay in place. Defense cues begin after the countdown."
    }

    func tick(at timestamp: TimeInterval) {
        advanceTimeline(to: timestamp, checkPositionFreshness: true)
    }

    func pause(reason: DefensePauseReason, at timestamp: TimeInterval) {
        guard timestamp.isFinite, isTimingSensitive else { return }

        let resolvedTimestamp = max(lastTimelineAt ?? timestamp, timestamp)
        if phase == .active {
            accrueActiveTime(until: resolvedTimestamp)
        }

        if currentCue != nil {
            cancelledCueCount += 1
        }
        if reason == .excessiveMovement {
            safetyBoundaryInterruptionCount += 1
        } else if reason.invalidatesAdaptiveEvidence {
            trackingInterruptionCount += 1
        }
        currentCue = nil
        pendingMovement = nil
        nextCueAt = nil
        countdownEndsAt = nil
        lastActiveUpdateAt = nil
        lastTimelineAt = resolvedTimestamp
        pausedStartedAt = resolvedTimestamp
        phase = .paused(reason: reason)
        feedback = .paused(reason)
        instruction = "Paused. Return to neutral, then resume with a fresh countdown."
    }

    func resume(at timestamp: TimeInterval) {
        guard timestamp.isFinite,
              case .paused = phase,
              lastTimelineAt.map({ timestamp >= $0 }) ?? true,
              pausedStartedAt.map({ timestamp >= $0 }) ?? true,
              neutralPosition != nil,
              hasFreshPosition(at: timestamp),
              latestPositionIsNeutral else {
            instruction = "A fresh neutral head position is required before resuming."
            return
        }

        if let pausedStartedAt {
            pausedDuration += max(0, timestamp - pausedStartedAt)
        }
        self.pausedStartedAt = nil
        countdownEndsAt = timestamp + configuration.countdownDuration
        lastTimelineAt = timestamp
        feedback = .neutral
        phase = .countdown(seconds: Int(ceil(configuration.countdownDuration)))
        instruction = "Neutral position restored. Restarting the countdown."
    }

    func stop(preservingCompletedResults: Bool = true) {
        if preservingCompletedResults,
           phase == .completed,
           summary != nil {
            return
        }
        resetRuntime(keepCalibration: true)
        phase = neutralPosition == nil ? .idle : .ready
        instruction = neutralPosition == nil
            ? "Calibrate a neutral head position before starting."
            : "The defense drill stopped. Start again when ready."
    }

    func leaveImmersiveSpace() {
        let completedAttempts = attempts
        let completedSummary = summary
        let completedCancelledCues = cancelledCueCount
        let completedTrackingInterruptions = trackingInterruptionCount
        let completedSafetyBoundaryInterruptions
            = safetyBoundaryInterruptionCount
        let completedActiveDuration = activeDuration
        let completedPausedDuration = pausedDuration
        let preserveCompletedResults = phase == .completed && summary != nil

        resetRuntime(keepCalibration: false)
        latestDevicePosition = nil
        latestDevicePositionAt = nil

        if preserveCompletedResults {
            attempts = completedAttempts
            summary = completedSummary
            cancelledCueCount = completedCancelledCues
            trackingInterruptionCount = completedTrackingInterruptions
            safetyBoundaryInterruptionCount
                = completedSafetyBoundaryInterruptions
            activeDuration = completedActiveDuration
            pausedDuration = completedPausedDuration
            phase = .completed
            instruction = "Training space closed. Review head-movement metrics in the window."
        } else {
            phase = .idle
            instruction = "Neutral calibration expired when the immersive space closed."
        }
    }

    private var isSessionInProgress: Bool {
        switch phase {
        case .countdown, .active, .paused:
            true
        case .idle, .calibratingNeutral, .ready, .completed:
            false
        }
    }

    private var isTimingSensitive: Bool {
        switch phase {
        case .countdown, .active:
            true
        case .idle, .calibratingNeutral, .ready, .paused, .completed:
            false
        }
    }

    private var latestPositionIsNeutral: Bool {
        guard let neutralPosition, let latestDevicePosition else { return false }
        return simd_length(latestDevicePosition - neutralPosition)
            <= configuration.neutralReturnRadius
    }

    private func hasFreshPosition(at timestamp: TimeInterval) -> Bool {
        guard let latestDevicePositionAt else { return false }
        let age = timestamp - latestDevicePositionAt
        return age >= 0 && age <= configuration.stalePositionInterval
    }

    private func ingestNeutralCalibration(
        _ position: SIMD3<Float>,
        rightDirection: SIMD3<Float>?,
        capturedAt timestamp: TimeInterval
    ) {
        guard let neutralCalibrationStartedAt,
              timestamp >= neutralCalibrationStartedAt else { return }

        let resolvedRightDirection = rightDirection ?? SIMD3<Float>(1, 0, 0)

        if let previousNeutralSampleAt,
           timestamp - previousNeutralSampleAt
                > configuration.maximumNeutralSampleInterval {
            restartNeutralCalibration(
                at: timestamp,
                position: position,
                rightDirection: resolvedRightDirection,
                message: "Head tracking paused; the neutral hold restarted."
            )
            return
        }

        if let neutralReferencePosition,
           simd_distance(position, neutralReferencePosition)
                > configuration.maximumNeutralDeviation {
            restartNeutralCalibration(
                at: timestamp,
                position: position,
                rightDirection: resolvedRightDirection,
                message: "Keep your head still; the neutral hold restarted."
            )
            return
        }

        if neutralReferencePosition == nil {
            neutralReferencePosition = position
        }
        previousNeutralSampleAt = timestamp

        neutralPositionSum += position
        neutralRightDirectionSum += resolvedRightDirection
        neutralSampleCount += 1

        let elapsed = timestamp - neutralCalibrationStartedAt
        let calibrationProgress = configuration.neutralCalibrationDuration > 0
            ? min(1, elapsed / configuration.neutralCalibrationDuration)
            : 1
        phase = .calibratingNeutral(progress: calibrationProgress)

        guard elapsed >= configuration.neutralCalibrationDuration,
              neutralSampleCount >= configuration.minimumNeutralSamples else {
            return
        }

        neutralPosition = neutralPositionSum / Float(neutralSampleCount)
        neutralRightDirection = Self.normalizedDirection(
            neutralRightDirectionSum,
            fallback: SIMD3<Float>(1, 0, 0)
        )
        self.neutralCalibrationStartedAt = nil
        phase = .ready
        feedback = .neutral
        instruction = "Neutral calibration complete. Metrics describe head movement only."
    }

    private func advanceTimeline(
        to timestamp: TimeInterval,
        checkPositionFreshness: Bool
    ) {
        guard timestamp.isFinite, isTimingSensitive else { return }
        guard lastTimelineAt.map({ timestamp >= $0 }) ?? true else { return }

        if checkPositionFreshness,
           let latestDevicePositionAt,
           latestDevicePositionAt + configuration.stalePositionInterval < timestamp {
            pause(
                reason: .staleDevicePosition,
                at: latestDevicePositionAt + configuration.stalePositionInterval
            )
            return
        }

        switch phase {
        case .countdown:
            guard let countdownEndsAt else { return }
            let seconds = max(0, Int(ceil(countdownEndsAt - timestamp)))
            phase = .countdown(seconds: seconds)

            guard timestamp >= countdownEndsAt else {
                lastTimelineAt = timestamp
                return
            }

            phase = .active
            lastActiveUpdateAt = countdownEndsAt
            lastTimelineAt = countdownEndsAt
            presentNextCue(at: countdownEndsAt)
            processActiveDeadlines(at: timestamp)

        case .active:
            processActiveDeadlines(at: timestamp)

        case .idle, .calibratingNeutral, .ready, .paused, .completed:
            break
        }

        if isTimingSensitive {
            lastTimelineAt = timestamp
        }
    }

    private func processActiveDeadlines(at timestamp: TimeInterval) {
        guard phase == .active else { return }
        let accrualBoundary = currentCue.map {
            min(timestamp, $0.expiresAt)
        } ?? timestamp
        accrueActiveTime(until: accrualBoundary)

        if let cue = currentCue, timestamp >= cue.expiresAt {
            if let pendingMovement {
                resolveCue(
                    cue,
                    outcome: .didNotReturn,
                    detectedMovement: pendingMovement.detected,
                    detectedAt: pendingMovement.detectedAt,
                    displacement: pendingMovement.displacement,
                    at: cue.expiresAt
                )
            } else {
                resolveCue(
                    cue,
                    outcome: .timeout,
                    detectedMovement: nil,
                    detectedAt: nil,
                    displacement: nil,
                    at: cue.expiresAt
                )
            }
        }

        guard phase == .active, currentCue == nil else { return }
        if let nextCueAt, timestamp >= nextCueAt {
            guard latestPositionIsNeutral else {
                instruction = "Return your head to neutral before the next cue."
                return
            }
            presentNextCue(at: max(nextCueAt, latestDevicePositionAt ?? nextCueAt))
        }
    }

    private func processActivePosition(
        _ position: SIMD3<Float>,
        capturedAt timestamp: TimeInterval
    ) {
        guard let neutralPosition else { return }
        let displacement = position - neutralPosition

        if simd_length(displacement) > configuration.maximumMovementDisplacement {
            pause(reason: .excessiveMovement, at: timestamp)
            instruction = "Movement exceeded the controlled head-motion range. Stop, return to neutral, then resume for a fresh countdown."
            return
        }

        guard let cue = currentCue else { return }

        if let pendingMovement {
            guard simd_length(displacement) <= configuration.neutralReturnRadius else {
                return
            }

            let outcome: DefenseAttemptOutcome = pendingMovement.detected == cue.expectedMovement
                ? .success
                : .wrongDirection(detected: pendingMovement.detected)
            resolveCue(
                cue,
                outcome: outcome,
                detectedMovement: pendingMovement.detected,
                detectedAt: pendingMovement.detectedAt,
                displacement: pendingMovement.displacement,
                at: timestamp
            )
            return
        }

        guard let detectedMovement = classifyMovement(displacement) else { return }
        pendingMovement = PendingMovement(
            detected: detectedMovement,
            detectedAt: timestamp,
            displacement: displacement
        )

        if detectedMovement == cue.expectedMovement {
            feedback = .returnToNeutral
            instruction = "Good movement. Return your head to neutral to complete the cue."
        } else {
            feedback = .wrongDirection(
                expected: cue.expectedMovement,
                detected: detectedMovement
            )
            instruction = "Wrong direction. Return your head to neutral before the cue ends."
        }
    }

    private func classifyMovement(_ displacement: SIMD3<Float>) -> DefenseDrill? {
        guard simd_length(displacement) <= configuration.maximumMovementDisplacement else {
            return nil
        }
        let calibratedRight = neutralRightDirection ?? SIMD3<Float>(1, 0, 0)
        let horizontalDisplacement = simd_dot(displacement, calibratedRight)
        let horizontalMagnitude = abs(horizontalDisplacement)
        let downwardMagnitude = max(0, -displacement.y)
        let largestMagnitude = max(horizontalMagnitude, downwardMagnitude)
        guard largestMagnitude >= configuration.movementThreshold else { return nil }

        if downwardMagnitude > horizontalMagnitude {
            return .duck
        }
        return horizontalDisplacement < 0 ? .slipLeft : .slipRight
    }

    private func presentNextCue(at timestamp: TimeInterval) {
        guard phase == .active else { return }

        let sequence = selectedDrill.cueSequence
        let movement = sequence[nextSequenceIndex % sequence.count]
        let cue = DefenseCue(
            id: presentedCueCount,
            sequenceIndex: nextSequenceIndex,
            expectedMovement: movement,
            presentedAt: timestamp,
            expiresAt: timestamp + activeCueDuration
        )

        presentedCueCount += 1
        nextSequenceIndex += 1
        currentCue = cue
        pendingMovement = nil
        nextCueAt = nil
        feedback = .cue(movement)
        instruction = "\(movement.title), then return to neutral. Keep your feet still."
    }

    private func resolveCue(
        _ cue: DefenseCue,
        outcome: DefenseAttemptOutcome,
        detectedMovement: DefenseDrill?,
        detectedAt: TimeInterval?,
        displacement: SIMD3<Float>?,
        at timestamp: TimeInterval
    ) {
        guard phase == .active, currentCue?.id == cue.id else { return }

        let responseTime = detectedAt.map { max(0, $0 - cue.presentedAt) }
        attempts.append(DefenseAttempt(
            id: attempts.count,
            cue: cue,
            outcome: outcome,
            detectedMovement: detectedMovement,
            detectedAt: detectedAt,
            resolvedAt: timestamp,
            responseTime: responseTime,
            displacementFromNeutral: displacement
        ))

        currentCue = nil
        pendingMovement = nil

        switch outcome {
        case .success:
            feedback = .success(cue.expectedMovement)
            instruction = "Head movement complete. Stay neutral for the next cue."
        case .wrongDirection(let detected):
            feedback = .wrongDirection(expected: cue.expectedMovement, detected: detected)
            instruction = "Wrong direction. Reset at neutral for the next cue."
        case .didNotReturn:
            feedback = .didNotReturn(cue.expectedMovement)
            instruction = "The movement was detected, but neutral return was late."
        case .timeout:
            feedback = .timeout(cue.expectedMovement)
            instruction = "No movement was detected before the cue ended."
        }

        if attempts.count >= Self.cueGoal {
            complete(at: timestamp)
        } else {
            nextCueAt = timestamp + activeInterCueDelay
        }
    }

    private func complete(at timestamp: TimeInterval) {
        accrueActiveTime(until: timestamp)
        currentCue = nil
        pendingMovement = nil
        nextCueAt = nil
        countdownEndsAt = nil
        lastActiveUpdateAt = nil
        phase = .completed
        summary = DefenseSummary(
            selectedDrill: selectedDrill,
            attempts: attempts,
            cancelledCues: cancelledCueCount,
            trackingInterruptions: trackingInterruptionCount,
            safetyBoundaryInterruptions: safetyBoundaryInterruptionCount,
            activeDuration: activeDuration,
            pausedDuration: pausedDuration,
            difficulty: activeDifficulty
        )
        feedback = .neutral
        instruction = "Defense drill complete. Review head-movement metrics in the window."
    }

    private var activeCueDuration: TimeInterval {
        configuration.cueDuration
            * activeDifficulty.presentation.defenseCueDurationMultiplier
    }

    private var activeInterCueDelay: TimeInterval {
        configuration.interCueDelay
            * activeDifficulty.presentation.defenseInterCueDelayMultiplier
    }

    private func accrueActiveTime(until timestamp: TimeInterval) {
        guard phase == .active, let lastActiveUpdateAt else { return }
        activeDuration += max(0, timestamp - lastActiveUpdateAt)
        self.lastActiveUpdateAt = timestamp
    }

    private func resetRuntime(keepCalibration: Bool) {
        phase = .idle
        feedback = .neutral
        currentCue = nil
        attempts = []
        summary = nil
        cancelledCueCount = 0
        trackingInterruptionCount = 0
        safetyBoundaryInterruptionCount = 0
        activeDuration = 0
        pausedDuration = 0
        neutralCalibrationStartedAt = nil
        neutralPositionSum = .zero
        neutralRightDirectionSum = .zero
        neutralSampleCount = 0
        neutralReferencePosition = nil
        previousNeutralSampleAt = nil
        countdownEndsAt = nil
        nextCueAt = nil
        nextSequenceIndex = 0
        presentedCueCount = 0
        pendingMovement = nil
        lastTimelineAt = nil
        lastActiveUpdateAt = nil
        pausedStartedAt = nil

        if !keepCalibration {
            neutralPosition = nil
            neutralRightDirection = nil
        }
    }

    private func restartNeutralCalibration(
        at timestamp: TimeInterval,
        position: SIMD3<Float>,
        rightDirection: SIMD3<Float>,
        message: String
    ) {
        neutralCalibrationStartedAt = timestamp
        neutralPositionSum = position
        neutralRightDirectionSum = rightDirection
        neutralSampleCount = 1
        neutralReferencePosition = position
        previousNeutralSampleAt = timestamp
        phase = .calibratingNeutral(progress: 0)
        feedback = .neutral
        instruction = message
    }

    private static func horizontalRightDirection(
        from direction: SIMD3<Float>?
    ) -> SIMD3<Float>? {
        guard let direction, direction.isFinite else { return nil }
        return normalizedDirection(
            SIMD3<Float>(direction.x, 0, direction.z),
            fallback: nil
        )
    }

    private static func normalizedDirection(
        _ direction: SIMD3<Float>,
        fallback: SIMD3<Float>?
    ) -> SIMD3<Float>? {
        let length = simd_length(direction)
        guard length.isFinite, length > 0.0001 else { return fallback }
        return direction / length
    }
}

private extension SIMD3 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
