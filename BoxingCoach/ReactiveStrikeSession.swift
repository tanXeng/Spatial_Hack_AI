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
    /// Mirrors the one shared measurement rather than caching its own copy. Competition reads this
    /// to persist a player's reach; there is deliberately no second source of truth to drift.
    var latestCalibratedReaches: [BodySide: Float] { calibration.reaches }
    private(set) var competitionSteps: [CompetitionStepEvidence] = []
    private(set) var competitionTrackingStatus: CompetitionTrackingStatus = .complete
    private(set) var competitionActiveElapsedTime: TimeInterval?
    private(set) var competitionRequiresRecalibration = false
    private(set) var wasStoppedBeforeCompletion = false

    /// Which arm calibration is on and whether it is waiting at guard or measuring — `nil` outside
    /// a calibration run.
    ///
    /// `OrderedReachCalibration` already sequences this; publishing it lets the screen show real
    /// per-arm progress instead of inferring it from a freeform feedback string, which is all the
    /// UI previously had to work with.
    private(set) var calibrationStage: OrderedReachCalibration.Stage?

    /// The active arm's live forward reach in meters, as a fraction of what an average adult can
    /// reach. Drives the extension meter so the user can see the hold building rather than
    /// guessing why nothing has happened yet. Zero when no arm is extending.
    private(set) var calibrationLiveExtension: Float = 0

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

    /// Measured once per launch by Anthropometry and shared with Aura Punch. Every mode reads the
    /// same numbers, so switching Air → Bag → Combination never re-measures the same arms.
    let calibration: BodyCalibration

    private let poseSolver = ArmPoseSolver()
    private var measurements: BodyMeasurements { calibration.measurements }
    private var guardPositionsBody: [BodySide: SIMD3<Float>] = [:]
    private var drillTask: Task<Void, Never>?
    private var activeAttemptID: UUID?
    private var spawnTime: Date?
    private var fistPositionAtSpawn: SIMD3<Float>?
    private var fistPositionsAtSpawn: [BodySide: SIMD3<Float>] = [:]
    private var capturesCompetitionEvidence = false
    private var competitionStartedAt: TimeInterval?
    private var competitionPausedDuration: TimeInterval = 0
    private var trackingResumeRequested = false
    private let coachAudio: CoachAudioPlayer
    let voiceCoach: CoachVoiceCoach

    // Defaulted to `nil` rather than to `BodyCalibration()`: a default argument expression is
    // evaluated outside this initializer's actor isolation, and `BodyCalibration` is MainActor.
    init(calibration: BodyCalibration? = nil) {
        self.calibration = calibration ?? BodyCalibration()
        let coachAudio = CoachAudioPlayer()
        self.coachAudio = coachAudio
        voiceCoach = CoachVoiceCoach(audioPlayer: coachAudio)
        auraPunch = AuraPunchSession(hands: hands, coachAudio: coachAudio)
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

    var hasCalibratedReach: Bool { calibration.isCalibrated }

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
        self.mode = mode
        self.stance = stance
        if let combination {
            selectedCombination = combination
        }

        if let measuredReach = calibration.measuredReach {
            reachProfile = mode.reachProfile.calibrated(measuredForwardReach: measuredReach)
        } else {
            reachProfile = mode.reachProfile
        }
    }

    func configureCompetition(
        mode: CompetitionMode,
        stance: Stance,
        reach: BilateralReach
    ) {
        let retainedGuards = calibration.guardPositionsBody
        calibration.store(reaches: reach.bySide, guardPositionsBody: retainedGuards)
        let reactiveMode: ReactiveStrikeMode = mode == .combination ? .combination : .air
        configure(
            mode: reactiveMode,
            combination: mode == .combination ? .jabCrossHookCross : nil,
            stance: stance
        )
        capturesCompetitionEvidence = true
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
    func applyPersistedCompetitionReach(
        _ reach: BilateralReach?,
        clearingGuards: Bool = false
    ) {
        guard phase != .running, phase != .calibrating else { return }
        let retainedGuards: [BodySide: SIMD3<Float>] = clearingGuards
            ? [:]
            : calibration.guardPositionsBody
        if clearingGuards {
            guardPositionsBody.removeAll()
        }
        if let reach {
            calibration.store(
                reaches: reach.bySide,
                guardPositionsBody: retainedGuards
            )
        } else {
            calibration.invalidate()
        }
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
        competitionPausedDuration = 0
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

    /// Runs Anthropometry: capture guard, measure both arms, store the result for the whole launch.
    ///
    /// Shares the drill's phase machine deliberately, so the immersive banner, the window status
    /// line, and the coordinator's readiness handling all work unchanged.
    func startCalibration() {
        startCalibration(capturingCompetitionEvidence: false)
    }

    func startCompetitionCalibration() {
        startCalibration(capturingCompetitionEvidence: true)
    }

    private func startCalibration(capturingCompetitionEvidence: Bool) {
        guard phase != .running, phase != .calibrating else { return }

        configure(mode: .air, combination: nil, stance: stance)
        self.capturesCompetitionEvidence = capturingCompetitionEvidence
        config.targetCount = CompetitionMode.reactiveStrike.totalSteps
        config.hitRadius = CompetitionScorer.targetRadius
        competitionSteps.removeAll(keepingCapacity: true)
        competitionTrackingStatus = .complete
        competitionActiveElapsedTime = nil
        competitionStartedAt = nil
        competitionPausedDuration = 0
        competitionRequiresRecalibration = false
        wasStoppedBeforeCompletion = false
        guardPositionsBody.removeAll()
        metrics.reset()
        calibrationStage = .awaitingGuard(.left)
        calibrationLiveExtension = 0
        phase = .calibrating
        lastFeedback = "Raise both hands into guard"
        errorMessage = nil
        isTrackingPaused = false
        trackingReadyToResume = false
        trackingResumeRequested = false
        coachAudio.play(id: .guardUp)

        drillTask?.cancel()
        drillTask = Task { [weak self] in
            await self?.runCalibrationLoop()
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
        calibrationStage = nil
        calibrationLiveExtension = 0
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
        }
    }

    func resetForParticipantHandoff() {
        resetForNewRound()
        hands.stop()
        targets.removeActiveTarget()
        calibration.invalidate()
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

        // Anthropometry already measured this body. Reuse its guard rather than making the user
        // stand still for another acquisition every single time they start a drill.
        let storedGuards = calibration.guardPositionsBody
        let guards: [BodySide: SIMD3<Float>]
        if storedGuards[.left] != nil, storedGuards[.right] != nil {
            guards = storedGuards
        } else if let acquired = await acquireGuardPositions() {
            guards = acquired
        } else {
            guard !Task.isCancelled else { return }
            failDrill("Keep both hands visible in guard so calibration can begin.")
            return
        }
        guardPositionsBody = guards

        guard let measuredReach = calibration.measuredReach else {
            failDrill("Calibrate your reach from the feature menu before starting a drill.")
            return
        }

        let maximumGuardForward = guards.values.map(\.z).max() ?? 0
        guard let guardedProfile = mode.reachProfile
            .calibrated(measuredForwardReach: measuredReach)
            .placingTargetsBeyondGuard(
                maximumGuardForward: maximumGuardForward,
                hitRadius: config.hitRadius
            ) else {
            // A ranked run must not silently fall back to an unsafe volume: flag it so Competition
            // routes the player back through calibration instead of scoring a bad round.
            if capturesCompetitionEvidence {
                competitionRequiresRecalibration = true
                failDrill("Your saved reach no longer clears your current guard. Recalibrate before competing.")
                return
            }
            failDrill("Your guard and full extension were too close together. Recalibrate from the feature menu.")
            return
        }
        reachProfile = guardedProfile

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
            competitionActiveElapsedTime = max(
                0,
                ProcessInfo.processInfo.systemUptime - startedAt - competitionPausedDuration
            )
        }
        phase = .finished
        lastFeedback = summaryFeedback()
    }

    private func runCalibrationLoop() async {
        // The user stands still for several seconds measuring their reach, which is free time to
        // pull the 17 MB coach model into memory. Detached so a slow load never stalls calibration.
        Task { [auraPunch] in await auraPunch.preloadCoach() }

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

        guard let measuredReaches = await calibrateReach(using: guards),
              ReachCalibration.conservativeBilateralReach(measuredReaches) != nil else {
            guard !Task.isCancelled else { return }
            failDrill("Reach calibration timed out. Return to guard, punch out, and hold full extension.")
            return
        }

        guard !Task.isCancelled, phase == .calibrating else { return }
        calibration.store(reaches: measuredReaches, guardPositionsBody: guards)
        guardPositionsBody = guards
        calibrationStage = .complete
        calibrationLiveExtension = 0
        phase = .finished

        if let reach = calibration.measuredReach {
            lastFeedback = String(format: "Calibrated · %.0f cm reach", reach * 100)
        } else {
            lastFeedback = "Calibration complete"
        }
    }

    /// Captures the guard pose. Anthropometry stores its result, so drills reuse it rather than
    /// re-acquiring. Combination validation uses these positions to require each punch to leave
    /// guard and return before the next step.
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

        // Cue at an average adult's reach, never at the profile's `forwardMax`. Air's 0.75 m far
        // edge is past most people's actual reach, so cueing there made users lean or lunge, which
        // moves the body frame origin and corrupts the very measurement being taken.
        let cueBodyPosition = SIMD3<Float>(0, 0.02, BodyMeasurements.averageAdult.armReach)
        targets.spawnTarget(
            at: frame.toWorld(cueBodyPosition),
            radius: config.targetRadius * 1.25
        )

        defer { targets.removeActiveTarget() }

        var sequence = OrderedReachCalibration()
        calibrationStage = sequence.stage
        while let side = sequence.activeSide, phase == .calibrating, !Task.isCancelled {
            guard let guardPosition = guards[side] else { return nil }
            if side == .right {
                lastFeedback = "Return your right hand to guard"
            }
            guard await waitForCalibrationGuard(for: side, guardPosition: guardPosition),
                  sequence.confirmGuard(for: side)
            else { return nil }
            calibrationStage = sequence.stage

            if side == .left {
                lastFeedback = "Keep a relaxed closed fist, punch out, and hold — left arm first"
                coachAudio.play(id: .calibrateReach)
            } else {
                lastFeedback = "Keep your fist closed, then punch out and hold with your right arm"
                coachAudio.play(id: .extendOtherArm)
            }

            guard let reach = await measureSettledReach(for: side, guardPosition: guardPosition),
                  sequence.acceptSettledReach(reach, for: side)
            else { return nil }
            calibrationStage = sequence.stage
            calibrationLiveExtension = 0
        }

        guard let reaches = sequence.completedReaches else { return nil }
        lastFeedback = "Reach calibrated"
        coachAudio.play(id: .reachCalibrated)
        targets.flash(result: .hit)
        try? await Task.sleep(for: .milliseconds(180))
        return reaches
    }

    private func waitForCalibrationGuard(
        for side: BodySide,
        guardPosition: SIMD3<Float>
    ) async -> Bool {
        let deadline: Date? = capturesCompetitionEvidence ? nil : Date().addingTimeInterval(5)
        var consecutiveFreshSamples = 0
        var lastTimestamp: TimeInterval?

        while !Task.isCancelled, deadline.map({ Date() < $0 }) ?? true, phase == .calibrating {
            if let frame = currentBodyFrame(),
               let observation = hands.observation(for: side),
               observation.timestamp > (lastTimestamp ?? -.infinity) {
                lastTimestamp = observation.timestamp
                let isAtGuard = CombinationPunchValidator.isRetracted(
                    fist: frame.toBody(observation.fistPosition),
                    guardPosition: guardPosition,
                    radius: CombinationPunchValidator.guardRadius
                )
                consecutiveFreshSamples = isAtGuard ? consecutiveFreshSamples + 1 : 0
                if consecutiveFreshSamples >= 3 { return true }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func measureSettledReach(
        for side: BodySide,
        guardPosition: SIMD3<Float>
    ) async -> Float? {
        let deadline: Date? = capturesCompetitionEvidence ? nil : Date().addingTimeInterval(14)
        var acceptedSamples: [ReachSample] = []
        var lastAcceptedTimestamp: TimeInterval?
        var lastProcessedTimestamp: TimeInterval?

        while !Task.isCancelled, deadline.map({ Date() < $0 }) ?? true, phase == .calibrating {
            if let frame = currentBodyFrame(),
               let observation = hands.observation(for: side),
               observation.timestamp > (lastProcessedTimestamp ?? -.infinity) {
                lastProcessedTimestamp = observation.timestamp
                let fistBody = frame.toBody(observation.fistPosition)
                // Published every processed frame, not only for accepted samples, so the meter
                // still moves while the fist is on its way out and has not yet cleared guard.
                publishLiveExtension(fistBody.z)
                if let candidate = ReachCalibration.candidateForwardReach(
                    guardPosition: guardPosition,
                    fistPosition: fistBody
                ) {
                    if let previous = lastAcceptedTimestamp,
                       observation.timestamp - previous > 0.5 {
                        acceptedSamples.removeAll(keepingCapacity: true)
                    }
                    acceptedSamples.append(
                        ReachSample(forward: candidate, time: observation.timestamp)
                    )
                    lastAcceptedTimestamp = observation.timestamp
                    if let settled = ReachCalibration.settledForwardReach(from: acceptedSamples) {
                        return settled
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(16))
        }

        guard !Task.isCancelled else { return nil }
        return ReachCalibration.robustForwardReach(from: acceptedSamples.map(\.forward))
    }

    /// Normalizes a body-space forward reach against average adult reach for the extension meter.
    ///
    /// Deliberately *not* normalized against the user's own measured reach: during calibration that
    /// number does not exist yet, and once it did the meter would read full at whatever the user
    /// happened to do, which tells them nothing about whether they are extending.
    private func publishLiveExtension(_ forward: Float) {
        guard forward.isFinite else { return }
        let reference = max(BodyMeasurements.averageAdult.armReach, 0.01)
        calibrationLiveExtension = min(max(forward / reference, 0), 1)
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

        beginAttempt(fistAtSpawn: fistPositionForCurrentRun(nearestTo: worldPosition))
        lastFeedback = "Punch!"
        if capturesCompetitionEvidence {
            coachAudio.play(id: .hitTarget)
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

        defer {
            competitionPausedDuration += max(
                0,
                ProcessInfo.processInfo.systemUptime - pausedAt
            )
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

    private func clearAttemptState() {
        activeAttemptID = nil
        spawnTime = nil
        fistPositionAtSpawn = nil
        fistPositionsAtSpawn.removeAll(keepingCapacity: true)
    }

    private func failDrill(_ message: String) {
        targets.removeActiveTarget()
        clearAttemptState()
        calibrationStage = nil
        calibrationLiveExtension = 0
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
