import Foundation
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
    private var competitionPausedDuration: TimeInterval = 0
    private var trackingResumeRequested = false
    let audioCoordinator: TrainingAudioCoordinator
    let voiceCoach: CoachVoiceCoach

    init(
        feedbackGenerator: some FeedbackGenerating = MockFeedbackGenerator(),
        audioCoordinator: TrainingAudioCoordinator? = nil
    ) {
        let audioCoordinator = audioCoordinator ?? TrainingAudioCoordinator()
        self.audioCoordinator = audioCoordinator
        voiceCoach = CoachVoiceCoach(audioCoordinator: audioCoordinator)
        auraPunch = AuraPunchSession(
            hands: hands,
            feedbackGenerator: feedbackGenerator,
            audioCoordinator: audioCoordinator
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
        audioCoordinator.handleImmediately(.sceneDidAttach)
    }

    func immersiveSpaceDidClose() {
        isImmersiveSpaceOpen = false
        voiceCoach.shutdown()
        audioCoordinator.handleImmediately(.sceneDidDetach)
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

        let audioStage: TrainingAudioStage
        if calibrationOnly {
            audioStage = .fit
        } else if capturesCompetitionEvidence {
            audioStage = .compete
        } else {
            audioStage = mode == .combination ? .transfer : .baseline
        }
        audioCoordinator.handleImmediately(.experienceDidEnter(audioStage))

        metrics.reset()
        currentTargetIndex = 0
        currentComboStepIndex = 0
        comboRepsCompleted = 0
        competitionSteps.removeAll(keepingCapacity: true)
        competitionTrackingStatus = .complete
        competitionActiveElapsedTime = nil
        competitionStartedAt = nil
        competitionPausedDuration = 0
        competitionRequiresRecalibration = false
        wasStoppedBeforeCompletion = false
        guardPositionsBody.removeAll()
        phase = .calibrating
        lastFeedback = "Raise both hands into guard"
        errorMessage = nil
        playCoachCue(.guardUp, caption: "Raise both hands into guard.")
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
        audioCoordinator.handleImmediately(.trainingDidStop)

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
        competitionPausedDuration = 0
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
            playCoachCue(.reachCalibrated, kind: .result, caption: "Reach calibrated.")
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
            playCoachCue(.countdown, caption: "Get ready.")
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
            competitionActiveElapsedTime = max(
                0,
                ProcessInfo.processInfo.systemUptime - startedAt - competitionPausedDuration
            )
        }
        phase = .finished
        lastFeedback = summaryFeedback()
        audioCoordinator.handleImmediately(.experienceDidEnter(.celebrate))
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

        while !Task.isCancelled, deadline.map({ Date() < $0 }) ?? true, phase == .calibrating {
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
        playCoachCue(
            .calibrateReach,
            caption: "Punch out and hold each arm at a comfortable reach."
        )

        // Keep the cue at a neutral reference distance. Placing it at an authored profile edge can
        // encourage a shorter user to lean, moving the body frame while reach is being measured.
        let cueBodyPosition = SIMD3<Float>(0, 0.02, BodyMeasurements.averageAdult.armReach)
        targets.spawnTarget(
            at: frame.toWorld(cueBodyPosition),
            radius: config.targetRadius * 1.25
        )
        audioCoordinator.handleImmediately(.targetDidAppear(
            position: frame.toWorld(cueBodyPosition)
        ))

        defer { targets.removeActiveTarget() }

        // Allow enough time to observe a settled hold from each arm, not merely the outbound ramp.
        let deadline: Date? = capturesCompetitionEvidence ? nil : Date().addingTimeInterval(14)
        var acceptedSamples: [BodySide: [ReachSample]] = [.left: [], .right: []]
        var lastAcceptedTimestamp: [BodySide: TimeInterval] = [:]
        var lastProcessedTimestamp: [BodySide: TimeInterval] = [:]
        var measuredReaches: [BodySide: Float] = [:]

        while !Task.isCancelled, deadline.map({ Date() < $0 }) ?? true, phase == .calibrating {
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
                        playCoachCue(.extendOtherArm, caption: "Now extend your other arm.")
                    } else {
                        lastFeedback = "Reach calibrated"
                        playCoachCue(.reachCalibrated, kind: .result, caption: "Reach calibrated.")
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

    private enum TargetPresentationOutcome: Equatable {
        case completed
        case retry
        case aborted
    }

    private func runTargetLoop() async {
        for index in 0..<config.targetCount {
            guard !Task.isCancelled, phase == .running else { return }
            currentTargetIndex = index

            var outcome: TargetPresentationOutcome = .retry
            while outcome == .retry {
                outcome = await presentTarget()
                guard !Task.isCancelled, phase == .running else { return }
            }
            guard outcome == .completed else { return }

            if index < config.targetCount - 1 {
                try? await Task.sleep(for: .seconds(config.interTargetDelay))
            }
        }
    }

    private func presentTarget() async -> TargetPresentationOutcome {
        guard let frame = await waitForBodyFrame() else {
            guard !Task.isCancelled else { return .aborted }
            if capturesCompetitionEvidence {
                return await recoverCompetitionTracking() ? .retry : .aborted
            }
            failDrill("Head tracking was lost. Face forward and try the round again.")
            return .aborted
        }

        let bodyPosition = reachProfile.randomBodyTargetPosition()
        let worldPosition = frame.toWorld(bodyPosition)
        targets.spawnTarget(at: worldPosition, radius: config.targetRadius)
        audioCoordinator.handleImmediately(.targetDidAppear(position: worldPosition))

        beginAttempt(fistAtSpawn: fistPositionForCurrentRun(nearestTo: worldPosition))
        lastFeedback = "Punch!"
        if capturesCompetitionEvidence {
            playCoachCue(.hitTarget, caption: "Hit the target.")
        }

        var activeElapsed: TimeInterval = 0
        var lastTick = Date()
        var trackingLostAt: Date?
        var guardPausedAt: Date?

        while !Task.isCancelled, phase == .running, activeAttemptID != nil {
            let now = Date()
            let currentFist = fistPositionForCurrentRun(nearestTo: worldPosition)
            if capturesCompetitionEvidence {
                let hasFreshPair = hands.freshObservation(for: .left) != nil
                    && hands.freshObservation(for: .right) != nil
                    && hands.deviceTransform != nil
                if !hasFreshPair {
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
                    lastTick = now
                }
                trackingLostAt = nil
            }

            let shouldPauseForGuard: Bool
            if capturesCompetitionEvidence {
                let punchingSide = competitionPunchingSide(to: worldPosition)
                if let punchingSide {
                    shouldPauseForGuard = nonPunchingGuardStatus(punchingSide: punchingSide) != true
                } else {
                    // Before an outbound hand is identifiable, both fists must remain in their
                    // captured guard. This prevents a dropped hand from bypassing the guard check.
                    shouldPauseForGuard = guardStatus(for: .left) != true
                        || guardStatus(for: .right) != true
                }
            } else {
                shouldPauseForGuard = nearestPunchingSide(to: worldPosition).map {
                    nonPunchingGuardStatus(punchingSide: $0) == false
                } ?? false
            }
            if shouldPauseForGuard {
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
                await finishAttempt(
                    result: .miss,
                    hitTime: nil,
                    fistAtHit: currentFist,
                    targetPosition: worldPosition
                )
                return .completed
            }

            if let fist = currentFist,
               distance(fist, worldPosition) <= config.hitRadius {
                await finishAttempt(
                    result: .hit,
                    hitTime: Date(),
                    fistAtHit: fist,
                    targetPosition: worldPosition
                )
                return .completed
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

        let pausedAt = ProcessInfo.processInfo.systemUptime
        targets.removeActiveTarget()
        clearAttemptState()
        isTrackingPaused = true
        trackingReadyToResume = false
        lastFeedback = "Tracking paused · Hold both fists in guard and look forward"
        audioCoordinator.handleImmediately(.trackingDidPause(.staleSamples))

        var didRecover = false

        defer {
            competitionPausedDuration += max(
                0,
                ProcessInfo.processInfo.systemUptime - pausedAt
            )
            isTrackingPaused = false
            trackingReadyToResume = false
            if didRecover {
                audioCoordinator.handleImmediately(.trackingDidResume)
            }
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
                    didRecover = true
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

            for target in resolvedTargets {
                guard !Task.isCancelled, phase == .running else { return }
                currentComboStepIndex = target.index

                guard let guardPosition = guardPositionsBody[target.requiredHand] else {
                    failDrill("Guard calibration was unavailable for this combination.")
                    return
                }
                var availableFrame = await waitForBodyFrame()
                while availableFrame == nil && capturesCompetitionEvidence {
                    guard await recoverCompetitionTracking() else { return }
                    availableFrame = await waitForBodyFrame()
                }
                guard let frame = availableFrame else {
                    guard !Task.isCancelled else { return }
                    failDrill("Tracking was lost while preparing the combination.")
                    return
                }

                var worldPosition = frame.toWorld(target.position)
                var worldGuardPosition = frame.toWorld(guardPosition)
                targets.spawnTarget(at: worldPosition, radius: config.targetRadius)
                audioCoordinator.handleImmediately(.targetDidAppear(position: worldPosition))

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
                var validator = CombinationPunchValidator(
                    target: worldTarget,
                    guardPosition: worldGuardPosition,
                    hitRadius: config.hitRadius
                )
                var deadline = Date().addingTimeInterval(config.timeout)
                var stepHit = false
                var centerError: Float?
                var reactionTime: TimeInterval?
                var trackingLostAt: Date?

                while !Task.isCancelled,
                      phase == .running,
                      activeAttemptID != nil {
                    let required = hands.freshObservation(for: target.requiredHand)
                    let other = hands.freshObservation(for: target.requiredHand.opposite)

                    if capturesCompetitionEvidence,
                       required == nil || other == nil || hands.deviceTransform == nil {
                        trackingLostAt = trackingLostAt ?? Date()
                        if Date().timeIntervalSince(trackingLostAt!)
                            >= CompetitionTrackingRecoveryGate.lossGraceSeconds {
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
                            validator = CombinationPunchValidator(
                                target: worldTarget,
                                guardPosition: worldGuardPosition,
                                hitRadius: config.hitRadius
                            )
                            targets.spawnTarget(at: worldPosition, radius: config.targetRadius)
                            audioCoordinator.handleImmediately(.targetDidAppear(
                                position: worldPosition
                            ))
                            beginAttempt(
                                fistAtSpawn: hands.freshObservation(for: target.requiredHand)?.fistPosition
                            )
                            deadline = Date().addingTimeInterval(config.timeout)
                            trackingLostAt = nil
                            lastFeedback = "\(target.punch.displayName)!"
                        }
                        try? await Task.sleep(for: .milliseconds(16))
                        continue
                    }

                    trackingLostAt = nil
                    if Date() >= deadline {
                        await finishAttempt(
                            result: .miss,
                            hitTime: nil,
                            fistAtHit: hands.freshObservation(for: target.requiredHand)?.fistPosition,
                            targetPosition: worldPosition
                        )
                        break
                    }

                    let timestamp = required?.timestamp
                        ?? other?.timestamp
                        ?? ProcessInfo.processInfo.systemUptime

                    switch validator.observe(
                        requiredFist: required?.fistPosition,
                        otherFist: other?.fistPosition,
                        timestamp: timestamp
                    ) {
                    case .waiting:
                        break
                    case .armed:
                        lastFeedback = "\(target.punch.displayName) · strike now"
                    case .wrongHand:
                        await finishAttempt(
                            result: .miss,
                            hitTime: nil,
                            fistAtHit: other?.fistPosition,
                            targetPosition: worldPosition,
                            feedback: "Wrong hand · use your \(target.requiredHand.rawValue) hand"
                        )
                    case .hit:
                        await finishAttempt(
                            result: .hit,
                            hitTime: Date(),
                            fistAtHit: required?.fistPosition,
                            targetPosition: worldPosition
                        )
                        stepHit = true
                        centerError = required.map { distance($0.fistPosition, worldPosition) }
                        reactionTime = metrics.lastAttempt?.reactionTime
                    }

                    if stepHit { break }
                    try? await Task.sleep(for: .milliseconds(16))
                }

                guard !Task.isCancelled, phase == .running else { return }
                guard stepHit else {
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
                    if capturesCompetitionEvidence { continue }
                    break
                }

                lastFeedback = "Return your \(target.requiredHand.rawValue) hand to guard"
                let returnedToGuard = await waitForRetraction(
                    side: target.requiredHand,
                    guardPosition: guardPosition
                )
                guard !Task.isCancelled else { return }
                if capturesCompetitionEvidence {
                    competitionSteps.append(CompetitionStepEvidence(
                        index: rep * resolvedTargets.count + target.index,
                        valid: returnedToGuard,
                        centreErrorMeters: returnedToGuard ? centerError : nil,
                        reactionTime: returnedToGuard ? reactionTime : nil,
                        requiredHand: target.requiredHand,
                        returnedToGuard: returnedToGuard
                    ))
                }
                guard returnedToGuard else {
                    lastFeedback = "Combination reset · return to guard"
                    completedRep = false
                    if capturesCompetitionEvidence { continue }
                    break
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
                guardPosition: guardPosition,
                hitRadius: config.hitRadius
            )
            guard validator.isValidConfiguration else { return nil }
        }

        return resolved
    }

    private func waitForRetraction(
        side: BodySide,
        guardPosition: SIMD3<Float>
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(1.8)
        var consecutiveSamples = 0
        var lastTimestamp: TimeInterval?
        var trackingLostAt: Date?

        while !Task.isCancelled, Date() < deadline, phase == .running {
            if let frame = currentBodyFrame(),
               let observation = hands.freshObservation(for: side),
               lastTimestamp.map({ observation.timestamp > $0 }) ?? true {
                trackingLostAt = nil
                lastTimestamp = observation.timestamp
                let isRetracted = CombinationPunchValidator.isRetracted(
                    fist: frame.toBody(observation.fistPosition),
                    guardPosition: guardPosition,
                    radius: CombinationPunchValidator.guardRadius
                )
                consecutiveSamples = isRetracted ? consecutiveSamples + 1 : 0
                if consecutiveSamples >= 3 { return true }
            } else if capturesCompetitionEvidence {
                let now = Date()
                trackingLostAt = trackingLostAt ?? now
                if now.timeIntervalSince(trackingLostAt!)
                    >= CompetitionTrackingRecoveryGate.lossGraceSeconds {
                    return await recoverCompetitionTracking()
                }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        return false
    }

    private func beginAttempt(fistAtSpawn: SIMD3<Float>?) {
        activeAttemptID = UUID()
        spawnTime = Date()
        fistPositionAtSpawn = fistAtSpawn
        if capturesCompetitionEvidence {
            fistPositionsAtSpawn = Dictionary(uniqueKeysWithValues: [BodySide.left, .right]
                .compactMap { side in
                    hands.freshObservation(for: side).map { (side, $0.fistPosition) }
                })
        } else {
            fistPositionsAtSpawn.removeAll(keepingCapacity: true)
        }
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
            distanceAtHit: fistAtHit.map { distance($0, targetPosition) },
            fistTravelDistance: travel,
            estimatedSpeedMetersPerSecond: speed
        )

        metrics.record(attempt)
        targets.flash(result: result)
        if result == .hit {
            audioCoordinator.handleImmediately(.validatedImpact(
                position: targetPosition,
                quality: .clean
            ))
        }

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

    private func currentBodyFrame() -> BodyFrame? {
        guard let transform = hands.deviceTransform else { return nil }
        return poseSolver.bodyFrame(headTransform: transform)
    }

    private func fistPositionForCurrentRun(nearestTo point: SIMD3<Float>) -> SIMD3<Float>? {
        guard capturesCompetitionEvidence else { return hands.nearestFistPosition(to: point) }
        let left = hands.freshObservation(for: .left)?.fistPosition
        let right = hands.freshObservation(for: .right)?.fistPosition
        switch (left, right) {
        case let (left?, right?):
            return distance(left, point) <= distance(right, point) ? left : right
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        case (nil, nil):
            return nil
        }
    }

    private func waitForBodyFrame(timeout: TimeInterval = 1.5) async -> BodyFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled, Date() < deadline {
            if let frame = currentBodyFrame() { return frame }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
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

    private func playCoachCue(
        _ clip: CoachClipID,
        kind: TrainingCoachCueKind = .phaseInstruction,
        caption: String
    ) {
        audioCoordinator.handleImmediately(.coachCue(TrainingCoachCue(
            kind: kind,
            clip: clip,
            caption: caption
        )))
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

    private func competitionPunchingSide(to target: SIMD3<Float>) -> BodySide? {
        let current = Dictionary(uniqueKeysWithValues: [BodySide.left, .right]
            .compactMap { side in
                hands.freshObservation(for: side).map { (side, $0.fistPosition) }
            })
        return GuardCoach.punchingSide(
            current: current,
            starts: fistPositionsAtSpawn,
            target: target
        )
    }

    private func nearestPunchingSide(to point: SIMD3<Float>) -> BodySide? {
        let left = hands.leftFistPosition
        let right = hands.rightFistPosition
        switch (left, right) {
        case let (left?, right?):
            return distance(left, point) <= distance(right, point) ? .left : .right
        case (nil, .some): return .right
        case (.some, nil): return .left
        case (nil, nil): return nil
        }
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
