import Foundation
import RealityKit
import simd

enum DrillPhase: String, Sendable {
    case idle
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

    var config = DrillConfig()
    var mode: ReactiveStrikeMode = .air
    var reachProfile = ReachProfile.air

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

    var progressLabel: String {
        guard phase == .running else {
            return phase == .finished ? "Round complete" : "Idle"
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
        guard phase != .running else { return }
        reachProfile = mode.reachProfile
        metrics.reset()
        currentTargetIndex = 0
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
        activeAttemptID = nil
        spawnTime = nil
        fistPositionAtSpawn = nil
        if phase == .running {
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

        // Brief pause so the user can raise their guard.
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled, phase == .running else { return }

        for index in 0..<config.targetCount {
            guard !Task.isCancelled, phase == .running else { return }
            currentTargetIndex = index
            await presentTarget()
            guard !Task.isCancelled, phase == .running else { return }

            if index < config.targetCount - 1 {
                try? await Task.sleep(for: .seconds(config.interTargetDelay))
            }
        }

        targets.removeActiveTarget()
        phase = .finished
        lastFeedback = summaryFeedback()
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
                targets.activeTargetPosition.map { distance(end, $0) }
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
        if let avg = metrics.averageReactionTime {
            return String(format: "Done · %d%% accuracy · avg %.0f ms", accuracyPercent, avg * 1000)
        }
        return "Done · \(accuracyPercent)% accuracy"
    }
}
