import Foundation
import simd

enum AttemptResult: String, Sendable {
    case hit
    case miss
}

struct TargetAttempt: Identifiable, Sendable {
    let id: UUID
    let spawnTime: Date
    var hitTime: Date?
    var result: AttemptResult
    var distanceAtHit: Float?
    var fistTravelDistance: Float?
    var estimatedSpeedMetersPerSecond: Float?

    var reactionTime: TimeInterval? {
        guard let hitTime else { return nil }
        return hitTime.timeIntervalSince(spawnTime)
    }
}

struct DrillConfig: Sendable, Equatable {
    var targetCount: Int = 8
    var hitRadius: Float = 0.12
    var timeout: TimeInterval = 2.0
    var interTargetDelay: TimeInterval = 0.45
    var targetRadius: Float = 0.08
}

@Observable
final class DrillMetrics {
    private(set) var attempts: [TargetAttempt] = []

    var hitCount: Int {
        attempts.filter { $0.result == .hit }.count
    }

    var missCount: Int {
        attempts.filter { $0.result == .miss }.count
    }

    var accuracy: Double {
        guard !attempts.isEmpty else { return 0 }
        return Double(hitCount) / Double(attempts.count)
    }

    var averageReactionTime: TimeInterval? {
        let times = attempts.compactMap(\.reactionTime)
        guard !times.isEmpty else { return nil }
        return times.reduce(0, +) / Double(times.count)
    }

    var averageEstimatedSpeed: Float? {
        let speeds = attempts.compactMap(\.estimatedSpeedMetersPerSecond)
        guard !speeds.isEmpty else { return nil }
        return speeds.reduce(0, +) / Float(speeds.count)
    }

    var lastAttempt: TargetAttempt? {
        attempts.last
    }

    func reset() {
        attempts.removeAll()
    }

    func record(_ attempt: TargetAttempt) {
        attempts.append(attempt)
    }
}
