import Foundation
import RealityKit
import simd

enum DrillPhase: String, Sendable {
    case idle
    case calibrating
    case running
    case finished
}

/// Owns the Reactive Strike drill loop: spawn → await hit/miss → metrics → next target.
@Observable
@MainActor
final class ReactiveStrikeSession {
    let immersiveSpaceID = BoxingCoachSceneID.immersiveSpace

    private(set) var phase: DrillPhase = .idle
    private(set) var currentTargetIndex = 0
    private(set) var lastFeedback: String = "Ready"
    private(set) var errorMessage: String?

    /// Whether the immersive space is actually on screen.
    ///
    /// Owned here, and set from the immersive scene's own lifecycle, because the space can also
    /// close without the window's buttons being involved — the system dismissing it, or the user
    /// leaving it. A copy kept in the window's local view state goes stale in exactly that case,
    /// which then makes "Start" silently do nothing because the app believes a closed space is
    /// still open.
    private(set) var isImmersiveSpaceOpen = false

    func immersiveSpaceDidOpen() {
        isImmersiveSpaceOpen = true
    }

    func immersiveSpaceDidClose() {
        isImmersiveSpaceOpen = false
    }

    var config = DrillConfig()
    var mode: ReactiveStrikeMode = .air
    var reachProfile = ReachProfile.air
    var selectedCombination: Combination = .oneTwo
    var comboRepeatCount: Int = 5

    let metrics = DrillMetrics()
    let hands = HandTrackingService()
    let targets = TargetController()

    /// Aura Punch shares this session's hand tracking and scene root rather than standing up its
    /// own ARKit session — two sessions competing for the same providers is a good way to get
    /// neither. Only one drill runs at a time, so there is no contention over the data.
    let auraPunch: AuraPunchSession

    init() {
        auraPunch = AuraPunchSession(hands: hands)
    }

    private var drillTask: Task<Void, Never>?
    private var activeAttemptID: UUID?
    private var spawnTime: Date?
    private var fistPositionAtSpawn: SIMD3<Float>?
    private var currentComboStepIndex = 0
    private var comboAttemptIDs: [UUID] = []
    private var comboStepSpawnTimes: [Date] = []
    private(set) var comboRepsCompleted = 0

    var progressLabel: String {
        guard phase == .running || phase == .calibrating else {
            return phase == .finished ? "Round complete" : "Idle"
        }
        if phase == .calibrating {
            return "Calibrating…"
        }
        if mode == .combination {
            let comboTotal = selectedCombination.punchCount
            return "Rep \(min(currentTargetIndex + 1, comboRepeatCount)) / \(comboRepeatCount)"
        }
        return "Target \(min(currentTargetIndex + 1, config.targetCount)) / \(config.targetCount)"
    }

    func selectMode(_ mode: ReactiveStrikeMode) {
        self.mode = mode
        reachProfile = mode.reachProfile
    }

    func attachSceneRoot(_ root: Entity) {
        targets.attach(to: root)
        auraPunch.attach(to: root)
    }

    func startDrill() {
        guard phase != .running, phase != .calibrating else { return }
        reachProfile = mode.reachProfile
        metrics.reset()
        currentTargetIndex = 0
        currentComboStepIndex = 0
        comboAttemptIDs.removeAll()
        comboStepSpawnTimes.removeAll()
        comboRepsCompleted = 0
        phase = .running
        lastFeedback = "Get ready…"
        errorMessage = nil

        drillTask?.cancel()
        drillTask = Task { [weak self] in
            await self?.runDrillLoop()
        }
    }

    func stopDrill() {
        // Also covers the immersive space being dismissed, which is the one moment Aura Punch
        // must stop too — its pose loop would otherwise keep running against dead tracking.
        auraPunch.stop()

        drillTask?.cancel()
        drillTask = nil
        targets.removeActiveTarget()
        targets.removeComboTargets()
        activeAttemptID = nil
        spawnTime = nil
        fistPositionAtSpawn = nil
        comboAttemptIDs.removeAll()
        comboStepSpawnTimes.removeAll()
        if phase == .running || phase == .calibrating {
            phase = metrics.attempts.isEmpty ? .idle : .finished
        }
        lastFeedback = "Drill stopped"
    }

    func resetForNewRound() {
        stopDrill()
        metrics.reset()
        phase = .idle
        currentTargetIndex = 0
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
        if !hands.isRunning {
            errorMessage = hands.statusMessage
            phase = .idle
            lastFeedback = hands.statusMessage
            return
        }

        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled, phase == .running || phase == .calibrating else { return }

        await calibrateReach()
        guard !Task.isCancelled, phase == .running else { return }

        if mode == .combination {
            await runCombinationLoop()
        } else {
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

        targets.removeActiveTarget()
        targets.removeComboTargets()
        phase = .finished
        lastFeedback = summaryFeedback()
    }

    private func calibrateReach() async {
        phase = .calibrating
        lastFeedback = "Extend arm to calibrate reach…"

        let testForward: Float = 0.90
        let testPosition = SIMD3<Float>(0, 1.25, -testForward)
        _ = targets.spawnTarget(at: testPosition, radius: config.targetRadius * 1.25)

        let deadline = Date().addingTimeInterval(6)
        var bestForward: Float = 0

        while Date() < deadline {
            if Task.isCancelled {
                targets.removeActiveTarget()
                return
            }

            if let fist = hands.nearestFistPosition(to: testPosition) {
                let fistForward = abs(fist.z)
                if fistForward > bestForward {
                    bestForward = fistForward
                }

                let dist = distance(fist, testPosition)
                if dist <= config.hitRadius * 1.5 {
                    break
                }
            }

            try? await Task.sleep(for: .milliseconds(16))
        }

        targets.removeActiveTarget()

        if bestForward > 0.25 {
            reachProfile = reachProfile.calibrated(measuredForwardReach: bestForward)
        }

        phase = .running
        lastFeedback = "Get ready…"
    }

    private func runCombinationLoop() async {
        let combo = selectedCombination
        let forwardBase = reachProfile.forwardMax * 0.92

        for rep in 0..<comboRepeatCount {
            guard !Task.isCancelled, phase == .running else { return }
            currentTargetIndex = rep

            let positions = combo.targetPositions(forwardBase: forwardBase)
            targets.spawnCombo(at: positions, radius: config.targetRadius)
            targets.activateComboTarget(at: 0)

            comboAttemptIDs = (0..<combo.punchCount).map { _ in UUID() }
            comboStepSpawnTimes.removeAll()

            for step in 0..<combo.punchCount {
                guard !Task.isCancelled, phase == .running else { return }
                currentComboStepIndex = step
                let stepSpawn = Date()
                comboStepSpawnTimes.append(stepSpawn)
                activeAttemptID = comboAttemptIDs[step]
                spawnTime = stepSpawn
                fistPositionAtSpawn = hands.nearestFistPosition(to: positions[step])

                let punchName = combo.punches[step].displayName
                lastFeedback = "\(punchName)! (\(step + 1)/\(combo.punchCount))"

                let deadline = Date().addingTimeInterval(config.timeout)
                var stepHit = false

                while !Task.isCancelled, phase == .running {
                    if Date() >= deadline {
                        finishAttempt(
                            result: .miss,
                            hitTime: nil,
                            fistAtHit: hands.nearestFistPosition(to: positions[step])
                        )
                        targets.flashComboTarget(at: step, result: .miss)
                        break
                    }

                    if let fist = hands.nearestFistPosition(to: positions[step]) {
                        if distance(fist, positions[step]) <= config.hitRadius {
                            finishAttempt(result: .hit, hitTime: Date(), fistAtHit: fist)
                            targets.flashComboTarget(at: step, result: .hit)
                            stepHit = true
                            break
                        }
                    }

                    try? await Task.sleep(for: .milliseconds(16))
                }

                if Task.isCancelled || phase != .running { return }

                if !stepHit {
                    break
                }

                if step < combo.punchCount - 1 {
                    targets.activateComboTarget(at: step + 1)
                    try? await Task.sleep(for: .milliseconds(120))
                } else {
                    comboRepsCompleted += 1
                }
            }

            comboAttemptIDs.removeAll()
            comboStepSpawnTimes.removeAll()

            try? await Task.sleep(for: .milliseconds(350))
            targets.removeComboTargets()

            if rep < comboRepeatCount - 1 {
                try? await Task.sleep(for: .seconds(config.interTargetDelay))
            }
        }
    }

    private func presentTarget() async {
        let position = reachProfile.randomTargetPosition()
        _ = targets.spawnTarget(at: position, radius: config.targetRadius)

        let attemptID = UUID()
        activeAttemptID = attemptID
        spawnTime = Date()
        fistPositionAtSpawn = hands.nearestFistPosition(to: position)
        lastFeedback = "Punch!"

        let deadline = Date().addingTimeInterval(config.timeout)

        while !Task.isCancelled, phase == .running, activeAttemptID == attemptID {
            if Date() >= deadline {
                finishAttempt(
                    result: .miss,
                    hitTime: nil,
                    fistAtHit: hands.nearestFistPosition(to: position)
                )
                return
            }

            if let fist = hands.nearestFistPosition(to: position) {
                let dist = distance(fist, position)
                if dist <= config.hitRadius {
                    finishAttempt(result: .hit, hitTime: Date(), fistAtHit: fist)
                    return
                }
            }

            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func finishAttempt(
        result: AttemptResult,
        hitTime: Date?,
        fistAtHit: SIMD3<Float>?
    ) {
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
            distanceAtHit: fistAtHit.flatMap { end in
                let targetPos: SIMD3<Float>?
                if mode == .combination, currentComboStepIndex < targets.comboTargetPositions.count {
                    targetPos = targets.comboTargetPositions[currentComboStepIndex]
                } else {
                    targetPos = targets.activeTargetPosition
                }
                return targetPos.map { distance(end, $0) }
            },
            fistTravelDistance: travel,
            estimatedSpeedMetersPerSecond: speed
        )

        metrics.record(attempt)
        targets.flash(result: result)

        if result == .hit, let reaction = attempt.reactionTime {
            lastFeedback = String(format: "Hit · %.0f ms", reaction * 1000)
        } else {
            lastFeedback = "Miss"
        }

        activeAttemptID = nil
        self.spawnTime = nil
        fistPositionAtSpawn = nil

        // Keep flash visible briefly, then clear.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            self?.targets.removeActiveTarget()
        }
    }

    private func summaryFeedback() -> String {
        let accuracyPercent = Int((metrics.accuracy * 100).rounded())
        if mode == .combination {
            return String(format: "Done · %d/%d combos · %d%% accuracy", comboRepsCompleted, comboRepeatCount, accuracyPercent)
        }
        if let avg = metrics.averageReactionTime {
            return String(format: "Done · %d%% accuracy · avg %.0f ms", accuracyPercent, avg * 1000)
        }
        return "Done · \(accuracyPercent)% accuracy"
    }
}
