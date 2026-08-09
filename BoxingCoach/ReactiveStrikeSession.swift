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

    private let poseSolver = ArmPoseSolver()
    private var calibratedReaches: [ReactiveStrikeMode: [BodySide: Float]] = [:]
    private var guardPositionsBody: [BodySide: SIMD3<Float>] = [:]
    private var drillTask: Task<Void, Never>?
    private var activeAttemptID: UUID?
    private var spawnTime: Date?
    private var fistPositionAtSpawn: SIMD3<Float>?

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

        guard let guards = await acquireGuardPositions() else {
            guard !Task.isCancelled else { return }
            failDrill("Keep both hands visible in guard so calibration can begin.")
            return
        }
        guardPositionsBody = guards

        let key = calibrationKey(for: mode)
        let maximumGuardForward = guards.values.map(\.z).max() ?? 0
        if let cached = calibratedReaches[key],
           let measuredReach = ReachCalibration.conservativeBilateralReach(cached),
               let guardedProfile = mode.reachProfile
               .calibrated(measuredForwardReach: measuredReach)
               .placingTargetsBeyondGuard(
                   maximumGuardForward: maximumGuardForward,
                   hitRadius: config.hitRadius
               ) {
            reachProfile = guardedProfile
        } else {
            // A guard can move between rounds. If it now sits beyond the cached safe volume,
            // invalidate that measurement and collect a fresh extension instead of failing every
            // subsequent retry with the same stale profile.
            calibratedReaches[key] = nil
            guard let measuredReaches = await calibrateReach(using: guards),
                  let measuredReach = ReachCalibration.conservativeBilateralReach(measuredReaches)
            else {
                guard !Task.isCancelled else { return }
                failDrill("Reach calibration timed out. Return to guard, then fully extend each arm.")
                return
            }
            let calibrated = mode.reachProfile.calibrated(measuredForwardReach: measuredReach)
            guard let guardedProfile = calibrated.placingTargetsBeyondGuard(
                maximumGuardForward: maximumGuardForward,
                hitRadius: config.hitRadius
            ) else {
                failDrill("Your guard and full extension were too close together. Reset your guard and calibrate again.")
                return
            }
            calibratedReaches[key] = measuredReaches
            reachProfile = guardedProfile
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

    /// Captures a fresh guard every round even when reach is cached. Combination validation uses
    /// these positions to require each punch to leave guard and return before the next step.
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
        lastFeedback = "Fully extend each arm toward the target, one at a time"

        let cueBodyPosition = SIMD3<Float>(0, 0.02, mode.reachProfile.forwardMax)
        targets.spawnTarget(
            at: frame.toWorld(cueBodyPosition),
            radius: config.targetRadius * 1.25
        )

        defer { targets.removeActiveTarget() }

        let deadline = Date().addingTimeInterval(9)
        var acceptedSamples: [BodySide: [Float]] = [.left: [], .right: []]
        var firstAcceptedAt: [BodySide: Date] = [:]
        var lastAcceptedAt: [BodySide: Date] = [:]
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
                    if let candidate = ReachCalibration.candidateForwardReach(
                        guardPosition: guardPosition,
                        fistPosition: fistBody
                    ) {
                        let now = Date()
                        if let previousAcceptedAt = lastAcceptedAt[side],
                           now.timeIntervalSince(previousAcceptedAt) > 0.5 {
                            acceptedSamples[side] = []
                            firstAcceptedAt[side] = nil
                        }
                        acceptedSamples[side, default: []].append(candidate)
                        firstAcceptedAt[side] = firstAcceptedAt[side] ?? now
                        lastAcceptedAt[side] = now

                        if let first = firstAcceptedAt[side],
                           now.timeIntervalSince(first) >= 0.25,
                           let robustReach = ReachCalibration.robustForwardReach(
                               from: acceptedSamples[side, default: []]
                            ) {
                            measuredReaches[side] = robustReach
                            if measuredReaches.count == 1 {
                                let remainingSide: BodySide = side == .left ? .right : .left
                                lastFeedback = "Now fully extend your \(remainingSide.rawValue) arm"
                            } else {
                                lastFeedback = "Reach calibrated"
                            }
                        }
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

        return nil
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
        let deadline = Date().addingTimeInterval(config.timeout)

        while !Task.isCancelled, phase == .running, activeAttemptID != nil {
            if Date() >= deadline {
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
}
