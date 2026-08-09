import Foundation
import QuartzCore
import RealityKit
import simd

enum DrillPhase: String, Sendable {
    case idle
    case calibrating
    case running
    case finished
}

/// Requires several consecutive, fresh samples before a technically interrupted competition
/// resumes. A single reacquired frame is not enough evidence that both hands are stable in guard.
nonisolated struct CompetitionTrackingRecoveryGate {
    static let lossGraceSeconds: TimeInterval = 0.35
    static let requiredStableSamples = 4

    private(set) var consecutiveStableSamples = 0

    mutating func observe(freshAndGuarded: Bool) -> Bool {
        consecutiveStableSamples = freshAndGuarded ? consecutiveStableSamples + 1 : 0
        return consecutiveStableSamples >= Self.requiredStableSamples
    }
}

/// Converts a competition tracking gap into an explicit wait, stable recovery, or clock pause.
/// A resumed short outage shifts both the target deadline and attempt origin by the same duration,
/// so lost tracking cannot manufacture a timeout or inflate the admitted punch's reaction time.
nonisolated enum CompetitionTrackingOutagePolicy {
    enum Decision: Equatable, Sendable {
        case wait
        case recover
        case resume(pausedDuration: TimeInterval)
    }

    static func decision(
        trackingAvailable: Bool,
        lossDuration: TimeInterval
    ) -> Decision {
        guard lossDuration.isFinite, lossDuration >= 0 else { return .recover }
        guard lossDuration < CompetitionTrackingRecoveryGate.lossGraceSeconds else {
            return .recover
        }
        return trackingAvailable ? .resume(pausedDuration: lossDuration) : .wait
    }

    static func compensatedDeadline(
        _ deadline: Date,
        pausedDuration: TimeInterval
    ) -> Date {
        guard pausedDuration.isFinite, pausedDuration > 0 else { return deadline }
        return deadline.addingTimeInterval(pausedDuration)
    }
}

/// Measures ranked active time from a monotonic clock while treating repeated loss polls and the
/// subsequent stable-recovery gate as one pause. `beginPause` is idempotent until `endPause`, so a
/// long outage keeps its original loss origin and cannot be double-counted when recovery begins.
nonisolated struct CompetitionElapsedClock: Sendable {
    private(set) var pausedDuration: TimeInterval = 0
    private var pauseStartedAt: TimeInterval?

    mutating func beginPause(at timestamp: TimeInterval) {
        guard pauseStartedAt == nil, timestamp.isFinite, timestamp >= 0 else { return }
        pauseStartedAt = timestamp
    }

    /// Opens ranked-time accounting before an asynchronous body-frame wait begins. Repeated calls
    /// while the same outage is active deliberately return `true` without replacing its origin.
    @discardableResult
    mutating func beginBodyFrameWaitIfNeeded(
        frameAvailable: Bool,
        rankedRoundActive: Bool,
        at timestamp: TimeInterval
    ) -> Bool {
        guard rankedRoundActive,
              !frameAvailable,
              timestamp.isFinite,
              timestamp >= 0 else {
            return false
        }
        beginPause(at: timestamp)
        return true
    }

    @discardableResult
    mutating func endPause(at timestamp: TimeInterval) -> TimeInterval {
        guard let pauseStartedAt,
              timestamp.isFinite,
              timestamp >= pauseStartedAt else {
            return 0
        }
        let duration = timestamp - pauseStartedAt
        let accumulated = pausedDuration + duration
        guard accumulated.isFinite else { return 0 }
        self.pauseStartedAt = nil
        pausedDuration = accumulated
        return duration
    }

    func activeElapsed(
        startedAt: TimeInterval,
        endedAt: TimeInterval
    ) -> TimeInterval {
        guard startedAt.isFinite,
              endedAt.isFinite,
              endedAt >= startedAt,
              pausedDuration.isFinite else {
            return 0
        }
        return max(0, endedAt - startedAt - pausedDuration)
    }
}

/// Keeps technically interrupted reactive-target evidence outside the miss/metric boundary.
/// Before either-hand selection, guard coaching owns availability. Once a physical side is fixed,
/// both hands and the device pose must stay coherent through retraction and coverage admission.
nonisolated enum ReactiveTargetTrackingPolicy {
    enum Decision: Equatable, Sendable {
        case continueAttempt
        case discardAndRetry

        var recordsMetric: Bool { false }
        var flashesTarget: Bool { false }
        var isRankable: Bool { false }
    }

    static func decision(
        selectedSide: BodySide?,
        requiredHandAvailable: Bool,
        otherHandAvailable: Bool,
        devicePoseAvailable: Bool
    ) -> Decision {
        guard selectedSide != nil else { return .continueAttempt }
        return requiredHandAvailable && otherHandAvailable && devicePoseAvailable
            ? .continueAttempt
            : .discardAndRetry
    }
}

/// Owns one generic target's immutable physical position across technical evidence retries.
nonisolated struct ReactiveTargetRetryPlan: Sendable {
    enum Outcome: Equatable, Sendable {
        case completed
        case retry
        case aborted
    }

    private(set) var targetPosition: SIMD3<Float>?

    init(targetPosition: SIMD3<Float>) {
        self.targetPosition = targetPosition
    }

    mutating func record(_ outcome: Outcome) {
        if outcome != .retry {
            targetPosition = nil
        }
    }
}

/// Owns Reactive Strike calibration and the target/combination drill loops.
@Observable
@MainActor
final class ReactiveStrikeSession {
    let immersiveSpaceID = BoxingCoachSceneID.immersiveSpace

    private(set) var phase: DrillPhase = .idle
    private(set) var currentTargetIndex = 0
    private(set) var currentComboStepIndex = 0
    private(set) var comboRepsCompleted = 0
    private(set) var lastFeedback: String = "Ready"
    private(set) var errorMessage: String?
    private(set) var isTrackingPaused = false
    private(set) var trackingReadyToResume = false
    private(set) var latestCalibratedReaches: [BodySide: Float] = [:]
    private(set) var competitionSteps: [CompetitionStepEvidence] = []
    private(set) var competitionTrackingStatus: CompetitionTrackingStatus = .complete
    private(set) var competitionActiveElapsedTime: TimeInterval?
    private(set) var competitionRequiresRecalibration = false
    private(set) var wasStoppedBeforeCompletion = false

    /// Whether the immersive space is actually on screen. The immersive scene owns this truth;
    /// a window-local copy goes stale if the system dismisses the space itself.
    private(set) var isImmersiveSpaceOpen = false

    var config = DrillConfig()
    var mode: ReactiveStrikeMode = .air
    var reachProfile = ReachProfile.air
    var selectedCombination: Combination = .oneTwo
    var stance: Stance = .orthodox
    var comboRepeatCount = 5

    let metrics = DrillMetrics()
    let hands = HandTrackingService()
    let targets = TargetController()
    /// Aura Punch shares this hand-tracking session and scene root. Two ARKit sessions competing
    /// for the same providers would make both features unreliable.
    let auraPunch: AuraPunchSession

    private let poseSolver = ArmPoseSolver()
    private var calibratedReaches: [ReactiveStrikeMode: [BodySide: Float]] = [:]
    private var guardPositionsBody: [BodySide: SIMD3<Float>] = [:]
    private var drillTask: Task<Void, Never>?
    private var activeAttemptID: UUID?
    private var spawnTime: Date?
    private var fistPositionAtSpawn: SIMD3<Float>?
    private var fistPositionsAtSpawn: [BodySide: SIMD3<Float>] = [:]
    private var capturesCompetitionEvidence = false
    private var calibrationOnly = false
    private var competitionStartedAt: TimeInterval?
    private var competitionElapsedClock = CompetitionElapsedClock()
    private var trackingResumeRequested = false
    private let coachAudio: CoachAudioPlayer
    let voiceCoach: CoachVoiceCoach

    init(
        feedbackGenerator: some FeedbackGenerating = MockFeedbackGenerator(),
        audienceTrack: CoachLearnerLevel = .beginner
    ) {
        let coachAudio = CoachAudioPlayer()
        self.coachAudio = coachAudio
        voiceCoach = CoachVoiceCoach(audioPlayer: coachAudio)
        auraPunch = AuraPunchSession(
            hands: hands,
            feedbackGenerator: feedbackGenerator,
            audienceTrack: audienceTrack,
            coachAudio: coachAudio
        )
    }

    var progressLabel: String {
        switch phase {
        case .idle:
            return "Idle"
        case .calibrating:
            return "Calibration"
        case .finished:
            return "Round complete"
        case .running:
            if mode == .combination {
                let step = min(currentComboStepIndex + 1, selectedCombination.punchCount)
                let rep = min(currentTargetIndex + 1, comboRepeatCount)
                return "Rep \(rep) / \(comboRepeatCount) · Step \(step) / \(selectedCombination.punchCount)"
            }
            return "Target \(min(currentTargetIndex + 1, config.targetCount)) / \(config.targetCount)"
        }
    }

    var hasCalibratedReach: Bool {
        guard let reaches = calibratedReaches[.air] else { return false }
        return ReachCalibration.conservativeBilateralReach(reaches) != nil
    }

    func immersiveSpaceDidOpen() {
        isImmersiveSpaceOpen = true
        auraPunch.prepareCoachAudio()
    }

    func immersiveSpaceDidClose() {
        isImmersiveSpaceOpen = false
        voiceCoach.shutdown()
    }

    func configure(
        mode: ReactiveStrikeMode,
        combination: Combination?,
        stance: Stance
    ) {
        config = DrillConfig()
        capturesCompetitionEvidence = false
        calibrationOnly = false
        self.mode = mode
        self.stance = stance
        if let combination {
            selectedCombination = combination
        }

        let key = calibrationKey(for: mode)
        if let reaches = calibratedReaches[key],
           let measuredReach = ReachCalibration.conservativeBilateralReach(reaches) {
            reachProfile = mode.reachProfile.calibrated(measuredForwardReach: measuredReach)
        } else {
            reachProfile = mode.reachProfile
        }
    }

    func configureCompetitionCalibration() {
        configureReachCalibration(capturingCompetitionEvidence: true)
    }

    /// Runs reach setup without creating or looking up a competition player. The resulting
    /// bilateral measurement is cached by the session and reused by regular Reactive Strike and
    /// Combination runs.
    func configureReachCalibration() {
        configureReachCalibration(capturingCompetitionEvidence: false)
    }

    private func configureReachCalibration(capturingCompetitionEvidence: Bool) {
        configure(mode: .air, combination: nil, stance: stance)
        capturesCompetitionEvidence = capturingCompetitionEvidence
        calibrationOnly = true
        calibratedReaches[.air] = nil
        latestCalibratedReaches.removeAll()
        config.targetCount = CompetitionMode.reactiveStrike.totalSteps
        config.hitRadius = CompetitionScorer.targetRadius
        competitionRequiresRecalibration = false
        wasStoppedBeforeCompletion = false
    }

    func configureCompetition(
        mode: CompetitionMode,
        stance: Stance,
        reach: BilateralReach
    ) {
        let reactiveMode: ReactiveStrikeMode = mode == .combination ? .combination : .air
        configure(
            mode: reactiveMode,
            combination: mode == .combination ? .jabCrossHookCross : nil,
            stance: stance
        )
        capturesCompetitionEvidence = true
        calibrationOnly = false
        calibratedReaches[.air] = reach.bySide
        latestCalibratedReaches = reach.bySide
        comboRepeatCount = 5
        config.targetCount = CompetitionMode.reactiveStrike.totalSteps
        config.hitRadius = CompetitionScorer.targetRadius
        config.targetRadius = 0.08
        // A miss still counts, but the target remains available long enough that a deliberate
        // boxer does not experience an ordinary hesitation as the competition closing itself.
        config.timeout = 4
        competitionRequiresRecalibration = false
    }

    /// Makes the active player's comfortable reach available to regular Reactive Strike and
    /// Combo setup as well as ranked runs. Passing nil prevents one player's measurement leaking
    /// into the next player's target placement.
    func applyPersistedCompetitionReach(_ reach: BilateralReach?) {
        guard phase != .running, phase != .calibrating else { return }
        calibratedReaches[.air] = reach?.bySide
        latestCalibratedReaches = reach?.bySide ?? [:]
        reachProfile = reach.map {
            ReachProfile.air.calibrated(measuredForwardReach: $0.conservative)
        } ?? .air
    }


    /// Kept as a small convenience for callers that do not need Combination Mode.
    func selectMode(_ mode: ReactiveStrikeMode) {
        configure(mode: mode, combination: nil, stance: stance)
    }

    func attachSceneRoot(_ root: Entity) {
        targets.attach(to: root)
        auraPunch.attach(to: root)
    }

    func startDrill() {
        guard phase != .running, phase != .calibrating else { return }

        metrics.reset()
        currentTargetIndex = 0
        currentComboStepIndex = 0
        comboRepsCompleted = 0
        competitionSteps.removeAll(keepingCapacity: true)
        competitionTrackingStatus = .complete
        competitionActiveElapsedTime = nil
        competitionStartedAt = nil
        competitionElapsedClock = CompetitionElapsedClock()
        competitionRequiresRecalibration = false
        wasStoppedBeforeCompletion = false
        guardPositionsBody.removeAll()
        phase = .calibrating
        lastFeedback = "Raise both hands into guard"
        errorMessage = nil
        coachAudio.play(id: .guardUp)
        isTrackingPaused = false
        trackingReadyToResume = false
        trackingResumeRequested = false

        drillTask?.cancel()
        drillTask = Task { [weak self] in
            await self?.runDrillLoop()
        }
    }

    func stopDrill() {
        // Also covers a system-driven immersive dismissal. Aura Punch must stop here too or its
        // pose loop would keep running against tracking providers that no longer have a scene.
        auraPunch.stop()
        coachAudio.stop()

        drillTask?.cancel()
        drillTask = nil
        targets.removeActiveTarget()
        clearAttemptState()
        guardPositionsBody.removeAll()
        isTrackingPaused = false
        trackingReadyToResume = false
        trackingResumeRequested = false

        let stoppedActiveDrill = phase == .running || phase == .calibrating
        if stoppedActiveDrill {
            wasStoppedBeforeCompletion = true
            phase = metrics.attempts.isEmpty ? .idle : .finished
            lastFeedback = "Drill stopped"
        }
    }

    func resetForNewRound(keepingCompetitionConfiguration: Bool = false) {
        stopDrill()
        metrics.reset()
        phase = .idle
        currentTargetIndex = 0
        currentComboStepIndex = 0
        comboRepsCompleted = 0
        competitionSteps.removeAll(keepingCapacity: true)
        competitionTrackingStatus = .complete
        competitionActiveElapsedTime = nil
        competitionStartedAt = nil
        competitionElapsedClock = CompetitionElapsedClock()
        competitionRequiresRecalibration = false
        wasStoppedBeforeCompletion = false
        lastFeedback = "Ready"
        errorMessage = nil
        isTrackingPaused = false
        trackingReadyToResume = false
        trackingResumeRequested = false
        if !keepingCompetitionConfiguration {
            capturesCompetitionEvidence = false
            calibrationOnly = false
        }
    }

    func resetForParticipantHandoff() {
        resetForNewRound()
        hands.stop()
        targets.removeActiveTarget()
        calibratedReaches.removeAll()
        guardPositionsBody.removeAll()
        reachProfile = .air
        stance = .orthodox
        selectedCombination = .oneTwo
        comboRepeatCount = 5
    }

    func reportError(_ message: String?) {
        errorMessage = message
    }

    func clearError() {
        errorMessage = nil
    }

    private func runDrillLoop() async {
        await hands.start()
        guard !Task.isCancelled else { return }
        guard hands.isRunning else {
            failDrill(hands.statusMessage)
            return
        }

        guard let guards = await acquireGuardPositions() else {
            guard !Task.isCancelled else { return }
            failDrill("Keep both hands visible in guard so calibration can begin.")
            return
        }
        guardPositionsBody = guards

        let key = calibrationKey(for: mode)
        let maximumGuardForward = guards.values.map(\.z).max() ?? 0
        if let cached = calibratedReaches[key],
           let measuredReach = ReachCalibration.conservativeBilateralReach(cached) {
            if let guardedProfile = mode.reachProfile
                .calibrated(measuredForwardReach: measuredReach)
                .placingTargetsBeyondGuard(
                    maximumGuardForward: maximumGuardForward,
                    hitRadius: config.hitRadius
                ) {
                latestCalibratedReaches = cached
                reachProfile = guardedProfile
            } else if capturesCompetitionEvidence, !calibrationOnly {
                competitionRequiresRecalibration = true
                failDrill("Your saved reach no longer clears your current guard. Recalibrate before competing.")
                return
            } else {
                calibratedReaches[key] = nil
            }
        } else if calibratedReaches[key] != nil {
            calibratedReaches[key] = nil
        }

        if calibratedReaches[key] == nil {
            // A guard can move between rounds. If it now sits beyond the cached safe volume,
            // invalidate that measurement and collect a fresh extension instead of failing every
            // subsequent retry with the same stale profile.
            guard let measuredReaches = await calibrateReach(using: guards),
                  let measuredReach = ReachCalibration.conservativeBilateralReach(measuredReaches)
            else {
                guard !Task.isCancelled else { return }
                failDrill("Reach calibration timed out. Return to guard, then extend each arm only as far as comfortable.")
                return
            }
            let calibrated = mode.reachProfile.calibrated(measuredForwardReach: measuredReach)
            guard let guardedProfile = calibrated.placingTargetsBeyondGuard(
                maximumGuardForward: maximumGuardForward,
                hitRadius: config.hitRadius
            ) else {
                failDrill("Your guard and comfortable reach were too close together. Reset your guard and calibrate again.")
                return
            }
            calibratedReaches[key] = measuredReaches
            latestCalibratedReaches = measuredReaches
            reachProfile = guardedProfile
        }

        if calibrationOnly {
            competitionTrackingStatus = .complete
            phase = .finished
            lastFeedback = "Reach calibrated"
            coachAudio.play(id: .reachCalibrated)
            return
        }


        guard !Task.isCancelled, phase == .calibrating else { return }
        lastFeedback = "Return both hands to guard"
        guard await waitForGuardReturn(using: guards) else {
            guard !Task.isCancelled else { return }
            failDrill("Return both hands to guard before the round begins.")
            return
        }

        guard !Task.isCancelled, phase == .calibrating else { return }
        phase = .running
        lastFeedback = "Guard set · Get ready…"
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled, phase == .running else { return }
        if capturesCompetitionEvidence {
            competitionStartedAt = ProcessInfo.processInfo.systemUptime
            coachAudio.play(id: .countdown)
        }

        if mode == .combination {
            await runCombinationLoop()
        } else {
            await runTargetLoop()
        }

        guard !Task.isCancelled, phase == .running else { return }
        targets.removeActiveTarget()
        clearAttemptState()
        if let startedAt = competitionStartedAt {
            competitionActiveElapsedTime = competitionElapsedClock.activeElapsed(
                startedAt: startedAt,
                endedAt: ProcessInfo.processInfo.systemUptime
            )
        }
        phase = .finished
        lastFeedback = summaryFeedback()
    }






    /// Captures a fresh guard every round even when reach is cached. Combination validation uses
    /// these positions to require each punch to leave guard and return before the next step.
    private func acquireGuardPositions() async -> [BodySide: SIMD3<Float>]? {
        // Competition setup is user-paced. It remains cancellable via End Training but does not
        // eject someone merely because they needed more than a few seconds to read the cue.
        let deadline: Date? = capturesCompetitionEvidence ? nil : Date().addingTimeInterval(5)
        var leftTotal = SIMD3<Float>.zero
        var rightTotal = SIMD3<Float>.zero
        var sampleCount: Float = 0
        var lastPairTimestamp: TimeInterval?
        var trackingContinuity = TrackingContinuityObserver(epoch: hands.continuityEpoch)

        while !Task.isCancelled, deadline.map({ Date() < $0 }) ?? true, phase == .calibrating {
            if trackingContinuity.observe(hands.continuityEpoch) {
                leftTotal = .zero
                rightTotal = .zero
                sampleCount = 0
                lastPairTimestamp = nil
                continue
            }
            if let frame = currentBodyFrame(),
               let left = hands.leftHand,
               let right = hands.rightHand {
                let pairTimestamp = min(left.timestamp, right.timestamp)
                let isFreshPair = lastPairTimestamp.map { pairTimestamp > $0 } ?? true
                let leftBody = frame.toBody(left.fistPosition)
                let rightBody = frame.toBody(right.fistPosition)
                let handsAreNearHead = distance(left.fistPosition, frame.headPosition) <= 0.45
                    && distance(right.fistPosition, frame.headPosition) <= 0.45

                if isFreshPair, leftBody.isFinite, rightBody.isFinite, handsAreNearHead {
                    lastPairTimestamp = pairTimestamp
                    leftTotal += leftBody
                    rightTotal += rightBody
                    sampleCount += 1
                    if sampleCount >= 12 {
                        return [
                            .left: leftTotal / sampleCount,
                            .right: rightTotal / sampleCount
                        ]
                    }
                }
            }

            try? await Task.sleep(for: .milliseconds(25))
        }

        return nil
    }

    /// Measures forward fist reach in body space, never by taking `abs(worldZ)`. Room origin,
    /// translation, and the wall the user faces therefore cannot change the result.
    private func calibrateReach(
        using guards: [BodySide: SIMD3<Float>]
    ) async -> [BodySide: Float]? {
        var initialFrame = currentBodyFrame()
        while initialFrame == nil,
              capturesCompetitionEvidence,
              !Task.isCancelled,
              phase == .calibrating {
            try? await Task.sleep(for: .milliseconds(25))
            initialFrame = currentBodyFrame()
        }
        guard let frame = initialFrame else { return nil }

        phase = .calibrating
        lastFeedback = "Keep a relaxed closed fist, punch out, and hold — left arm first"
        coachAudio.play(id: .calibrateReach)

        // Keep the cue at a neutral reference distance. Placing it at an authored profile edge can
        // encourage a shorter user to lean, moving the body frame while reach is being measured.
        let cueBodyPosition = SIMD3<Float>(0, 0.02, BodyMeasurements.averageAdult.armReach)
        targets.spawnTarget(
            at: frame.toWorld(cueBodyPosition),
            radius: config.targetRadius * 1.25
        )

        defer { targets.removeActiveTarget() }

        // Allow enough time to observe a settled hold from each arm, not merely the outbound ramp.
        let deadline: Date? = capturesCompetitionEvidence ? nil : Date().addingTimeInterval(14)
        var acceptedSamples: [BodySide: [ReachSample]] = [.left: [], .right: []]
        var lastAcceptedTimestamp: [BodySide: TimeInterval] = [:]
        var lastProcessedTimestamp: [BodySide: TimeInterval] = [:]
        var measuredReaches: [BodySide: Float] = [:]
        var trackingContinuity = TrackingContinuityObserver(epoch: hands.continuityEpoch)

        while !Task.isCancelled, deadline.map({ Date() < $0 }) ?? true, phase == .calibrating {
            if trackingContinuity.observe(hands.continuityEpoch) {
                acceptedSamples = [.left: [], .right: []]
                lastAcceptedTimestamp.removeAll(keepingCapacity: true)
                lastProcessedTimestamp.removeAll(keepingCapacity: true)
                measuredReaches.removeAll(keepingCapacity: true)
                lastFeedback = "Tracking changed · Restarting reach calibration"
                continue
            }
            if let liveFrame = currentBodyFrame() {
                for side in [BodySide.left, .right] where measuredReaches[side] == nil {
                    guard let guardPosition = guards[side],
                          let observation = hands.observation(for: side),
                          observation.timestamp > (lastProcessedTimestamp[side] ?? -.infinity)
                    else { continue }
                    lastProcessedTimestamp[side] = observation.timestamp

                    let fistBody = liveFrame.toBody(observation.fistPosition)
                    guard let candidate = ReachCalibration.candidateForwardReach(
                        guardPosition: guardPosition,
                        fistPosition: fistBody
                    ) else { continue }

                    // Do not splice separate extensions into one apparent hold after tracking or
                    // the candidate motion drops out for a material interval.
                    if let previous = lastAcceptedTimestamp[side],
                       observation.timestamp - previous > 0.5 {
                        acceptedSamples[side] = []
                    }
                    acceptedSamples[side, default: []].append(
                        ReachSample(forward: candidate, time: observation.timestamp)
                    )
                    lastAcceptedTimestamp[side] = observation.timestamp

                    guard let settled = ReachCalibration.settledForwardReach(
                        from: acceptedSamples[side, default: []]
                    ) else { continue }

                    measuredReaches[side] = settled
                    if measuredReaches.count == 1 {
                        lastFeedback = "Keep your fist closed, then punch out and hold with your \(side.opposite.rawValue) arm"
                        coachAudio.play(id: .extendOtherArm)
                    } else {
                        lastFeedback = "Reach calibrated"
                        coachAudio.play(id: .reachCalibrated)
                    }
                }
            }

            if ReachCalibration.conservativeBilateralReach(measuredReaches) != nil {
                targets.flash(result: .hit)
                try? await Task.sleep(for: .milliseconds(180))
                return measuredReaches
            }

            try? await Task.sleep(for: .milliseconds(16))
        }

        guard !Task.isCancelled else { return nil }

        // If a steady plateau was not observed before the deadline, retain the previous robust
        // percentile fallback so a usable capture can still complete instead of stranding setup.
        for side in [BodySide.left, .right] where measuredReaches[side] == nil {
            if let fallback = ReachCalibration.robustForwardReach(
                from: acceptedSamples[side, default: []].map(\.forward)
            ) {
                measuredReaches[side] = fallback
            }
        }

        return ReachCalibration.conservativeBilateralReach(measuredReaches) != nil
            ? measuredReaches
            : nil
    }

    private func waitForGuardReturn(
        using guards: [BodySide: SIMD3<Float>]
    ) async -> Bool {
        let deadline: Date? = capturesCompetitionEvidence ? nil : Date().addingTimeInterval(2.5)
        var consecutiveFreshSamples = 0
        var lastPairTimestamp: TimeInterval?

        while !Task.isCancelled, deadline.map({ Date() < $0 }) ?? true, phase == .calibrating {
            if let frame = currentBodyFrame(),
               let left = hands.leftHand,
               let right = hands.rightHand,
               let leftGuard = guards[.left],
               let rightGuard = guards[.right] {
                let pairTimestamp = min(left.timestamp, right.timestamp)
                let isFreshPair = lastPairTimestamp.map { pairTimestamp > $0 } ?? true
                if isFreshPair {
                    lastPairTimestamp = pairTimestamp
                    let leftIsReady = CombinationPunchValidator.isRetracted(
                        fist: frame.toBody(left.fistPosition),
                        guardPosition: leftGuard,
                        radius: CombinationPunchValidator.guardRadius
                    )
                    let rightIsReady = CombinationPunchValidator.isRetracted(
                        fist: frame.toBody(right.fistPosition),
                        guardPosition: rightGuard,
                        radius: CombinationPunchValidator.guardRadius
                    )
                    consecutiveFreshSamples = leftIsReady && rightIsReady
                        ? consecutiveFreshSamples + 1
                        : 0
                    if consecutiveFreshSamples >= 3 { return true }
                }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        return false
    }

    private typealias TargetPresentationOutcome = ReactiveTargetRetryPlan.Outcome

    private func runTargetLoop() async {
        for index in 0..<config.targetCount {
            guard !Task.isCancelled, phase == .running else { return }
            currentTargetIndex = index

            guard var retryPlan = await makeReactiveTargetRetryPlan() else { return }

            var outcome: TargetPresentationOutcome = .retry
            while outcome == .retry {
                guard let targetPosition = retryPlan.targetPosition else { return }
                outcome = await presentTarget(at: targetPosition)
                retryPlan.record(outcome)
                guard !Task.isCancelled, phase == .running else { return }
            }
            guard outcome == .completed else { return }

            if index < config.targetCount - 1 {
                try? await Task.sleep(for: .seconds(config.interTargetDelay))
            }
        }
    }

    private func makeReactiveTargetRetryPlan() async -> ReactiveTargetRetryPlan? {
        while !Task.isCancelled, phase == .running {
            if let frame = await waitForRequiredBodyFrame() {
                let bodyPosition = reachProfile.randomBodyTargetPosition()
                return ReactiveTargetRetryPlan(
                    targetPosition: frame.toWorld(bodyPosition)
                )
            }
            guard !Task.isCancelled else { return nil }
            if capturesCompetitionEvidence {
                guard await recoverCompetitionTracking() else { return nil }
                continue
            }
            failDrill("Head tracking was lost. Face forward and try the round again.")
            return nil
        }
        return nil
    }

    private func presentTarget(
        at worldPosition: SIMD3<Float>
    ) async -> TargetPresentationOutcome {
        guard let frame = await waitForRequiredBodyFrame() else {
            guard !Task.isCancelled else { return .aborted }
            if capturesCompetitionEvidence {
                return await recoverCompetitionTracking() ? .retry : .aborted
            }
            failDrill("Head tracking was lost. Face forward and try the round again.")
            return .aborted
        }

        let worldGuards = guardPositionsBody.mapValues(frame.toWorld)
        targets.spawnTarget(at: worldPosition, radius: config.targetRadius)

        let captureChain = PunchEvidenceCaptureChain(
            generation: hands.providerGeneration,
            continuityEpoch: hands.continuityEpoch
        )
        var selector = PunchEvidenceSideSelector(
            // An unsequenced reactive target accepts either physical hand. The selector still
            // locks the first validated outbound side and keeps it fixed through retraction.
            technique: .hook,
            stance: stance,
            guardPositions: worldGuards,
            targetPosition: worldPosition,
            targetRadius: config.hitRadius,
            generation: captureChain.generation,
            continuityEpoch: captureChain.continuityEpoch
        )

        beginAttempt(fistAtSpawn: nil)
        lastFeedback = "Punch!"
        if capturesCompetitionEvidence {
            coachAudio.play(id: .hitTarget)
        }

        var activeElapsed: TimeInterval = 0
        var lastTick = Date()
        var trackingLostAt: Date?
        var guardPausedAt: Date?
        var contactTime: Date?
        var contactFist: SIMD3<Float>?
        var lastEvidenceTimestamps: [BodySide: TimeInterval] = [:]
        var evidencePollCount = 0
        var trackedPollCount: [BodySide: Int] = [:]

        while !Task.isCancelled, phase == .running, activeAttemptID != nil {
            let now = Date()
            let evidenceNow = CACurrentMediaTime()

            guard hands.providerGeneration == captureChain.generation,
                  hands.continuityEpoch == captureChain.continuityEpoch else {
                if capturesCompetitionEvidence {
                    return await recoverCompetitionTracking() ? .retry : .aborted
                }
                await discardAttempt(
                    feedback: "Tracking changed · punch discarded",
                    preserveTarget: true
                )
                return .retry
            }

            if !capturesCompetitionEvidence, let selectedSide = selector.trackingHand {
                let trackingDecision = ReactiveTargetTrackingPolicy.decision(
                    selectedSide: selectedSide,
                    requiredHandAvailable: hands.freshObservation(for: selectedSide) != nil,
                    otherHandAvailable: hands.freshObservation(for: selectedSide.opposite) != nil,
                    devicePoseAvailable: hands.deviceTransform != nil
                )
                if trackingDecision == .discardAndRetry {
                    await discardAttempt(
                        feedback: "Tracking paused · punch discarded",
                        preserveTarget: true
                    )
                    return .retry
                }
            }

            if capturesCompetitionEvidence {
                let hasFreshPair = hands.freshObservation(for: .left) != nil
                    && hands.freshObservation(for: .right) != nil
                    && hands.deviceTransform != nil
                if !hasFreshPair {
                    competitionElapsedClock.beginPause(
                        at: ProcessInfo.processInfo.systemUptime
                    )
                    trackingLostAt = trackingLostAt ?? now
                    if now.timeIntervalSince(trackingLostAt!)
                        >= CompetitionTrackingRecoveryGate.lossGraceSeconds {
                        return await recoverCompetitionTracking() ? .retry : .aborted
                    }
                    lastTick = now
                    try? await Task.sleep(for: .milliseconds(16))
                    continue
                }
                if let trackingLostAt {
                    shiftAttemptStart(by: now.timeIntervalSince(trackingLostAt))
                    competitionElapsedClock.endPause(
                        at: ProcessInfo.processInfo.systemUptime
                    )
                    lastTick = now
                }
                trackingLostAt = nil
            }

            evidencePollCount += 1
            for side in [BodySide.left, .right]
            where hands.freshObservation(for: side) != nil {
                trackedPollCount[side, default: 0] += 1
            }

            var selectorEvent = PunchEvidenceSideSelector.Event.waiting
            if let evidenceFrame = punchEvidenceFrame(
                now: evidenceNow,
                requiredSide: selector.trackingHand
            ) {
                let hasNewAnchor = evidenceFrame.hands.contains { sample in
                    sample.acquisitionTimestamp
                        > (lastEvidenceTimestamps[sample.side] ?? -.infinity)
                }
                if hasNewAnchor {
                    for sample in evidenceFrame.hands {
                        lastEvidenceTimestamps[sample.side] = max(
                            lastEvidenceTimestamps[sample.side] ?? -.infinity,
                            sample.acquisitionTimestamp
                        )
                    }
                    selectorEvent = selector.observe(evidenceFrame)
                }
            }

            var selectedSide: BodySide?
            var attemptAction: PunchEvidenceAttemptAction?
            switch selectorEvent {
            case .waiting:
                break
            case let .invalid(reason):
                await discardAttempt(
                    feedback: PunchEvidenceFeedback.message(for: reason),
                    preserveTarget: true
                )
                return .retry
            case let .selected(side, event):
                selectedSide = side
                attemptAction = PunchEvidenceAttemptAction(event: event)
                if fistPositionAtSpawn == nil {
                    fistPositionAtSpawn = fistPositionsAtSpawn[side]
                }
                if case let .retry(reason) = attemptAction {
                    await discardAttempt(
                        feedback: PunchEvidenceFeedback.message(for: reason),
                        preserveTarget: true
                    )
                    return .retry
                }
            }

            let shouldPauseForGuard: Bool
            if let requiredHand = selector.trackingHand {
                shouldPauseForGuard = nonPunchingGuardStatus(punchingSide: requiredHand) != true
            } else {
                // Before validated outbound motion identifies a side, both fists stay in their
                // captured guard. Target proximity never chooses the required hand.
                shouldPauseForGuard = guardStatus(for: .left) != true
                    || guardStatus(for: .right) != true
            }
            if shouldPauseForGuard {
                if attemptAction?.canBeDeferredByGuard == false {
                    // Contact/retraction/coverage events are one-shot reducer transitions. Once
                    // one arrives, a dropped guard invalidates and retries the whole target rather
                    // than consuming that transition behind the coaching pause.
                    await discardAttempt(
                        feedback: GuardCoach.waitMessage,
                        preserveTarget: true
                    )
                    return .retry
                }
                guardPausedAt = guardPausedAt ?? now
                lastFeedback = GuardCoach.waitMessage
                lastTick = now
                try? await Task.sleep(for: .milliseconds(16))
                continue
            }

            if let guardPausedAt {
                shiftAttemptStart(by: now.timeIntervalSince(guardPausedAt))
                self.lastFeedback = "Punch!"
                lastTick = now
            }
            guardPausedAt = nil

            if lastFeedback == GuardCoach.waitMessage {
                lastFeedback = "Punch!"
            }

            activeElapsed += now.timeIntervalSince(lastTick)
            lastTick = now

            if activeElapsed >= config.timeout {
                let side = selector.requiredHand
                await finishAttempt(
                    result: .miss,
                    hitTime: nil,
                    fistAtHit: side.flatMap { hands.freshObservation(for: $0)?.fistPosition },
                    targetPosition: worldPosition
                )
                return .completed
            }

            switch attemptAction {
            case nil, .waiting:
                break
            case .armed:
                if let selectedSide {
                    lastFeedback = PunchEvidenceFeedback.strikeNow(side: selectedSide)
                }
            case .contact:
                guard let selectedSide else {
                    await discardAttempt(
                        feedback: "Punch evidence was invalid · reset in guard",
                        preserveTarget: true
                    )
                    return .retry
                }
                contactTime = contactTime ?? now
                contactFist = contactFist
                    ?? hands.freshObservation(for: selectedSide)?.fistPosition
                lastFeedback = PunchEvidenceFeedback.returnToGuard(
                    side: selectedSide,
                    style: .return
                )
            case .completeCoverage:
                guard let selectedSide else {
                    await discardAttempt(
                        feedback: "Punch evidence was invalid · reset in guard",
                        preserveTarget: true
                    )
                    return .retry
                }
                let trackedFraction = Float(trackedPollCount[selectedSide, default: 0])
                    / Float(max(1, evidencePollCount))
                guard let coverage = captureChain.coverage(
                    trackedFraction: trackedFraction,
                    currentGeneration: hands.providerGeneration,
                    currentContinuityEpoch: hands.continuityEpoch
                ) else {
                    await discardAttempt(
                        feedback: "Tracking changed · punch discarded",
                        preserveTarget: true
                    )
                    return .retry
                }

                guard case let .selected(_, completionEvent) = selector.complete(
                    coverage: coverage
                ) else {
                    await discardAttempt(
                        feedback: "Punch evidence was invalid · reset in guard",
                        preserveTarget: true
                    )
                    return .retry
                }
                switch PunchEvidenceAttemptAction(event: completionEvent) {
                case let .admit(evidence):
                    await finishAttempt(
                        result: .hit,
                        hitTime: wallClockDate(
                            forAcquisitionTimestamp: evidence.landedAt,
                            fallback: contactTime ?? now
                        ),
                        fistAtHit: contactFist
                            ?? hands.freshObservation(for: selectedSide)?.fistPosition,
                        targetPosition: worldPosition,
                        landingError: evidence.landingError
                    )
                    return .completed
                case let .retry(reason):
                    await discardAttempt(
                        feedback: PunchEvidenceFeedback.message(for: reason),
                        preserveTarget: true
                    )
                    return .retry
                case .waiting, .armed, .contact, .completeCoverage:
                    await discardAttempt(
                        feedback: "Punch evidence was incomplete",
                        preserveTarget: true
                    )
                    return .retry
                }
            case let .retry(reason):
                await discardAttempt(
                    feedback: PunchEvidenceFeedback.message(for: reason),
                    preserveTarget: true
                )
                return .retry
            case .admit:
                // Admission is produced only by the explicit coverage completion above.
                await discardAttempt(
                    feedback: "Punch evidence was invalid · reset in guard",
                    preserveTarget: true
                )
                return .retry
            }

            try? await Task.sleep(for: .milliseconds(16))
        }

        return .aborted
    }

    /// Discards only the technically interrupted target, then waits in-place for stable body and
    /// hand tracking. Returning to guard resumes automatically; no score or miss is created from
    /// stale samples, and the immersive space stays open so the run can still finish and submit.
    private func recoverCompetitionTracking() async -> Bool {
        guard capturesCompetitionEvidence, phase == .running else { return false }

        competitionElapsedClock.beginPause(at: ProcessInfo.processInfo.systemUptime)
        targets.removeActiveTarget()
        clearAttemptState()
        isTrackingPaused = true
        trackingReadyToResume = false
        lastFeedback = "Tracking paused · Hold both fists in guard and look forward"

        defer {
            competitionElapsedClock.endPause(at: ProcessInfo.processInfo.systemUptime)
            isTrackingPaused = false
            trackingReadyToResume = false
        }

        var gate = CompetitionTrackingRecoveryGate()
        var lastPairTimestamp: TimeInterval?

        while !Task.isCancelled, phase == .running {
            var recoverySample: Bool?
            var hasFreshInputs = false
            if let frame = currentBodyFrame(),
               let left = hands.freshObservation(for: .left),
               let right = hands.freshObservation(for: .right),
               let leftGuard = guardPositionsBody[.left],
               let rightGuard = guardPositionsBody[.right] {
                hasFreshInputs = true
                let pairTimestamp = min(left.timestamp, right.timestamp)
                let isNewPair = lastPairTimestamp.map { pairTimestamp > $0 } ?? true
                if isNewPair {
                    lastPairTimestamp = pairTimestamp
                    recoverySample = CombinationPunchValidator.isRetracted(
                        fist: frame.toBody(left.fistPosition),
                        guardPosition: leftGuard,
                        radius: CombinationPunchValidator.guardRadius
                    ) && CombinationPunchValidator.isRetracted(
                        fist: frame.toBody(right.fistPosition),
                        guardPosition: rightGuard,
                        radius: CombinationPunchValidator.guardRadius
                    )
                }
            }

            if !hasFreshInputs {
                _ = gate.observe(freshAndGuarded: false)
            }

            if let recoverySample,
               gate.observe(freshAndGuarded: recoverySample) {
                trackingReadyToResume = true
                lastFeedback = "Tracking restored · Resuming"
                try? await Task.sleep(for: .milliseconds(180))
                if !Task.isCancelled,
                   phase == .running,
                   currentBodyFrame() != nil,
                   hands.freshObservation(for: .left) != nil,
                   hands.freshObservation(for: .right) != nil {
                    return true
                }
                trackingReadyToResume = false
                lastFeedback = "Tracking paused · Hold both fists in guard and look forward"
                gate = CompetitionTrackingRecoveryGate()
            }

            try? await Task.sleep(for: .milliseconds(25))
        }

        return false
    }

    /// Normal combination rounds fail closed on any tracking-chain interruption. They remain on
    /// the same authored target until three new, coherent bilateral samples establish guard again.
    /// No attempt or ranked evidence is created while this recovery gate is active.
    private func waitForNormalCombinationGuardRecovery() async -> Bool {
        lastFeedback = "Tracking paused · hold both fists in guard"

        var gate = NormalCombinationGuardRecoveryGate()

        while !Task.isCancelled, phase == .running {
            guard let frame = currentBodyFrame(),
                  let left = hands.freshObservation(for: .left),
                  let right = hands.freshObservation(for: .right),
                  let leftGuard = guardPositionsBody[.left],
                  let rightGuard = guardPositionsBody[.right]
            else {
                _ = gate.observe(
                    .init(
                        providerGeneration: hands.providerGeneration,
                        continuityEpoch: hands.continuityEpoch,
                        pairTimestamp: nil,
                        observationsFresh: false,
                        freshClosedAndGuarded: false
                    )
                )
                try? await Task.sleep(for: .milliseconds(25))
                continue
            }

            let pairTimestamp = min(left.acquisitionTimestamp, right.acquisitionTimestamp)
            let isFreshGuard = left.fistState == .closed
                && right.fistState == .closed
                && CombinationPunchValidator.isRetracted(
                    fist: frame.toBody(left.fistPosition),
                    guardPosition: leftGuard,
                    radius: CombinationPunchValidator.guardRadius
                )
                && CombinationPunchValidator.isRetracted(
                    fist: frame.toBody(right.fistPosition),
                    guardPosition: rightGuard,
                    radius: CombinationPunchValidator.guardRadius
                )
            if gate.observe(
                .init(
                    providerGeneration: hands.providerGeneration,
                    continuityEpoch: hands.continuityEpoch,
                    pairTimestamp: pairTimestamp,
                    observationsFresh: true,
                    freshClosedAndGuarded: isFreshGuard
                )
            ) {
                lastFeedback = "Tracking restored · retrying punch"
                return true
            }

            try? await Task.sleep(for: .milliseconds(25))
        }

        return false
    }

    /// Presents exactly one combination target at a time. Each step validates the stance-derived
    /// physical hand and outbound motion, then requires that hand to retract before another target
    /// is allowed to appear. That makes repeated positions such as a double jab unambiguous.
    private func runCombinationLoop() async {
        let combination = selectedCombination
        guard let resolvedTargets = resolvedCombinationTargets(for: combination) else {
            failDrill("Your calibrated reach leaves too little room beyond guard for this combination.")
            return
        }

        for rep in 0..<comboRepeatCount {
            guard !Task.isCancelled, phase == .running else { return }
            currentTargetIndex = rep
            var completedRep = true

            targetLoop: for target in resolvedTargets {
                evidenceRetryLoop: while true {
                guard !Task.isCancelled, phase == .running else { return }
                currentComboStepIndex = target.index

                guard let guardPosition = guardPositionsBody[target.requiredHand] else {
                    failDrill("Guard calibration was unavailable for this combination.")
                    return
                }
                var availableFrame = await waitForRequiredBodyFrame()
                while availableFrame == nil && capturesCompetitionEvidence {
                    guard await recoverCompetitionTracking() else { return }
                    availableFrame = await waitForRequiredBodyFrame()
                }
                guard let frame = availableFrame else {
                    guard !Task.isCancelled else { return }
                    failDrill("Tracking was lost while preparing the combination.")
                    return
                }

                var worldPosition = frame.toWorld(target.position)
                var worldGuardPosition = frame.toWorld(guardPosition)
                targets.spawnTarget(at: worldPosition, radius: config.targetRadius)

                let requiredObservation = hands.freshObservation(for: target.requiredHand)
                beginAttempt(fistAtSpawn: requiredObservation?.fistPosition)
                lastFeedback = "\(target.punch.displayName)!"

                var worldTarget = CombinationTarget(
                    id: target.id,
                    index: target.index,
                    punch: target.punch,
                    requiredHand: target.requiredHand,
                    position: worldPosition
                )
                var captureChain = PunchEvidenceCaptureChain(
                    generation: hands.providerGeneration,
                    continuityEpoch: hands.continuityEpoch
                )
                var validator = CombinationPunchValidator(
                    target: worldTarget,
                    stance: stance,
                    guardPosition: worldGuardPosition,
                    hitRadius: config.hitRadius,
                    generation: captureChain.generation,
                    continuityEpoch: captureChain.continuityEpoch
                )
                var deadline = Date().addingTimeInterval(config.timeout)
                var stepHit = false
                var retryInvalidEvidence = false
                var centerError: Float?
                var reactionTime: TimeInterval?
                var contactTime: Date?
                var contactFist: SIMD3<Float>?
                var trackingLostAt: Date?
                var evidencePollCount = 0
                var trackedPollCount = 0
                var lastEvidenceTimestamps: [BodySide: TimeInterval] = [:]

                while !Task.isCancelled,
                      phase == .running,
                      activeAttemptID != nil {
                    let required = hands.freshObservation(for: target.requiredHand)
                    let other = hands.freshObservation(for: target.requiredHand.opposite)

                    let trackingDecision = CombinationTrackingInterruptionPolicy.decision(
                        input: .init(
                            requiredHandAvailable: required != nil,
                            otherHandAvailable: other != nil,
                            devicePoseAvailable: hands.deviceTransform != nil,
                            expectedGeneration: captureChain.generation,
                            currentGeneration: hands.providerGeneration,
                            expectedContinuityEpoch: captureChain.continuityEpoch,
                            currentContinuityEpoch: hands.continuityEpoch
                        ),
                        capturesCompetitionEvidence: capturesCompetitionEvidence
                    )
                    switch trackingDecision {
                    case .continueAttempt:
                        if let trackingLostAt {
                            let resumedAt = Date()
                            let lossDuration = resumedAt.timeIntervalSince(trackingLostAt)
                            switch CompetitionTrackingOutagePolicy.decision(
                                trackingAvailable: true,
                                lossDuration: lossDuration
                            ) {
                            case let .resume(pausedDuration):
                                deadline = CompetitionTrackingOutagePolicy.compensatedDeadline(
                                    deadline,
                                    pausedDuration: pausedDuration
                                )
                                shiftAttemptStart(by: pausedDuration)
                                competitionElapsedClock.endPause(
                                    at: ProcessInfo.processInfo.systemUptime
                                )
                            case .recover:
                                guard await recoverCompetitionTracking() else { return }
                                continue evidenceRetryLoop
                            case .wait:
                                break
                            }
                        }
                        trackingLostAt = nil
                    case .discardAndRetry:
                        await discardAttempt(
                            feedback: "Tracking paused · return both fists to guard"
                        )
                        guard await waitForNormalCombinationGuardRecovery() else { return }
                        continue evidenceRetryLoop
                    case .competitionRecovery:
                        let now = Date()
                        competitionElapsedClock.beginPause(
                            at: ProcessInfo.processInfo.systemUptime
                        )
                        trackingLostAt = trackingLostAt ?? now
                        let lossDuration = now.timeIntervalSince(trackingLostAt!)
                        if CompetitionTrackingOutagePolicy.decision(
                            trackingAvailable: false,
                            lossDuration: lossDuration
                        ) == .recover {
                            guard await recoverCompetitionTracking() else { return }
                            var availableRecoveredFrame = currentBodyFrame()
                            while availableRecoveredFrame == nil {
                                guard await recoverCompetitionTracking() else { return }
                                availableRecoveredFrame = currentBodyFrame()
                            }
                            guard let recoveredFrame = availableRecoveredFrame else { return }

                            worldPosition = recoveredFrame.toWorld(target.position)
                            worldGuardPosition = recoveredFrame.toWorld(guardPosition)
                            worldTarget = CombinationTarget(
                                id: target.id,
                                index: target.index,
                                punch: target.punch,
                                requiredHand: target.requiredHand,
                                position: worldPosition
                            )
                            captureChain = PunchEvidenceCaptureChain(
                                generation: hands.providerGeneration,
                                continuityEpoch: hands.continuityEpoch
                            )
                            validator = CombinationPunchValidator(
                                target: worldTarget,
                                stance: stance,
                                guardPosition: worldGuardPosition,
                                hitRadius: config.hitRadius,
                                generation: captureChain.generation,
                                continuityEpoch: captureChain.continuityEpoch
                            )
                            targets.spawnTarget(at: worldPosition, radius: config.targetRadius)
                            beginAttempt(
                                fistAtSpawn: hands.freshObservation(for: target.requiredHand)?.fistPosition
                            )
                            deadline = Date().addingTimeInterval(config.timeout)
                            contactTime = nil
                            contactFist = nil
                            evidencePollCount = 0
                            trackedPollCount = 0
                            lastEvidenceTimestamps.removeAll(keepingCapacity: true)
                            trackingLostAt = nil
                            lastFeedback = "\(target.punch.displayName)!"
                        }
                        try? await Task.sleep(for: .milliseconds(16))
                        continue
                    }
                    if Date() >= deadline {
                        await finishAttempt(
                            result: .miss,
                            hitTime: nil,
                            fistAtHit: hands.freshObservation(for: target.requiredHand)?.fistPosition,
                            targetPosition: worldPosition
                        )
                        break
                    }

                    evidencePollCount += 1
                    if required != nil { trackedPollCount += 1 }

                    if let evidenceFrame = punchEvidenceFrame(
                        now: CACurrentMediaTime(),
                        requiredSide: target.requiredHand
                    ) {
                        let hasNewAnchor = evidenceFrame.hands.contains { sample in
                            sample.acquisitionTimestamp
                                > (lastEvidenceTimestamps[sample.side] ?? -.infinity)
                        }
                        if hasNewAnchor {
                            for sample in evidenceFrame.hands {
                                lastEvidenceTimestamps[sample.side] = max(
                                    lastEvidenceTimestamps[sample.side] ?? -.infinity,
                                    sample.acquisitionTimestamp
                                )
                            }

                            switch validator.observe(evidenceFrame) {
                            case .waiting:
                                break
                            case .armed:
                                lastFeedback = "\(target.punch.displayName) · strike now"
                            case .contact:
                                contactTime = contactTime ?? Date()
                                contactFist = contactFist ?? required?.fistPosition
                                lastFeedback = PunchEvidenceFeedback.returnToGuard(
                                    side: target.requiredHand,
                                    style: .return
                                )
                            case .readyForCoverage:
                                let trackedFraction = Float(trackedPollCount)
                                    / Float(max(1, evidencePollCount))
                                guard let coverage = captureChain.coverage(
                                    trackedFraction: trackedFraction,
                                    currentGeneration: hands.providerGeneration,
                                    currentContinuityEpoch: hands.continuityEpoch
                                ) else {
                                    await discardAttempt(
                                        feedback: "Tracking changed · punch discarded"
                                    )
                                    retryInvalidEvidence = true
                                    break
                                }
                                switch PunchEvidenceAttemptAction(
                                    event: validator.complete(coverage: coverage)
                                ) {
                                case let .admit(evidence):
                                    await finishAttempt(
                                        result: .hit,
                                        hitTime: wallClockDate(
                                            forAcquisitionTimestamp: evidence.landedAt,
                                            fallback: contactTime ?? Date()
                                        ),
                                        fistAtHit: contactFist ?? required?.fistPosition,
                                        targetPosition: worldPosition,
                                        landingError: evidence.landingError
                                    )
                                    stepHit = true
                                    centerError = evidence.landingError
                                    reactionTime = metrics.lastAttempt?.reactionTime
                                case let .retry(reason):
                                    await discardAttempt(
                                        feedback: PunchEvidenceFeedback.message(for: reason)
                                    )
                                    retryInvalidEvidence = true
                                case .waiting, .armed, .contact, .completeCoverage:
                                    await discardAttempt(feedback: "Punch evidence was incomplete")
                                    retryInvalidEvidence = true
                                }
                            case let .invalid(reason):
                                await discardAttempt(
                                    feedback: PunchEvidenceFeedback.message(for: reason)
                                )
                                retryInvalidEvidence = true
                            case .validated:
                                break
                            }
                        }
                    }

                    if stepHit { break }
                    try? await Task.sleep(for: .milliseconds(16))
                }

                guard !Task.isCancelled, phase == .running else { return }
                guard stepHit else {
                    if retryInvalidEvidence { continue evidenceRetryLoop }
                    completedRep = false
                    if capturesCompetitionEvidence {
                        competitionSteps.append(CompetitionStepEvidence(
                            index: rep * resolvedTargets.count + target.index,
                            valid: false,
                            centreErrorMeters: nil,
                            reactionTime: nil,
                            requiredHand: target.requiredHand,
                            returnedToGuard: false
                        ))
                    }
                    if capturesCompetitionEvidence { break evidenceRetryLoop }
                    break targetLoop
                }

                if capturesCompetitionEvidence {
                    competitionSteps.append(CompetitionStepEvidence(
                        index: rep * resolvedTargets.count + target.index,
                        valid: true,
                        centreErrorMeters: centerError,
                        reactionTime: reactionTime,
                        requiredHand: target.requiredHand,
                        returnedToGuard: true
                    ))
                }
                break evidenceRetryLoop
                }
            }

            if completedRep {
                comboRepsCompleted += 1
                lastFeedback = "Combination complete"
            }

            targets.removeActiveTarget()
            clearAttemptState()

            if rep < comboRepeatCount - 1 {
                try? await Task.sleep(for: .seconds(config.interTargetDelay))
            }
        }
    }

    /// Resolves the authored punch layout against each required hand's captured guard. A target
    /// that is too close to guard can never produce the ordered guard → outbound → hit states, so
    /// push only its forward component far enough to make the validator usable. The cap is 105% of
    /// the conservative target reach, which remains within the user's measured full extension.
    private func resolvedCombinationTargets(
        for combination: Combination
    ) -> [CombinationTarget]? {
        let authored = combination.targets(
            forwardBase: reachProfile.forwardMax,
            stance: stance
        )
        let minimumSeparation = max(
            max(
                CombinationPunchValidator.guardRadius,
                CombinationPunchValidator.minimumOutwardTravel
            ),
            config.hitRadius
        ) + 0.02
        let maximumForward = reachProfile.forwardMax * 1.05
        guard let resolved = CombinationTargetResolver.resolve(
            authored,
            guardPositions: guardPositionsBody,
            minimumSeparation: minimumSeparation,
            maximumForward: maximumForward
        ) else { return nil }

        for adjusted in resolved {
            guard let guardPosition = guardPositionsBody[adjusted.requiredHand] else { return nil }
            let validator = CombinationPunchValidator(
                target: adjusted,
                stance: stance,
                guardPosition: guardPosition,
                hitRadius: config.hitRadius,
                generation: hands.providerGeneration,
                continuityEpoch: hands.continuityEpoch
            )
            guard validator.isValidConfiguration else { return nil }
        }

        return resolved
    }

    private func beginAttempt(fistAtSpawn: SIMD3<Float>?) {
        activeAttemptID = UUID()
        spawnTime = Date()
        fistPositionAtSpawn = fistAtSpawn
        fistPositionsAtSpawn = Dictionary(uniqueKeysWithValues: [BodySide.left, .right]
            .compactMap { side in
                hands.freshObservation(for: side).map { (side, $0.fistPosition) }
            })
    }

    private func shiftAttemptStart(by pausedDuration: TimeInterval) {
        guard pausedDuration.isFinite, pausedDuration > 0, let spawnTime else { return }
        self.spawnTime = spawnTime.addingTimeInterval(pausedDuration)
    }

    private func finishAttempt(
        result: AttemptResult,
        hitTime: Date?,
        fistAtHit: SIMD3<Float>?,
        targetPosition: SIMD3<Float>,
        landingError: Float? = nil,
        feedback: String? = nil
    ) async {
        guard let spawnTime else { return }

        var travel: Float?
        var speed: Float?

        if result == .hit,
           let hitTime,
           let start = fistPositionAtSpawn,
           let end = fistAtHit {
            let travelDistance = distance(start, end)
            let reaction = hitTime.timeIntervalSince(spawnTime)
            travel = travelDistance
            if reaction > 0 {
                speed = travelDistance / Float(reaction)
            }
        }

        let attempt = TargetAttempt(
            id: activeAttemptID ?? UUID(),
            spawnTime: spawnTime,
            hitTime: hitTime,
            result: result,
            distanceAtHit: landingError ?? fistAtHit.map { distance($0, targetPosition) },
            fistTravelDistance: travel,
            estimatedSpeedMetersPerSecond: speed
        )

        metrics.record(attempt)
        targets.flash(result: result)

        if let feedback {
            lastFeedback = feedback
        } else if result == .hit, let reaction = attempt.reactionTime {
            lastFeedback = String(format: "Hit · %.0f ms", reaction * 1000)
        } else {
            lastFeedback = "Miss"
        }

        clearAttemptState()
        try? await Task.sleep(for: .milliseconds(220))
        targets.removeActiveTarget()
    }

    /// Discards a technically invalid evidence chain without creating an ordinary miss, metric,
    /// ranked step, or satisfying target flash. The caller decides whether to retry or abort.
    private func discardAttempt(
        feedback: String,
        preserveTarget: Bool = false
    ) async {
        lastFeedback = feedback
        clearAttemptState()
        try? await Task.sleep(for: .milliseconds(220))
        if !preserveTarget {
            targets.removeActiveTarget()
        }
    }

    private func wallClockDate(
        forAcquisitionTimestamp timestamp: TimeInterval,
        fallback: Date
    ) -> Date {
        guard timestamp.isFinite else { return fallback }
        let delta = timestamp - CACurrentMediaTime()
        guard delta.isFinite, abs(delta) <= 1 else { return fallback }
        return Date().addingTimeInterval(delta)
    }

    private func currentBodyFrame() -> BodyFrame? {
        guard let transform = hands.deviceTransform else { return nil }
        return poseSolver.bodyFrame(headTransform: transform)
    }

    private func punchEvidenceFrame(
        now: TimeInterval,
        requiredSide: BodySide?
    ) -> PunchEvidenceValidator.Frame? {
        let observations = [BodySide.left, .right].compactMap {
            hands.freshObservation(for: $0)
        }
        let deviceObservation: HandObservation?
        if let requiredSide {
            deviceObservation = observations.first { $0.side == requiredSide }
        } else {
            deviceObservation = observations.max {
                $0.acquisitionTimestamp < $1.acquisitionTimestamp
            }
        }
        guard let deviceObservation else { return nil }

        return PunchEvidenceValidator.Frame(
            now: now,
            deviceTimestamp: deviceObservation.deviceTimestamp,
            generation: hands.providerGeneration,
            continuityEpoch: hands.continuityEpoch,
            hands: observations.map {
                PunchEvidenceValidator.HandSample(
                    side: $0.side,
                    fistPosition: $0.fistPosition,
                    fistState: $0.fistState,
                    acquisitionTimestamp: $0.acquisitionTimestamp,
                    quality: .measured
                )
            }
        )
    }

    private func waitForBodyFrame(timeout: TimeInterval = 1.5) async -> BodyFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled, Date() < deadline {
            if let frame = currentBodyFrame() { return frame }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    /// Starts ranked pause accounting before the potentially 1.5-second wait. A recovered frame
    /// closes a short setup outage here; a timeout deliberately leaves the same pause active so
    /// `recoverCompetitionTracking` includes its stable-sample gate without resetting the origin.
    private func waitForRequiredBodyFrame(timeout: TimeInterval = 1.5) async -> BodyFrame? {
        let immediateFrame = currentBodyFrame()
        let accountsForRankedWait = competitionElapsedClock.beginBodyFrameWaitIfNeeded(
            frameAvailable: immediateFrame != nil,
            rankedRoundActive: capturesCompetitionEvidence && competitionStartedAt != nil,
            at: ProcessInfo.processInfo.systemUptime
        )
        if let immediateFrame { return immediateFrame }

        let frame = await waitForBodyFrame(timeout: timeout)
        if accountsForRankedWait,
           frame != nil || Task.isCancelled || phase != .running {
            competitionElapsedClock.endPause(at: ProcessInfo.processInfo.systemUptime)
        }
        return frame
    }

    private func calibrationKey(for mode: ReactiveStrikeMode) -> ReactiveStrikeMode {
        mode == .combination ? .air : mode
    }

    private func clearAttemptState() {
        activeAttemptID = nil
        spawnTime = nil
        fistPositionAtSpawn = nil
        fistPositionsAtSpawn.removeAll(keepingCapacity: true)
    }

    private func failDrill(_ message: String) {
        targets.removeActiveTarget()
        clearAttemptState()
        if capturesCompetitionEvidence, competitionTrackingStatus == .complete {
            competitionTrackingStatus = .technicalFailure
        }
        errorMessage = message
        lastFeedback = message
        phase = .idle
    }

    private func summaryFeedback() -> String {
        let accuracyPercent = Int((metrics.accuracy * 100).rounded())
        if mode == .combination {
            return "Done · \(comboRepsCompleted)/\(comboRepeatCount) combinations · \(accuracyPercent)% accuracy"
        }
        if let average = metrics.averageReactionTime {
            return String(
                format: "Done · %d%% accuracy · avg %.0f ms",
                accuracyPercent,
                average * 1000
            )
        }
        return "Done · \(accuracyPercent)% accuracy"
    }

    private func guardStatus(for side: BodySide) -> Bool? {
        guard let frame = currentBodyFrame(), let captured = guardPositionsBody[side] else {
            return nil
        }
        return GuardCoach.isGuardUp(
            guardFistBody: hands.freshObservation(for: side).map { frame.toBody($0.fistPosition) },
            capturedGuardBody: captured
        )
    }

    private func nonPunchingGuardStatus(punchingSide: BodySide) -> Bool? {
        let guardSide = punchingSide.opposite
        guard let frame = currentBodyFrame(),
              let capturedGuard = guardPositionsBody[guardSide]
        else { return nil }
        return GuardCoach.isGuardUp(
            guardFistBody: hands.freshObservation(for: guardSide).map {
                frame.toBody($0.fistPosition)
            },
            capturedGuardBody: capturedGuard
        )
    }
}
