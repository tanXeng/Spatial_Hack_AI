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
    private(set) var challengeRepetitions: [ChallengeRepSnapshot] = []
    private(set) var lessonStages: [LessonStageSnapshot] = []
    private(set) var lastFeedback: String = "Ready"
    private(set) var errorMessage: String?
    private(set) var isTrackingPaused = false
    private(set) var trackingReadyToResume = false
    private(set) var instructionPanelWorldPosition: SIMD3<Float>?
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
    let guided = GuidedBoxingSession()

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
    private var capturesEventChallengeEvidence = false
    private var capturesCompetitionEvidence = false
    private var competitionCalibrationOnly = false
    private var competitionStartedAt: TimeInterval?
    private var competitionPausedDuration: TimeInterval = 0
    private var trackingResumeRequested = false

    init() {
        auraPunch = AuraPunchSession(hands: hands)
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

    func immersiveSpaceDidOpen() {
        isImmersiveSpaceOpen = true
    }

    func immersiveSpaceDidClose() {
        isImmersiveSpaceOpen = false
    }

    func configure(
        mode: ReactiveStrikeMode,
        combination: Combination?,
        stance: Stance
    ) {
        config = DrillConfig()
        capturesEventChallengeEvidence = false
        capturesCompetitionEvidence = false
        competitionCalibrationOnly = false
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
        configure(mode: .air, combination: nil, stance: stance)
        capturesCompetitionEvidence = true
        competitionCalibrationOnly = true
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
        competitionCalibrationOnly = false
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

    func configureEventChallenge(stance: Stance) {
        configure(mode: .combination, combination: .oneTwo, stance: stance)
        capturesEventChallengeEvidence = true
        comboRepeatCount = ChallengeRulesV1.repetitionCount
        config.hitRadius = ChallengeRulesV1.targetRadiusMeters
        config.targetRadius = ChallengeRulesV1.targetRadiusMeters
        config.timeout = 2
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
        challengeRepetitions.removeAll(keepingCapacity: true)
        lessonStages.removeAll(keepingCapacity: true)
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
        isTrackingPaused = false
        trackingReadyToResume = false
        trackingResumeRequested = false
        instructionPanelWorldPosition = nil

        drillTask?.cancel()
        drillTask = Task { [weak self] in
            await self?.runDrillLoop()
        }
    }

    func requestTrackingResume() {
        guard isTrackingPaused, trackingReadyToResume else { return }
        trackingResumeRequested = true
    }

    func stopDrill() {
        // Also covers a system-driven immersive dismissal. Aura Punch must stop here too or its
        // pose loop would keep running against tracking providers that no longer have a scene.
        auraPunch.stop()

        drillTask?.cancel()
        drillTask = nil
        targets.removeActiveTarget()
        targets.removeCoachPath()
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

    func resetForNewRound(
        keepingEventConfiguration: Bool = false,
        keepingCompetitionConfiguration: Bool = false
    ) {
        stopDrill()
        metrics.reset()
        phase = .idle
        currentTargetIndex = 0
        currentComboStepIndex = 0
        comboRepsCompleted = 0
        challengeRepetitions.removeAll(keepingCapacity: true)
        lessonStages.removeAll(keepingCapacity: true)
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
        instructionPanelWorldPosition = nil
        if !keepingEventConfiguration {
            capturesEventChallengeEvidence = false
        }
        if !keepingCompetitionConfiguration {
            capturesCompetitionEvidence = false
            competitionCalibrationOnly = false
        }
    }

    func resetForParticipantHandoff() {
        resetForNewRound()
        hands.stop()
        targets.removeActiveTarget()
        targets.removeCoachPath()
        calibratedReaches.removeAll()
        guardPositionsBody.removeAll()
        reachProfile = .air
        stance = .orthodox
        selectedCombination = .oneTwo
        comboRepeatCount = ChallengeRulesV1.repetitionCount
        guided.reset()
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

        if guided.plan == .observeOnly {
            phase = .running
            await runObserveOnlyLesson()
            guard !Task.isCancelled else { return }
            phase = .finished
            lastFeedback = "Lesson observed"
            return
        }


        if capturesEventChallengeEvidence {
            advanceGuidedCalibrationStage()
            lastFeedback = "Hold both open hands beside your face"
            guard let openRatios = await captureHandShape(expected: .open) else {
                guard !Task.isCancelled else { return }
                failDrill("We could not calibrate your open hands. Keep both hands visible and repeat setup.")
                return
            }
            advanceGuidedCalibrationStage()
            lastFeedback = "Close both hands gently. Do not squeeze"
            guard let closedRatios = await captureHandShape(expected: .closed) else {
                guard !Task.isCancelled else { return }
                failDrill("We could not calibrate your relaxed fists. Open both hands, then repeat setup.")
                return
            }
            advanceGuidedCalibrationStage()
            for side in [BodySide.left, .right] {
                if let closed = closedRatios[side], let open = openRatios[side] {
                    hands.setFistCalibration(side: side, closed: closed, open: open)
                }
            }
        }

        guard let guards = await acquireGuardPositions() else {
            guard !Task.isCancelled else { return }
            failDrill("Keep both hands visible in guard so calibration can begin.")
            return
        }
        guardPositionsBody = guards
        if let frame = currentBodyFrame() {
            instructionPanelWorldPosition = frame.toWorld(SIMD3<Float>(0, 0.30, 1.10))
        }
        if capturesEventChallengeEvidence { advanceGuidedCalibrationStage() }

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
            } else if capturesCompetitionEvidence, !competitionCalibrationOnly {
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

        if competitionCalibrationOnly {
            competitionTrackingStatus = .complete
            phase = .finished
            lastFeedback = "Reach calibrated"
            return
        }

        if capturesEventChallengeEvidence {
            advanceGuidedCalibrationStage()
            advanceGuidedCalibrationStage()
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
        }

        if guided.plan == .guidedCore {
            await runGuidedLessonLoop()
        } else if mode == .combination {
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

    private func runObserveOnlyLesson() async {
        let demonstrations: [(GuidedStage, PunchType, String, String)] = [
            (.jabWatch, .jab, "Watch the lead hand travel straight out and back.", "jab-watch"),
            (.crossWatch, .cross, "Watch the rear hand travel straight out and back.", "cross-watch"),
            (.oneTwoPractice(rep: 0), .jab, "Jab, return to guard; cross, return to guard.", "one-two-watch")
        ]
        for (stage, punch, instruction, id) in demonstrations {
            guard !Task.isCancelled else { return }
            guided.transition(to: stage, instruction: instruction)
            lastFeedback = instruction
            if let frame = currentBodyFrame() {
                let side = punch.requiredHand(for: stance)
                let guardPosition = SIMD3<Float>(side.lateralSign * 0.18, 0.16, 0.18)
                let target = punch.targetPosition(forwardBase: 0.58, stance: stance)
                targets.showCoachPath(from: frame.toWorld(guardPosition), to: frame.toWorld(target))
            }
            try? await Task.sleep(for: .seconds(2))
            targets.removeCoachPath()
            lessonStages.append(LessonStageSnapshot(
                stageID: id,
                completedAt: .now,
                metrics: [LessonMetricSnapshot(
                    id: "observation", availability: .unavailable, value: nil, confidence: 1,
                    evidence: "Demonstration observed; no punch was requested or scored"
                )]
            ))
        }
    }

    private func runGuidedLessonLoop() async {
        let originalCombination = selectedCombination
        let originalRepeatCount = comboRepeatCount
        defer { selectedCombination = originalCombination; comboRepeatCount = originalRepeatCount }

        await demonstrate(.jabWatch, punch: .jab, "Watch the lead hand travel straight out and back.", id: "jab-watch")
        await guidedPunch(.jab, .jabFollow(rep: 1), reps: 2, "Follow two controlled jabs. Return each one to guard.", id: "jab-follow")
        await guidedPunch(.jab, .jabBaseline, reps: 1, "One controlled jab. Return it to guard.", id: "jab-baseline")
        presentCorrection(.jabCorrection, punchName: "jab")
        await guidedPunch(.jab, .jabRetest, reps: 1, "Retest your jab with that one adjustment.", id: "jab-retest")

        await demonstrate(.crossWatch, punch: .cross, "Watch the rear hand travel straight out and back.", id: "cross-watch")
        await guidedPunch(.cross, .crossFollow(rep: 1), reps: 2, "Follow two controlled crosses. Keep the lead hand near guard.", id: "cross-follow")
        await guidedPunch(.cross, .crossBaseline, reps: 1, "One controlled cross. Keep the lead hand near guard.", id: "cross-baseline")
        presentCorrection(.crossCorrection, punchName: "cross")
        await guidedPunch(.cross, .crossRetest, reps: 1, "Retest your cross with that one adjustment.", id: "cross-retest")

        guided.transition(to: .oneTwoPractice(rep: 1), instruction: "Jab, return to guard; cross, return to guard.")
        selectedCombination = .oneTwo
        comboRepeatCount = 3
        let start = metrics.attempts.count
        await runCombinationLoop()
        appendLessonMetrics(id: "one-two-practice", attemptsSince: start)
    }

    private func demonstrate(_ stage: GuidedStage, punch: PunchType, _ instruction: String, id: String) async {
        guard !Task.isCancelled else { return }
        guided.transition(to: stage, instruction: instruction)
        lastFeedback = instruction
        if let frame = currentBodyFrame(),
           let guardPosition = guardPositionsBody[punch.requiredHand(for: stance)] {
            let target = punch.targetPosition(forwardBase: reachProfile.forwardMax, stance: stance)
            targets.showCoachPath(from: frame.toWorld(guardPosition), to: frame.toWorld(target))
        }
        try? await Task.sleep(for: .seconds(2))
        targets.removeCoachPath()
        lessonStages.append(LessonStageSnapshot(
            stageID: id,
            completedAt: .now,
            metrics: [LessonMetricSnapshot(
                id: "coach-path", availability: .unavailable, value: nil, confidence: 1,
                evidence: "Deterministic coach-path demonstration completed"
            )]
        ))
    }

    private func guidedPunch(
        _ punch: PunchType,
        _ stage: GuidedStage,
        reps: Int,
        _ instruction: String,
        id: String
    ) async {
        guard !Task.isCancelled else { return }
        guided.transition(to: stage, instruction: instruction)
        lastFeedback = instruction
        selectedCombination = Combination(
            id: "guided-\(punch.rawValue)", name: punch.displayName, punches: [punch],
            summary: "Guided \(punch.displayName.lowercased())"
        )
        comboRepeatCount = reps
        let start = metrics.attempts.count
        await runCombinationLoop()
        appendLessonMetrics(id: id, attemptsSince: start)
    }

    private func presentCorrection(_ stage: GuidedStage, punchName: String) {
        let instruction = metrics.lastAttempt?.result == .hit
            ? "Bring your \(punchName) directly back to guard."
            : "Start from guard and send the correct hand through the centre."
        guided.transition(to: stage, instruction: instruction)
        lastFeedback = instruction
        lessonStages.append(LessonStageSnapshot(
            stageID: "\(punchName)-correction",
            completedAt: .now,
            metrics: [LessonMetricSnapshot(
                id: "selected-correction", availability: .measured, value: nil, confidence: 1,
                evidence: instruction
            )]
        ))
    }

    private func appendLessonMetrics(id: String, attemptsSince startIndex: Int) {
        let attempts = Array(metrics.attempts.dropFirst(startIndex))
        let contacts = attempts.filter { $0.result == .hit }.count
        lessonStages.append(LessonStageSnapshot(
            stageID: id,
            completedAt: .now,
            metrics: [
                LessonMetricSnapshot(
                    id: "valid-contact-rate",
                    availability: attempts.isEmpty ? .unavailable : .measured,
                    value: attempts.isEmpty ? nil : Float(contacts) / Float(attempts.count),
                    confidence: attempts.isEmpty ? 0 : 1,
                    evidence: attempts.isEmpty ? "No confidently tracked attempt was available" : "Correct-hand closed-fist target outcomes"
                ),
                LessonMetricSnapshot(
                    id: "complete-form", availability: .unavailable, value: nil, confidence: 0,
                    evidence: "Feet, hips, torso rotation, power, and complete form are not measured"
                )
            ]
        ))
    }

    private func advanceGuidedCalibrationStage() {
        let timestamp = ProcessInfo.processInfo.systemUptime
        guided.advanceCalibration(withFreshEvidenceAt: timestamp)
        guided.advanceCalibration(withFreshEvidenceAt: timestamp + 0.5)
    }

    private func captureHandShape(
        expected: TrackedFistState
    ) async -> [BodySide: Float]? {
        let deadline = Date().addingTimeInterval(6)
        var values: [BodySide: [Float]] = [.left: [], .right: []]
        var stableStartedAt: Date?
        var lastTimestamps: [BodySide: TimeInterval] = [:]

        while !Task.isCancelled, Date() < deadline, phase == .calibrating {
            guard let left = hands.freshObservation(for: .left),
                  let right = hands.freshObservation(for: .right),
                  left.fistState == expected,
                  right.fistState == expected,
                  left.timestamp > (lastTimestamps[.left] ?? -.infinity),
                  right.timestamp > (lastTimestamps[.right] ?? -.infinity)
            else {
                stableStartedAt = nil
                values = [.left: [], .right: []]
                try? await Task.sleep(for: .milliseconds(16))
                continue
            }

            stableStartedAt = stableStartedAt ?? Date()
            lastTimestamps[.left] = left.timestamp
            lastTimestamps[.right] = right.timestamp
            values[.left, default: []].append(left.fistClosureRatio)
            values[.right, default: []].append(right.fistClosureRatio)
            if Date().timeIntervalSince(stableStartedAt!) >= 0.5,
               values[.left, default: []].count >= 12,
               values[.right, default: []].count >= 12 {
                return values.mapValues { samples in
                    samples.sorted()[samples.count / 2]
                }
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return nil
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
               let right = hands.rightHand,
               (!capturesEventChallengeEvidence
                    || (left.fistState == .closed && right.fistState == .closed)) {
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
                    } else {
                        lastFeedback = "Reach calibrated"
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

        beginAttempt(fistAtSpawn: fistPositionForCurrentRun(nearestTo: worldPosition))
        lastFeedback = "Punch!"

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

            if let punchingSide = nearestPunchingSide(to: worldPosition),
               nonPunchingGuardStatus(punchingSide: punchingSide) == false {
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
            var eventPunches: [ChallengePunchSnapshot] = []

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
                var eventState: ChallengePunchState = .timeout
                var centerError: Float?
                var reactionTime: TimeInterval?
                var trackingLostAt: Date?

                while !Task.isCancelled,
                      phase == .running,
                      activeAttemptID != nil || (capturesEventChallengeEvidence && isTrackingPaused) {
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

                    if capturesEventChallengeEvidence,
                       required == nil || other == nil || hands.deviceTransform == nil {
                        trackingLostAt = trackingLostAt ?? Date()
                        if !isTrackingPaused,
                           Date().timeIntervalSince(trackingLostAt!) >= 0.1 {
                            targets.removeActiveTarget()
                            clearAttemptState()
                            isTrackingPaused = true
                            trackingReadyToResume = false
                            trackingResumeRequested = false
                            guided.pause(.requiredSampleStale)
                            lastFeedback = "Tracking Paused · That attempt was not scored"
                            if case .failed(.technicalDiscardLimit) = guided.stage {
                                failDrill("Tracking could not stabilize. This official attempt did not count.")
                                return
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(16))
                        continue
                    }

                    if capturesEventChallengeEvidence, isTrackingPaused {
                        let bothInGuard: Bool
                        if let bodyFrame = currentBodyFrame(),
                           let left = hands.freshObservation(for: .left),
                           let right = hands.freshObservation(for: .right),
                           let leftGuard = guardPositionsBody[.left],
                           let rightGuard = guardPositionsBody[.right] {
                            bothInGuard = CombinationPunchValidator.isRetracted(
                                fist: bodyFrame.toBody(left.fistPosition),
                                guardPosition: leftGuard,
                                radius: CombinationPunchValidator.guardRadius
                            ) && CombinationPunchValidator.isRetracted(
                                fist: bodyFrame.toBody(right.fistPosition),
                                guardPosition: rightGuard,
                                radius: CombinationPunchValidator.guardRadius
                            )
                        } else {
                            bothInGuard = false
                        }
                        guided.noteRecoveryEvidence(
                            at: ProcessInfo.processInfo.systemUptime,
                            bothHandsInGuard: bothInGuard
                        )
                        trackingReadyToResume = guided.readyToResume
                        lastFeedback = trackingReadyToResume
                            ? "Ready to resume · No score was lost"
                            : "Tracking Paused · Hold both hands in guard and look forward"

                        if trackingResumeRequested, trackingReadyToResume {
                            guided.resume()
                            trackingResumeRequested = false
                            trackingReadyToResume = false
                            isTrackingPaused = false
                            trackingLostAt = nil
                            validator = CombinationPunchValidator(
                                target: worldTarget,
                                guardPosition: worldGuardPosition,
                                hitRadius: config.hitRadius
                            )
                            targets.spawnTarget(at: worldPosition, radius: config.targetRadius)
                            beginAttempt(fistAtSpawn: required?.fistPosition)
                            deadline = Date().addingTimeInterval(config.timeout)
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
                        eventState = validator.phase == .armed ? .validMiss : .timeout
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
                        eventState = .wrongHand
                    case .hit:
                        await finishAttempt(
                            result: .hit,
                            hitTime: Date(),
                            fistAtHit: required?.fistPosition,
                            targetPosition: worldPosition
                        )
                        stepHit = true
                        eventState = required?.fistState == .closed ? .validContact : .openHand
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
                    if capturesEventChallengeEvidence {
                        let returnedToGuard = eventState == .validMiss
                            ? await waitForRetraction(
                                side: target.requiredHand,
                                guardPosition: guardPosition
                            )
                            : false
                        eventPunches.append(ChallengePunchSnapshot(
                            repetition: rep + 1,
                            punch: target.punch,
                            requiredHand: target.requiredHand,
                            state: eventState,
                            centerErrorMeters: nil,
                            returnedToGuard: returnedToGuard,
                            trackingConfidence: freshTrackingConfidence(for: target.requiredHand)
                        ))
                        continue
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
                if capturesEventChallengeEvidence {
                    eventPunches.append(ChallengePunchSnapshot(
                        repetition: rep + 1,
                        punch: target.punch,
                        requiredHand: target.requiredHand,
                        state: eventState,
                        centerErrorMeters: centerError,
                        returnedToGuard: returnedToGuard,
                        trackingConfidence: freshTrackingConfidence(for: target.requiredHand)
                    ))
                }
                guard returnedToGuard else {
                    lastFeedback = "Combination reset · return to guard"
                    completedRep = false
                    if capturesEventChallengeEvidence || capturesCompetitionEvidence { continue }
                    break
                }
            }

            if capturesEventChallengeEvidence,
               eventPunches.count == 2,
               let jab = eventPunches.first(where: { $0.punch == .jab }),
               let cross = eventPunches.first(where: { $0.punch == .cross }) {
                challengeRepetitions.append(ChallengeRepSnapshot(
                    repetition: rep + 1,
                    jab: jab,
                    cross: cross
                ))
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

    private func freshTrackingConfidence(for side: BodySide) -> Float {
        guard let observation = hands.freshObservation(for: side) else { return 0 }
        let age = ProcessInfo.processInfo.systemUptime - observation.timestamp
        return age >= 0 && age <= 0.1 ? 1 : 0
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

    private func calibrationKey(for mode: ReactiveStrikeMode) -> ReactiveStrikeMode {
        mode == .combination ? .air : mode
    }

    private func clearAttemptState() {
        activeAttemptID = nil
        spawnTime = nil
        fistPositionAtSpawn = nil
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

    private func nearestPunchingSide(to point: SIMD3<Float>) -> BodySide? {
        let left = capturesCompetitionEvidence
            ? hands.freshObservation(for: .left)?.fistPosition
            : hands.leftFistPosition
        let right = capturesCompetitionEvidence
            ? hands.freshObservation(for: .right)?.fistPosition
            : hands.rightFistPosition
        switch (left, right) {
        case let (left?, right?):
            return distance(left, point) <= distance(right, point) ? .left : .right
        case (nil, .some):
            return .right
        case (.some, nil):
            return .left
        case (nil, nil):
            return nil
        }
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
