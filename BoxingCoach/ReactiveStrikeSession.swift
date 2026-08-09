import Foundation
import RealityKit
import simd

enum DrillPhase: String, Sendable {
    case idle
    case calibrating
    case running
    case finished
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

    // Defaulted to `nil` rather than to `BodyCalibration()`: a default argument expression is
    // evaluated outside this initializer's actor isolation, and `BodyCalibration` is MainActor.
    init(calibration: BodyCalibration? = nil) {
        self.calibration = calibration ?? BodyCalibration()
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
        guardPositionsBody.removeAll()
        phase = .calibrating
        lastFeedback = "Raise both hands into guard"
        errorMessage = nil

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
        guard phase != .running, phase != .calibrating else { return }

        guardPositionsBody.removeAll()
        calibration.invalidate()
        metrics.reset()
        phase = .calibrating
        lastFeedback = "Raise both hands into guard"
        errorMessage = nil

        drillTask?.cancel()
        drillTask = Task { [weak self] in
            await self?.runCalibrationLoop()
        }
    }

    func stopDrill() {
        // Also covers a system-driven immersive dismissal. Aura Punch must stop here too or its
        // pose loop would keep running against tracking providers that no longer have a scene.
        auraPunch.stop()

        drillTask?.cancel()
        drillTask = nil
        targets.removeActiveTarget()
        clearAttemptState()
        guardPositionsBody.removeAll()

        let stoppedActiveDrill = phase == .running || phase == .calibrating
        if stoppedActiveDrill {
            phase = metrics.attempts.isEmpty ? .idle : .finished
            lastFeedback = "Drill stopped"
        }
    }

    func resetForNewRound() {
        stopDrill()
        metrics.reset()
        phase = .idle
        currentTargetIndex = 0
        currentComboStepIndex = 0
        comboRepsCompleted = 0
        lastFeedback = "Ready"
        errorMessage = nil
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

        if mode == .combination {
            await runCombinationLoop()
        } else {
            await runTargetLoop()
        }

        guard !Task.isCancelled, phase == .running else { return }
        targets.removeActiveTarget()
        clearAttemptState()
        phase = .finished
        lastFeedback = summaryFeedback()
    }

    private func runCalibrationLoop() async {
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
        let deadline = Date().addingTimeInterval(5)
        var leftTotal = SIMD3<Float>.zero
        var rightTotal = SIMD3<Float>.zero
        var sampleCount: Float = 0
        var lastPairTimestamp: TimeInterval?

        while !Task.isCancelled, Date() < deadline, phase == .calibrating {
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
        guard let frame = currentBodyFrame() else { return nil }

        phase = .calibrating
        lastFeedback = "Punch out and hold full extension — left arm first"

        // Cue at an average adult's reach, never at the profile's `forwardMax`. Air's 0.75 m far
        // edge is past most people's actual reach, so cueing there made users lean or lunge, which
        // moves the body frame origin and corrupts the very measurement being taken.
        let cueBodyPosition = SIMD3<Float>(0, 0.02, BodyMeasurements.averageAdult.armReach)
        targets.spawnTarget(
            at: frame.toWorld(cueBodyPosition),
            radius: config.targetRadius * 1.25
        )

        defer { targets.removeActiveTarget() }

        // Longer than the old 9 s: a held plateau is being waited for, not just a passing sample.
        let deadline = Date().addingTimeInterval(14)
        var acceptedSamples: [BodySide: [ReachSample]] = [.left: [], .right: []]
        var lastAcceptedTimestamp: [BodySide: TimeInterval] = [:]
        var lastProcessedTimestamp: [BodySide: TimeInterval] = [:]
        var measuredReaches: [BodySide: Float] = [:]

        while !Task.isCancelled, Date() < deadline, phase == .calibrating {
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

                    // Dropping back to guard between attempts starts a fresh measurement rather
                    // than splicing two separate extensions into one plateau.
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
                        lastFeedback = "Now punch out and hold with your \(side.opposite.rawValue) arm"
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

        // Timed out waiting for a clean hold. Fall back to the old percentile rule on whatever was
        // captured: an under-measured drill still beats refusing to start one.
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
        let deadline = Date().addingTimeInterval(2.5)
        var consecutiveFreshSamples = 0
        var lastPairTimestamp: TimeInterval?

        while !Task.isCancelled, Date() < deadline, phase == .calibrating {
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

    private func runTargetLoop() async {
        for index in 0..<config.targetCount {
            guard !Task.isCancelled, phase == .running else { return }
            currentTargetIndex = index
            await presentTarget()
            guard !Task.isCancelled, phase == .running else { return }

            if index < config.targetCount - 1 {
                try? await Task.sleep(for: .seconds(config.interTargetDelay))
            }
        }
    }

    private func presentTarget() async {
        guard let frame = await waitForBodyFrame() else {
            guard !Task.isCancelled else { return }
            failDrill("Head tracking was lost. Face forward and try the round again.")
            return
        }

        let bodyPosition = reachProfile.randomBodyTargetPosition()
        let worldPosition = frame.toWorld(bodyPosition)
        targets.spawnTarget(at: worldPosition, radius: config.targetRadius)

        beginAttempt(fistAtSpawn: hands.nearestFistPosition(to: worldPosition))
        lastFeedback = "Punch!"

        var activeElapsed: TimeInterval = 0
        var lastTick = Date()

        while !Task.isCancelled, phase == .running, activeAttemptID != nil {
            let now = Date()

            if let punchingSide = nearestPunchingSide(to: worldPosition),
               nonPunchingGuardStatus(punchingSide: punchingSide) == false {
                lastFeedback = GuardCoach.waitMessage
                lastTick = now
                try? await Task.sleep(for: .milliseconds(16))
                continue
            }

            if lastFeedback == GuardCoach.waitMessage {
                lastFeedback = "Punch!"
            }

            activeElapsed += now.timeIntervalSince(lastTick)
            lastTick = now

            if activeElapsed >= config.timeout {
                await finishAttempt(
                    result: .miss,
                    hitTime: nil,
                    fistAtHit: hands.nearestFistPosition(to: worldPosition),
                    targetPosition: worldPosition
                )
                return
            }

            if let fist = hands.nearestFistPosition(to: worldPosition),
               distance(fist, worldPosition) <= config.hitRadius {
                await finishAttempt(
                    result: .hit,
                    hitTime: Date(),
                    fistAtHit: fist,
                    targetPosition: worldPosition
                )
                return
            }

            try? await Task.sleep(for: .milliseconds(16))
        }
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

                guard let guardPosition = guardPositionsBody[target.requiredHand],
                      let frame = await waitForBodyFrame()
                else {
                    guard !Task.isCancelled else { return }
                    failDrill("Tracking was lost while preparing the combination.")
                    return
                }

                let worldPosition = frame.toWorld(target.position)
                let worldGuardPosition = frame.toWorld(guardPosition)
                targets.spawnTarget(at: worldPosition, radius: config.targetRadius)

                let requiredObservation = hands.observation(for: target.requiredHand)
                beginAttempt(fistAtSpawn: requiredObservation?.fistPosition)
                lastFeedback = "\(target.punch.displayName)!"

                let worldTarget = CombinationTarget(
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
                let deadline = Date().addingTimeInterval(config.timeout)
                var stepHit = false

                while !Task.isCancelled, phase == .running, activeAttemptID != nil {
                    if Date() >= deadline {
                        await finishAttempt(
                            result: .miss,
                            hitTime: nil,
                            fistAtHit: hands.observation(for: target.requiredHand)?.fistPosition,
                            targetPosition: worldPosition
                        )
                        break
                    }

                    let required = hands.observation(for: target.requiredHand)
                    let other = hands.observation(for: target.requiredHand.opposite)
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
                    }

                    if stepHit { break }
                    try? await Task.sleep(for: .milliseconds(16))
                }

                guard !Task.isCancelled, phase == .running else { return }
                guard stepHit else {
                    completedRep = false
                    break
                }

                lastFeedback = "Return your \(target.requiredHand.rawValue) hand to guard"
                guard await waitForRetraction(
                    side: target.requiredHand,
                    guardPosition: guardPosition
                ) else {
                    guard !Task.isCancelled else { return }
                    lastFeedback = "Combination reset · return to guard"
                    completedRep = false
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

        while !Task.isCancelled, Date() < deadline, phase == .running {
            if let frame = currentBodyFrame(),
               let observation = hands.observation(for: side),
               lastTimestamp.map({ observation.timestamp > $0 }) ?? true {
                lastTimestamp = observation.timestamp
                let isRetracted = CombinationPunchValidator.isRetracted(
                    fist: frame.toBody(observation.fistPosition),
                    guardPosition: guardPosition,
                    radius: CombinationPunchValidator.guardRadius
                )
                consecutiveSamples = isRetracted ? consecutiveSamples + 1 : 0
                if consecutiveSamples >= 3 { return true }
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
    }

    private func failDrill(_ message: String) {
        targets.removeActiveTarget()
        clearAttemptState()
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
        switch (hands.leftFistPosition, hands.rightFistPosition) {
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
        guard let frame = currentBodyFrame() else { return nil }
        let guardSide = punchingSide.opposite
        return GuardCoach.isGuardUp(
            guardFistWorld: hands.observation(for: guardSide)?.fistPosition,
            frame: frame,
            measurements: measurements,
            guardSide: guardSide
        )
    }
}
